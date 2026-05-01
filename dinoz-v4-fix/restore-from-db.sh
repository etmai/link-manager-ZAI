#!/bin/bash
# ============================================
# Dinoz Link Manager — Restore from Database File
# Reads data directly from the 464K database file
# and imports into a fresh V3+Prisma database
# ============================================

set -e

PROJECT_DIR="/root/var/www/link-manager"
DB_FILE="${PROJECT_DIR}/database.sqlite"
BACKUP_FILE="${DB_FILE}.backup"

echo "============================================"
echo "  RESTORE FROM DATABASE FILE (464K)"
echo "============================================"
echo ""

# Step 1: Verify source file
echo "=== STEP 1: Verify source database ==="
if [ ! -f "$DB_FILE" ]; then
    echo "[ERROR] Database not found: $DB_FILE"
    exit 1
fi
SIZE=$(ls -lh "$DB_FILE" | awk '{print $5}')
echo "[OK] Source: $DB_FILE ($SIZE)"

# Count data in V3 tables via .dump
DUMP_COUNT=$(sqlite3 "$DB_FILE" ".dump" | grep -c "^INSERT INTO" || echo "0")
echo "[OK] Found $DUMP_COUNT INSERT statements in file"

# Count per table
echo ""
echo "    Data summary:"
for TABLE in links trending_keywords finance_entries sales_entries evergreen_keywords usa_holidays merchants accounts fulfillments sample_requests users categories work_schedule task_comments pod_holidays; do
    COUNT=$(sqlite3 "$DB_FILE" ".dump" | grep -c "^INSERT INTO $TABLE " || echo "0")
    if [ "$COUNT" -gt 0 ]; then
        printf "      %-25s %s rows\n" "$TABLE" "$COUNT"
    fi
done
echo ""

if [ "$DUMP_COUNT" -eq 0 ]; then
    echo "[ERROR] No data found in database file!"
    echo "        File may be truly corrupted."
    exit 1
fi

# Step 2: Stop server
echo "=== STEP 2: Stop server ==="
pm2 stop link-manager 2>/dev/null || echo "  (not running)"
echo ""

# Step 3: Backup the original file (keep it safe!)
echo "=== STEP 3: Backup original file ==="
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAFE_BACKUP="${DB_FILE}.original.${TIMESTAMP}"
cp "$DB_FILE" "$SAFE_BACKUP"
echo "[OK] Original backed up to: $SAFE_BACKUP"
echo ""

# Step 4: Create fresh database
echo "=== STEP 4: Create fresh database with V3 schema ==="
mv "$DB_FILE" "${DB_FILE}.old"

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

echo "[OK] Fresh database created"
echo ""

# Step 5: Import data directly from OLD database file
echo "=== STEP 5: Import data from old database ==="
# Dump only V3 INSERT statements (skip Prisma PascalCase tables and CREATE statements)
sqlite3 "${DB_FILE}.old" ".dump" | \
    grep "^INSERT INTO" | \
    grep -v '"User"' | grep -v '"Category"' | grep -v '"Link"' | \
    grep -v '"SalesEntry"' | grep -v '"Account"' | grep -v '"Merchant"' | \
    grep -v '"Fulfillment"' | grep -v '"WorkSchedule"' | grep -v '"SampleRequest"' | \
    grep -v '"FinanceEntry"' | grep -v '"TaskComment"' | grep -v '"UsaHoliday"' | \
    grep -v '"TrendingKeyword"' | grep -v '"PodHoliday"' | grep -v '"EvergreenKeyword"' | \
    grep -v '"ai_configs"' | \
    sqlite3 "$DB_FILE"

echo "[OK] Data imported from old database"
echo ""

# Step 6: Seed default admin (if not in dump)
echo "=== STEP 6: Ensure admin user exists ==="
ADMIN_EXISTS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE username='admin';")
if [ "$ADMIN_EXISTS" -eq 0 ]; then
    # bcrypt hash of 'Hello0'
    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO users VALUES('admin', '\$2a\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', 'admin');"
    echo "[OK] Default admin created (password: Hello0)"
else
    echo "[OK] Admin user exists ($ADMIN_EXISTS found)"
fi

# Seed default categories if empty
CAT_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM categories;")
if [ "$CAT_COUNT" -eq 0 ]; then
    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO categories VALUES('Tài liệu nội bộ');"
    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO categories VALUES('Thiết kế UI/UX');"
    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO categories VALUES('Mã nguồn');"
    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO categories VALUES('Tham khảo ngoại bộ');"
    echo "[OK] Default categories seeded"
fi
echo ""

# Step 7: Apply Prisma schema
echo "=== STEP 7: Apply Prisma schema ==="
cd "$PROJECT_DIR"

if [ -f "dinoz-v4-fix/schema.prisma" ]; then
    cp dinoz-v4-fix/schema.prisma prisma/schema.prisma
    echo "[OK] Updated schema with @@map annotations"
elif [ -f "prisma/schema.prisma" ]; then
    MAP_COUNT=$(grep -c "@@map" prisma/schema.prisma || echo "0")
    if [ "$MAP_COUNT" -lt 10 ]; then
        echo "[WARN] prisma/schema.prisma missing @@map annotations!"
        echo "       Extract dinoz-v4-fix.zip first, then re-run this script."
    fi
fi

npx prisma generate 2>&1 | tail -1

# Push schema (auto-accept data loss for orphan Prisma tables)
echo "y" | npx prisma db push 2>&1 | grep -v "prisma" | grep -v "warn" | grep -v "info" | head -10 || true
echo ""

# Step 8: Restart server
echo "=== STEP 8: Restart server ==="
pm2 delete link-manager 2>/dev/null || true
pm2 start src/server.js --name link-manager
pm2 save
echo "[OK] Server restarted"
echo ""

# Step 9: Verification
echo "=== STEP 9: VERIFICATION ==="
sleep 3
echo ""
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

# Show sample links
echo "=== SAMPLE DATA CHECK ==="
echo "  Latest 3 links:"
sqlite3 "$DB_FILE" "SELECT id, substr(url, 1, 60), date FROM links ORDER BY date DESC LIMIT 3;" 2>/dev/null | while read LINE; do
    echo "    $LINE"
done
echo ""

echo "============================================"
echo "  DONE!"
echo "  Original backup: $SAFE_BACKUP"
echo "  Old DB kept as:  ${DB_FILE}.old (can delete later)"
echo "  Login: admin / Hello0"
echo ""
echo "  Check logs: pm2 logs link-manager --lines 20"
echo "============================================"
