#!/bin/bash
# ============================================
# Cleanup orphaned Prisma V4 tables (PascalCase)
# These were created by mistake before @@map fix
# ============================================

set -e

DB_FILE="/root/var/www/link-manager/database.sqlite"

echo "============================================"
echo "  CLEANUP: Removing orphaned Prisma tables"
echo "============================================"
echo ""

# Prisma-created tables that should NOT exist anymore
# (Prisma now uses @@map to point to V3 snake_case tables)
PRISMA_ORPHANS="User Category Link SalesEntry Account Merchant Fulfillment WorkSchedule SampleRequest FinanceEntry TaskComment UsaHoliday TrendingKeyword PodHoliday EvergreenKeyword"

DROPPED=0
KEPT=0

for TABLE in $PRISMA_ORPHANS; do
    EXISTS=$(sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name='$TABLE';" 2>/dev/null)
    if [ -n "$EXISTS" ]; then
        ROWS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM $TABLE;")
        if [ "$ROWS" -gt 0 ]; then
            echo "  [KEEP] $TABLE has $ROWS rows (has data, skipping for safety)"
            KEPT=$((KEPT + 1))
        else
            sqlite3 "$DB_FILE" "DROP TABLE $TABLE;"
            echo "  [DROP] $TABLE (0 rows, removed)"
            DROPPED=$((DROPPED + 1))
        fi
    else
        echo "  [SKIP] $TABLE (does not exist)"
    fi
done

echo ""
echo "============================================"
echo "  Dropped: $DROPPED tables"
echo "  Kept:    $KEPT tables (have data)"
echo "============================================"
