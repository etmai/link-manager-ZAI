#!/bin/bash
# ============================================
# Dinoz Link Manager V4 — Complete Recovery
# Fixes database table mapping issue
# Run this on VPS in project directory
# ============================================

set -e

PROJECT_DIR="/root/var/www/link-manager"
DB_FILE="${PROJECT_DIR}/database.sqlite"

echo ""
echo "============================================"
echo "  DINOZ LINK MANAGER V4 — DATA RECOVERY"
echo "============================================"
echo ""

# Step 0: Check we're in the right place
if [ ! -f "package.json" ]; then
    echo "[ERROR] package.json not found. Are you in the project directory?"
    echo "        Run: cd /root/var/www/link-manager"
    exit 1
fi

# Step 1: Diagnose
echo "=== STEP 1: Checking database state ==="
if [ ! -f "$DB_FILE" ]; then
    echo "[ERROR] database.sqlite not found!"
    echo "        Your data may have been lost. Check if you have a backup."
    exit 1
fi

SIZE=$(ls -lh "$DB_FILE" | awk '{print $5}')
echo "[OK] Database file: $DB_FILE ($SIZE)"

# Check old tables
OLD_COUNT=0
V3_TABLES="users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords"
for TABLE in $V3_TABLES; do
    COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "0")
    OLD_COUNT=$((OLD_COUNT + COUNT))
done

echo "[OK] Old V3 tables contain: $OLD_COUNT rows"

if [ "$OLD_COUNT" -eq 0 ]; then
    echo "[WARN] No data found in old tables either!"
    echo "       Your database may have been truly emptied."
    echo "       Checking for backup files..."
    find /root -name "*.sqlite.bak" -o -name "*.db.bak" -o -name "database_backup*" 2>/dev/null | head -10
    echo ""
    echo "       If no backup found, data cannot be recovered."
    exit 1
fi

echo ""

# Step 2: Stop the server
echo "=== STEP 2: Stopping PM2 process ==="
pm2 stop link-manager 2>/dev/null || echo "  (PM2 process not running)"
echo ""

# Step 3: Backup database before making changes
echo "=== STEP 3: Backing up database ==="
BACKUP="${DB_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$DB_FILE" "$BACKUP"
echo "[OK] Backup created: $BACKUP"
echo ""

# Step 4: Replace Prisma schema
echo "=== STEP 4: Applying fixed Prisma schema ==="
if [ -f "prisma/schema.prisma" ]; then
    # The schema.prisma file should already be updated from the fix ZIP
    # Verify it has @@map annotations
    MAP_COUNT=$(grep -c "@@map" prisma/schema.prisma 2>/dev/null || echo "0")
    if [ "$MAP_COUNT" -lt 10 ]; then
        echo "[ERROR] prisma/schema.prisma does not have @@map annotations!"
        echo "        Please extract the fix ZIP first:"
        echo "        unzip dinoz-v4-fix.zip"
        echo "        cp dinoz-v4-fix/schema.prisma prisma/schema.prisma"
        exit 1
    fi
    echo "[OK] Found $MAP_COUNT @@map annotations in schema"
else
    echo "[ERROR] prisma/schema.prisma not found!"
    echo "        Make sure you extracted the V4 ZIP correctly."
    exit 1
fi
echo ""

# Step 5: Regenerate Prisma Client and push schema
echo "=== STEP 5: Regenerating Prisma Client ==="
npx prisma generate
echo "[OK] Prisma Client regenerated"
echo ""

echo "=== STEP 6: Pushing schema to database ==="
npx prisma db push
echo "[OK] Schema pushed to database"
echo ""

# Step 7: Clean up orphaned Prisma tables
echo "=== STEP 7: Cleaning up orphaned tables ==="
PRISMA_ORPHANS="User Category Link SalesEntry Account Merchant Fulfillment WorkSchedule SampleRequest FinanceEntry TaskComment UsaHoliday TrendingKeyword PodHoliday EvergreenKeyword"

for TABLE in $PRISMA_ORPHANS; do
    EXISTS=$(sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name='$TABLE';" 2>/dev/null)
    if [ -n "$EXISTS" ]; then
        ROWS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;")
        if [ "$ROWS" -eq 0 ]; then
            sqlite3 "$DB_FILE" "DROP TABLE $TABLE;"
            echo "  [DROP] $TABLE (empty orphan)"
        else
            echo "  [KEEP] $TABLE ($ROWS rows — has data)"
        fi
    fi
done
echo ""

# Step 8: Restart server
echo "=== STEP 8: Restarting server ==="
pm2 start src/server.js --name link-manager
pm2 save
echo "[OK] Server restarted"
echo ""

# Step 9: Verify
echo "=== STEP 9: Verification ==="
sleep 3
echo "Tables and row counts after fix:"
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

echo "============================================"
echo "  [DONE] Recovery complete!"
echo "  PM2 logs: pm2 logs link-manager --lines 20"
echo "============================================"
