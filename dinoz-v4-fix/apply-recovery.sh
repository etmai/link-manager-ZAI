#!/bin/bash
# ============================================
# Dinoz Link Manager — Apply Recovered Data
# Imports data from SQLite .recover output
# Run AFTER deep-recover.sh
# ============================================

set -e

DB_FILE="/root/var/www/link-manager/database.sqlite"
RECOVERY_DIR="/tmp/dinoz-recovery"

echo "============================================"
echo "  APPLY RECOVERED DATA"
echo "============================================"
echo ""

# Find the latest recovery SQL file
LATEST_SQL=$(ls -t /tmp/dinoz-recovery-*.sql 2>/dev/null | head -1)

if [ -z "$LATEST_SQL" ] || [ ! -s "$LATEST_SQL" ]; then
    echo "[ERROR] No recovery SQL file found!"
    echo "        Run deep-recover.sh first: bash dinoz-v4-fix/deep-recover.sh"
    exit 1
fi

echo "[OK] Using recovery file: $LATEST_SQL"
echo "    Size: $(ls -lh "$LATEST_SQL" | awk '{print $5}')"
echo "    Lines: $(wc -l < "$LATEST_SQL")"
echo ""

# Count recoverable data
echo "=== RECOVERABLE DATA SUMMARY ==="
echo "Tables with INSERT statements:"
grep -oP "INSERT INTO \K[^ (]+" "$LATEST_SQL" 2>/dev/null | sort | uniq -c | sort -rn
echo ""

# Ask user to confirm
read -p "Apply recovered data to database? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

# Step 1: Backup current state
BACKUP="${DB_FILE}.pre-restore.$(date +%Y%m%d_%H%M%S)"
cp "$DB_FILE" "$BACKUP"
echo "[OK] Current DB backed up to: $BACKUP"
echo ""

# Step 2: Create fresh database with V3 schema
echo "=== STEP 1: Creating fresh database with V3 schema ==="

# V3 schema SQL
SCHEMA_SQL="
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
"

# Move old DB and create fresh one
mv "$DB_FILE" "${DB_FILE}.corrupted.$(date +%s)"
sqlite3 "$DB_FILE" < <(echo "$SCHEMA_SQL")
echo "[OK] Fresh database created"
echo ""

# Step 3: Import recovered data
echo "=== STEP 2: Importing recovered data ==="

# First, apply only the INSERT statements from recovery SQL
# Skip CREATE TABLE statements (we already created them)
grep -v "^CREATE TABLE" "$LATEST_SQL" | grep -v "^CREATE INDEX" | sqlite3 "$DB_FILE" 2>&1 || true

# Check if direct import worked
V3_TABLES="users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords"

TOTAL=0
for TABLE in $V3_TABLES; do
    COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "0")
    printf "  %-25s %s rows\n" "$TABLE" "$COUNT"
    TOTAL=$((TOTAL + COUNT))
done
echo "  ----------------------------------------"
echo "  TOTAL:                                   $TOTAL rows"
echo ""

if [ "$TOTAL" -gt 0 ]; then
    echo "=== STEP 3: Re-applying Prisma schema ==="
    cd /root/var/www/link-manager

    # Copy fixed schema
    if [ -f "dinoz-v4-fix/schema.prisma" ]; then
        cp dinoz-v4-fix/schema.prisma prisma/schema.prisma
    fi

    # Regenerate and push
    npx prisma generate
    npx prisma db push --accept-data-loss 2>/dev/null || true

    echo ""
    echo "=== STEP 4: Restarting server ==="
    pm2 restart link-manager 2>/dev/null || pm2 start src/server.js --name link-manager
    pm2 save

    echo ""
    echo "============================================"
    echo "  [SUCCESS] Data recovered: $TOTAL rows!"
    echo "  Backup of corrupted DB: ${DB_FILE}.corrupted.*"
    echo "  PM2 logs: pm2 logs link-manager --lines 20"
    echo "============================================"
else
    echo "[WARN] Direct import did not recover data."
    echo ""
    echo "Attempting manual table-by-table recovery..."
    echo ""

    # Try to find data in the corrupted file by table
    CORRUPTED=$(ls -t ${DB_FILE}.corrupted.* 2>/dev/null | head -1)
    if [ -n "$CORRUPTED" ]; then
        echo "Source: $CORRUPTED"

        # For each table, try to extract data from corrupted file
        for TABLE in $V3_TABLES; do
            # Get column info from fresh schema
            COLS=$(sqlite3 "$DB_FILE" "PRAGMA table_info($TABLE);" 2>/dev/null | awk -F'|' '{print $2}' | tr '\n' ',' | sed 's/,$//')

            if [ -n "$COLS" ]; then
                # Try to read from corrupted file
                DATA=$(sqlite3 "$CORRUPTED" "SELECT $COLS FROM $TABLE;" 2>/dev/null || true)
                if [ -n "$DATA" ]; then
                    ROW_COUNT=$(echo "$DATA" | wc -l)
                    echo "  [FOUND] $TABLE: $ROW_COUNT rows in corrupted file"

                    # Insert each row
                    echo "$DATA" | while IFS='|' read -r ROW; do
                        if [ -n "$ROW" ]; then
                            # Escape single quotes
                            ESCAPED=$(echo "$ROW" | sed "s/'/''/g")
                            sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO $TABLE VALUES($ESCAPED);" 2>/dev/null || true
                        fi
                    done
                fi
            fi
        done

        # Final count
        TOTAL2=0
        for TABLE in $V3_TABLES; do
            COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "0")
            if [ "$COUNT" -gt 0 ]; then
                printf "  %-25s %s rows\n" "$TABLE" "$COUNT"
            fi
            TOTAL2=$((TOTAL2 + COUNT))
        done
        echo "  ----------------------------------------"
        echo "  TOTAL RECOVERED:                        $TOTAL2 rows"
    fi
fi
