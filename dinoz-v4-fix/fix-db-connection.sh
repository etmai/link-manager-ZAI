#!/bin/bash
# ============================================
# Quick Fix: Database connection mismatch
# Ensures DATABASE_URL points to the right file
# and prisma schema is applied correctly
# ============================================

PROJECT_DIR="/root/var/www/link-manager"
cd "$PROJECT_DIR"

echo "============================================"
echo "  DATABASE CONNECTION FIX"
echo "============================================"
echo ""

# 1. Show current .env DATABASE_URL
echo "=== STEP 1: Check DATABASE_URL ==="
if [ -f ".env" ]; then
    echo "[.env contents:]"
    cat .env | grep -v "^#" | grep -v "^$"
else
    echo "[WARN] .env file not found!"
fi
echo ""

# 2. Show all .sqlite files
echo "=== STEP 2: All database files ==="
find . -name "*.sqlite" -o -name "*.db" 2>/dev/null | while read F; do
    SIZE=$(ls -lh "$F" | awk '{print $5}')
    TABLES=$(sqlite3 "$F" ".tables" 2>/dev/null | tr '\n' ' ')
    ROWS=$(sqlite3 "$F" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "?")
    echo "  $F ($SIZE) — $ROWS tables: $TABLES"
done
echo ""

# 3. Check prisma schema @@map
echo "=== STEP 3: Prisma schema @@map check ==="
if [ -f "prisma/schema.prisma" ]; then
    MAP_COUNT=$(grep -c "@@map" prisma/schema.prisma 2>/dev/null || echo "0")
    echo "[OK] @@map count: $MAP_COUNT"
    if [ "$MAP_COUNT" -lt 10 ]; then
        echo "[WARN] Schema may be missing @@map annotations!"
        echo "       Copy fixed schema..."
        if [ -f "dinoz-v4-fix/schema.prisma" ]; then
            cp dinoz-v4-fix/schema.prisma prisma/schema.prisma
            echo "[OK] Fixed schema applied"
        fi
    fi
else
    echo "[ERROR] prisma/schema.prisma not found!"
fi
echo ""

# 4. Fix DATABASE_URL to point to project root database.sqlite
echo "=== STEP 4: Fix DATABASE_URL ==="
# Remove old DATABASE_URL line and set correct one
if grep -q "DATABASE_URL" .env 2>/dev/null; then
    sed -i '/^DATABASE_URL=/d' .env
fi
echo 'DATABASE_URL="file:./database.sqlite"' >> .env
echo "[OK] DATABASE_URL set to: file:./database.sqlite"
echo ""

# 5. Show updated .env
echo "=== Updated .env ==="
cat .env | grep -v "^#" | grep -v "^$"
echo ""

# 6. Check if users table exists in the target database
echo "=== STEP 5: Verify target database ==="
TARGET_DB="$PROJECT_DIR/database.sqlite"
if [ -f "$TARGET_DB" ]; then
    TABLES=$(sqlite3 "$TARGET_DB" ".tables" 2>/dev/null)
    echo "[OK] Tables in database.sqlite: $TABLES"
    
    # Check for users table
    USERS_EXISTS=$(sqlite3 "$TARGET_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='users';" 2>/dev/null)
    if [ -n "$USERS_EXISTS" ]; then
        USER_COUNT=$(sqlite3 "$TARGET_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
        echo "[OK] users table exists ($USER_COUNT rows)"
    else
        echo "[WARN] users table NOT FOUND in database.sqlite"
        echo "       Need to create schema..."
    fi
else
    echo "[WARN] database.sqlite does not exist!"
fi
echo ""

# 7. Regenerate Prisma Client
echo "=== STEP 6: Regenerate Prisma Client ==="
npx prisma generate 2>&1 | tail -3
echo ""

# 8. Push schema
echo "=== STEP 7: Push Prisma schema ==="
echo "y" | npx prisma db push 2>&1 | tail -10
echo ""

# 9. Verify tables after push
echo "=== STEP 8: Final verification ==="
if [ -f "$TARGET_DB" ]; then
    echo "Tables in database.sqlite:"
    for TABLE in users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords; do
        COUNT=$(sqlite3 "$TARGET_DB" "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null || echo "N/A")
        if [ "$COUNT" != "N/A" ]; then
            printf "  %-25s %s\n" "$TABLE" "$COUNT"
        fi
    done
fi
echo ""

# 10. Restart
echo "=== STEP 9: Restart server ==="
pm2 restart link-manager
echo ""

echo "============================================"
echo "  DONE! Test login at your app URL."
echo "  If still fails: pm2 logs link-manager --lines 20"
echo "============================================"
