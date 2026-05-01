#!/bin/bash
# ============================================
# Dinoz Link Manager — Import Data from Dump
# Uses the 4k.txt dump file to restore data
# ============================================

set -e

PROJECT_DIR="/root/var/www/link-manager"
DB_FILE="${PROJECT_DIR}/database.sqlite"
DUMP_FILE="${PROJECT_DIR}/4k.txt"

echo "============================================"
echo "  DATA IMPORT FROM DUMP FILE"
echo "============================================"
echo ""

# Check dump file exists
if [ ! -f "$DUMP_FILE" ]; then
    echo "[ERROR] Dump file not found: $DUMP_FILE"
    echo "        Make sure 4k.txt is in: $PROJECT_DIR/"
    exit 1
fi

echo "[OK] Dump file: $DUMP_FILE ($(ls -lh "$DUMP_FILE" | awk '{print $5}'))"
echo ""

# Count recoverable data
echo "=== DATA IN DUMP FILE ==="
for TABLE in links trending_keywords finance_entries sales_entries evergreen_keywords usa_holidays merchants accounts fulfillments sample_requests; do
    COUNT=$(grep -c "INSERT INTO $TABLE " "$DUMP_FILE" 2>/dev/null || echo "0")
    if [ "$COUNT" -gt 0 ]; then
        printf "  %-25s %s rows\n" "$TABLE" "$COUNT"
    fi
done
echo ""

# Step 1: Stop server
echo "=== STEP 1: Stopping server ==="
pm2 stop link-manager 2>/dev/null || echo "  (not running)"
echo ""

# Step 2: Backup current database
echo "=== STEP 2: Backing up current database ==="
if [ -f "$DB_FILE" ]; then
    BACKUP="${DB_FILE}.before-restore.$(date +%Y%m%d_%H%M%S)"
    cp "$DB_FILE" "$BACKUP"
    echo "[OK] Backup: $BACKUP"
fi
echo ""

# Step 3: Create fresh database with V3 schema
echo "=== STEP 3: Creating fresh database ==="
rm -f "$DB_FILE"

sqlite3 "$DB_FILE" << 'SCHEMA_EOF'
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password TEXT NOT NULL,
    role TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS categories (
    name TEXT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS links (
    id TEXT PRIMARY KEY,
    url TEXT NOT NULL,
    date TEXT NOT NULL,
    categories TEXT NOT NULL,
    updatedAt TEXT,
    createdAt TEXT NOT NULL,
    addedBy TEXT,
    updatedBy TEXT
);
CREATE TABLE IF NOT EXISTS sales_entries (
    id TEXT PRIMARY KEY,
    account TEXT NOT NULL,
    merchant TEXT DEFAULT '',
    category TEXT DEFAULT '',
    fulfillment TEXT DEFAULT '',
    design_id TEXT DEFAULT '',
    sku TEXT NOT NULL,
    title TEXT DEFAULT '',
    ord_id TEXT DEFAULT '',
    custom TEXT DEFAULT '',
    size TEXT DEFAULT '',
    filename TEXT DEFAULT '',
    sales INTEGER NOT NULL DEFAULT 0,
    date TEXT NOT NULL,
    createdAt TEXT NOT NULL,
    addedBy TEXT
);
CREATE TABLE IF NOT EXISTS accounts (
    id TEXT PRIMARY KEY,
    name UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS merchants (
    id TEXT PRIMARY KEY,
    name UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS fulfillments (
    id TEXT PRIMARY KEY,
    name UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS work_schedule (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    date TEXT NOT NULL,
    userId TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    createdBy TEXT,
    creatorRole TEXT DEFAULT 'user',
    createdAt TEXT NOT NULL,
    trelloCardId TEXT,
    categories TEXT
);
CREATE TABLE IF NOT EXISTS sample_requests (
    id TEXT PRIMARY KEY,
    designId TEXT NOT NULL,
    requester TEXT NOT NULL,
    requestDate TEXT NOT NULL,
    status TEXT DEFAULT 'Process',
    productLink TEXT DEFAULT 'N/A',
    expiryDate TEXT DEFAULT 'N/A',
    createdAt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS finance_entries (
    id TEXT PRIMARY KEY,
    date TEXT NOT NULL,
    fulfillment_cost REAL DEFAULT 0,
    fulfillment_note TEXT DEFAULT '',
    other_cost REAL DEFAULT 0,
    other_note TEXT DEFAULT '',
    payment REAL DEFAULT 0,
    payment_note TEXT DEFAULT '',
    createdAt TEXT NOT NULL,
    addedBy TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS task_comments (
    id TEXT PRIMARY KEY,
    taskId TEXT NOT NULL,
    username TEXT NOT NULL,
    content TEXT NOT NULL,
    createdAt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS usa_holidays (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    date TEXT NOT NULL,
    days_left INTEGER,
    priority_group TEXT,
    updatedAt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS trending_keywords (
    id TEXT PRIMARY KEY,
    keyword TEXT UNIQUE NOT NULL,
    heat_score INTEGER DEFAULT 50,
    category TEXT DEFAULT 'general',
    ai_summary TEXT,
    search_url_etsy TEXT,
    search_url_amazon TEXT,
    search_url_pinterest TEXT,
    is_pinned INTEGER DEFAULT 0,
    source TEXT DEFAULT 'google_trends',
    fetched_at TEXT
);
CREATE TABLE IF NOT EXISTS pod_holidays (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    date TEXT NOT NULL,
    heat_score INTEGER DEFAULT 50,
    prep_start TEXT,
    emoji TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS evergreen_keywords (
    id TEXT PRIMARY KEY,
    keyword TEXT UNIQUE NOT NULL,
    category TEXT,
    source TEXT DEFAULT 'google_sheet',
    createdAt TEXT
);
SCHEMA_EOF

echo "[OK] Fresh database created with V3 schema"
echo ""

# Step 4: Import data from dump (INSERT statements only)
echo "=== STEP 4: Importing data from dump ==="
# Filter only INSERT INTO statements for V3 tables, skip CREATE TABLE and Prisma tables
grep "^INSERT INTO" "$DUMP_FILE" | grep -v "INSERT INTO \"User\"" | grep -v "INSERT INTO \"Category\"" | grep -v "INSERT INTO \"Link\"" | grep -v "INSERT INTO \"SalesEntry\"" | grep -v "INSERT INTO \"Account\"" | grep -v "INSERT INTO \"Merchant\"" | grep -v "INSERT INTO \"Fulfillment\"" | grep -v "INSERT INTO \"WorkSchedule\"" | grep -v "INSERT INTO \"SampleRequest\"" | grep -v "INSERT INTO \"FinanceEntry\"" | grep -v "INSERT INTO \"TaskComment\"" | grep -v "INSERT INTO \"UsaHoliday\"" | grep -v "INSERT INTO \"TrendingKeyword\"" | grep -v "INSERT INTO \"PodHoliday\"" | grep -v "INSERT INTO \"EvergreenKeyword\"" | sqlite3 "$DB_FILE"

echo "[OK] Data imported"
echo ""

# Step 5: Create default admin user
echo "=== STEP 5: Creating default admin ==="
ADMIN_EXISTS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE username='admin';")
if [ "$ADMIN_EXISTS" -eq 0 ]; then
    # Default password: Hello0 (bcrypt hash)
    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO users VALUES('admin', '\$2a\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', 'admin');"
    echo "[OK] Admin user created (password: Hello0)"
else
    echo "[OK] Admin user already exists"
fi
echo ""

# Step 6: Seed missing categories
echo "=== STEP 6: Seeding default categories ==="
CAT_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM categories;")
if [ "$CAT_COUNT" -eq 0 ]; then
    for CAT in "Tài liệu nội bộ" "Thiết kế UI/UX" "Mã nguồn" "Tham khảo ngoại bộ"; do
        sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO categories VALUES('$CAT');"
    done
    echo "[OK] Default categories created"
else
    echo "[OK] Categories exist ($CAT_COUNT)"
fi
echo ""

# Step 7: Verify import
echo "=== STEP 7: VERIFICATION ==="
V3_TABLES="users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords"
TOTAL=0
for TABLE in $V3_TABLES; do
    COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "0")
    if [ "$COUNT" -gt 0 ]; then
        printf "  %-25s %s rows\n" "$TABLE" "$COUNT"
    fi
    TOTAL=$((TOTAL + COUNT))
done
echo "  ----------------------------------------"
echo "  TOTAL RESTORED:                          $TOTAL rows"
echo ""

# Step 8: Apply Prisma schema
echo "=== STEP 8: Applying Prisma schema ==="
cd "$PROJECT_DIR"

if [ -f "dinoz-v4-fix/schema.prisma" ]; then
    cp dinoz-v4-fix/schema.prisma prisma/schema.prisma
    echo "[OK] Schema updated with @@map annotations"
else
    echo "[WARN] dinoz-v4-fix/schema.prisma not found"
    echo "       Make sure you have the fix ZIP extracted"
fi

echo "[OK] Running prisma generate..."
npx prisma generate

echo "[OK] Running prisma db push..."
echo "y" | npx prisma db push 2>/dev/null || npx prisma db push --accept-data-loss 2>/dev/null || true
echo ""

# Step 9: Restart server
echo "=== STEP 9: Restarting server ==="
pm2 delete link-manager 2>/dev/null || true
pm2 start src/server.js --name link-manager
pm2 save
echo ""

# Step 10: Final verification
echo "=== FINAL VERIFICATION ==="
sleep 3
for TABLE in links sales_entries trending_keywords finance_entries evergreen_keywords usa_holidays; do
    COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "0")
    printf "  %-25s %s rows\n" "$TABLE" "$COUNT"
done
echo ""

echo "============================================"
echo "  RECOVERY COMPLETE!"
echo "  Login: admin / Hello0"
echo "  PM2 logs: pm2 logs link-manager --lines 20"
echo "============================================"
