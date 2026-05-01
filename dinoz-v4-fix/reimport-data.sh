#!/bin/bash
# ============================================
# Dinoz V4.1 — Check Data & Re-Import from Backup
# Prisma db push may have dropped tables when
# changing column types (Int→String), losing data.
# This script re-imports from backup.
# ============================================

set -e

PROJECT_DIR="/root/var/www/link-manager"
cd "$PROJECT_DIR"

echo "============================================"
echo "  DATA CHECK & RE-IMPORT"
echo "============================================"
echo ""

# ── 1. Check current database ──
echo "=== CURRENT DATABASE STATE ==="
DB="${PROJECT_DIR}/database.sqlite"
if [ -f "$DB" ]; then
    SIZE=$(ls -lh "$DB" | awk '{print $5}')
    echo "File: $DB ($SIZE)"
    echo ""
    printf "%-25s %s\n" "TABLE" "ROWS"
    echo "-----------------------------------------"
    CURRENT_TOTAL=0
    for T in users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords; do
        C=$(sqlite3 "$DB" "SELECT COUNT(*) FROM $T;" 2>/dev/null || echo "N/A")
        printf "%-25s %s\n" "$T" "$C"
        if [ "$C" != "N/A" ]; then
            CURRENT_TOTAL=$((CURRENT_TOTAL + C))
        fi
    done
    echo "-----------------------------------------"
    echo "TOTAL:                                $CURRENT_TOTAL"
else
    echo "[ERROR] database.sqlite not found!"
    exit 1
fi
echo ""

# ── 2. Find backup with most data ──
echo "=== FINDING BACKUP FILES ==="
BEST_BACKUP=""
BEST_ROWS=0

for F in $(find "$PROJECT_DIR" -maxdepth 1 -name "database.sqlite.*" -o -name "database.sqlite.old" 2>/dev/null | sort); do
    if [ -f "$F" ]; then
        ROWS=0
        for T in links sales_entries trending_keywords finance_entries; do
            C=$(sqlite3 "$F" "SELECT COUNT(*) FROM $T;" 2>/dev/null || echo "0")
            ROWS=$((ROWS + C))
        done
        BSIZE=$(ls -lh "$F" | awk '{print $5}')
        printf "  %-55s %s rows (%s)\n" "$(basename $F)" "$ROWS" "$BSIZE"
        if [ "$ROWS" -gt "$BEST_ROWS" ]; then
            BEST_ROWS=$ROWS
            BEST_BACKUP="$F"
        fi
    fi
done

echo ""
if [ -z "$BEST_BACKUP" ]; then
    echo "[ERROR] No backup files found!"
    echo "        Cannot restore data."
    exit 1
fi

echo "[OK] Best backup: $(basename $BEST_BACKUP) ($BEST_ROWS main rows)"
echo ""

# ── 3. Compare with current ──
if [ "$CURRENT_TOTAL" -ge "$BEST_ROWS" ]; then
    echo "[OK] Current database has $CURRENT_TOTAL rows."
    echo "    Backup has $BEST_ROWS rows."
    echo "    No restore needed!"
    echo ""
    echo "    If specific tables are empty, the data may not have been"
    echo "    in the original database. Check the backup:"
    echo "    sqlite3 $BEST_BACKUP '.dump' | grep 'INSERT INTO trending_keywords' | wc -l"
    echo "    sqlite3 $BEST_BACKUP '.dump' | grep 'INSERT INTO sales_entries' | wc -l"
    exit 0
fi

echo "[WARN] Current DB has $CURRENT_TOTAL rows vs Backup has $BEST_ROWS rows"
echo "       Data was lost during prisma db push!"
echo ""

read -p "Re-import data from backup? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

# ── 4. Stop server ──
echo ""
echo "=== STEP 1: Stop server ==="
pm2 stop link-manager 2>/dev/null || echo "  (not running)"

# ── 5. Export data from backup ──
echo "=== STEP 2: Export data from backup ==="
DUMP_SQL="/tmp/dinoz-restore-$(date +%s).sql"

sqlite3 "$BEST_BACKUP" ".dump" | \
    grep "^INSERT INTO" | \
    grep -v '"User"' | grep -v '"Category"' | grep -v '"Link"' | \
    grep -v '"SalesEntry"' | grep -v '"Account"' | grep -v '"Merchant"' | \
    grep -v '"Fulfillment"' | grep -v '"WorkSchedule"' | grep -v '"SampleRequest"' | \
    grep -v '"FinanceEntry"' | grep -v '"TaskComment"' | grep -v '"UsaHoliday"' | \
    grep -v '"TrendingKeyword"' | grep -v '"PodHoliday"' | grep -v '"EvergreenKeyword"' | \
    grep -v '"ai_configs"' | \
    > "$DUMP_SQL"

DUMP_LINES=$(wc -l < "$DUMP_SQL")
echo "[OK] Exported $DUMP_LINES INSERT statements"
echo ""

# Show what we're importing
echo "    Data to import:"
for T in users links sales_entries trending_keywords finance_entries evergreen_keywords usa_holidays accounts merchants fulfillments sample_requests categories work_schedule task_comments pod_holidays; do
    C=$(grep -c "INSERT INTO $T " "$DUMP_SQL" 2>/dev/null || echo "0")
    if [ "$C" -gt 0 ]; then
        printf "      %-25s %s rows\n" "$T" "$C"
    fi
done
echo ""

# ── 6. Clear current tables and re-import ──
echo "=== STEP 3: Clear tables and re-import ==="

# Clear data from all tables (keep schema)
for T in task_comments sample_requests work_schedule finance_entries sales_entries evergreen_keywords trending_keywords usa_holidays pod_holidays links accounts merchants fulfillments categories users; do
    sqlite3 "$DB" "DELETE FROM $T;" 2>/dev/null || true
done
echo "[OK] All tables cleared"

# Import from backup dump
sqlite3 "$DB" < "$DUMP_SQL"
echo "[OK] Data imported from backup"
rm -f "$DUMP_SQL"
echo ""

# ── 7: Seed admin ──
echo "=== STEP 4: Ensure admin user ==="
ADMIN=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='admin';" 2>/dev/null || echo "0")
if [ "$ADMIN" -eq 0 ]; then
    HASH='$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy'
    sqlite3 "$DB" "INSERT OR IGNORE INTO users VALUES('admin','$HASH','admin');"
    echo "[OK] Admin created (password: Hello0)"
else
    echo "[OK] Admin exists ($ADMIN found)"
fi

# Seed categories if empty
CAT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM categories;" 2>/dev/null || echo "0")
if [ "$CAT" -eq 0 ]; then
    sqlite3 "$DB" "INSERT OR IGNORE INTO categories VALUES('Tài liệu nội bộ');"
    sqlite3 "$DB" "INSERT OR IGNORE INTO categories VALUES('Thiết kế UI/UX');"
    sqlite3 "$DB" "INSERT OR IGNORE INTO categories VALUES('Mã nguồn');"
    sqlite3 "$DB" "INSERT OR IGNORE INTO categories VALUES('Tham khảo ngoại bộ');"
    echo "[OK] Default categories seeded"
fi
echo ""

# ── 8: Verify ──
echo "=== STEP 5: Verification ==="
printf "%-25s %s\n" "TABLE" "ROWS"
echo "-----------------------------------------"
FINAL_TOTAL=0
for T in users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords; do
    C=$(sqlite3 "$DB" "SELECT COUNT(*) FROM $T;" 2>/dev/null || echo "N/A")
    if [ "$C" != "N/A" ] && [ "$C" != "0" ]; then
        printf "%-25s %s\n" "$T" "$C"
    fi
    if [ "$C" != "N/A" ]; then
        FINAL_TOTAL=$((FINAL_TOTAL + C))
    fi
done
echo "-----------------------------------------"
echo "TOTAL:                                $FINAL_TOTAL"
echo ""

# ── 9: Restart ──
echo "=== STEP 6: Restart server ==="
pm2 delete link-manager 2>/dev/null || true
pm2 start src/server.js --name link-manager
pm2 save
sleep 3
echo ""

echo "============================================"
echo "  DATA RESTORED: $FINAL_TOTAL rows"
echo "  Test: Open Trending Niches & Nhập Sales tabs"
echo "============================================"
