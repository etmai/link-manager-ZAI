#!/bin/bash
# ============================================
# Dinoz Link Manager — Database Diagnostic
# Runs on VPS to check old vs new tables
# ============================================

set -e

echo "============================================"
echo "  DATABASE DIAGNOSTIC REPORT"
echo "============================================"
echo ""

PROJECT_DIR="/root/var/www/link-manager"
DB_FILE="${PROJECT_DIR}/database.sqlite"

# 1. Check if database file exists
if [ -f "$DB_FILE" ]; then
    SIZE=$(ls -lh "$DB_FILE" | awk '{print $5}')
    echo "[OK] Database file found: $DB_FILE ($SIZE)"
else
    echo "[!!] Database file NOT found at: $DB_FILE"
    echo "[!!] Searching for .sqlite and .db files..."
    find /root -name "*.sqlite" -o -name "*.db" 2>/dev/null | head -20
    echo ""
    echo "[!!] If you found your database above, copy it:"
    echo "     cp <found_path> $DB_FILE"
    exit 1
fi

echo ""

# 2. List ALL tables in the database
echo "=== ALL TABLES IN DATABASE ==="
sqlite3 "$DB_FILE" ".tables"
echo ""

# 3. Count rows in V3 tables (snake_case)
echo "=== V3 OLD TABLES (snake_case) — YOUR DATA ==="
V3_TABLES="users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords"

TOTAL_OLD=0
for TABLE in $V3_TABLES; do
    COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "NOT_FOUND")
    if [ "$COUNT" != "NOT_FOUND" ]; then
        printf "  %-25s %s rows\n" "$TABLE" "$COUNT"
        TOTAL_OLD=$((TOTAL_OLD + COUNT))
    else
        printf "  %-25s [TABLE NOT FOUND]\n" "$TABLE"
    fi
done
echo "  ----------------------------------------"
echo "  TOTAL OLD DATA:                         $TOTAL_OLD rows"
echo ""

# 4. Count rows in Prisma tables (PascalCase)
echo "=== PRISMA V4 TABLES (PascalCase) — EMPTY? ==="
PRISMA_TABLES="User Category Link SalesEntry Account Merchant Fulfillment WorkSchedule SampleRequest FinanceEntry TaskComment UsaHoliday TrendingKeyword PodHoliday EvergreenKeyword"

TOTAL_NEW=0
for TABLE in $PRISMA_TABLES; do
    COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "NOT_FOUND")
    if [ "$COUNT" != "NOT_FOUND" ]; then
        printf "  %-25s %s rows\n" "$TABLE" "$COUNT"
        TOTAL_NEW=$((TOTAL_NEW + COUNT))
    else
        printf "  %-25s [TABLE NOT FOUND]\n" "$TABLE"
    fi
done
echo "  ----------------------------------------"
echo "  TOTAL PRISMA DATA:                      $TOTAL_NEW rows"
echo ""

# 5. Summary
echo "============================================"
if [ "$TOTAL_OLD" -gt 0 ]; then
    echo "  [SAVED] Your old data is still in the database!"
    echo "  Old tables: $TOTAL_OLD rows"
    echo "  Prisma tables: $TOTAL_NEW rows"
    echo ""
    echo "  FIX: Apply the V4-fix patch to remap Prisma tables"
    echo "  to your old table names. Data will be restored."
else
    echo "  [PROBLEM] No old data found in database."
    echo "  Check if the database file was overwritten."
fi
echo "============================================"
