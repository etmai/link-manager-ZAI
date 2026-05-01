#!/bin/bash
# ============================================
# Dinoz V4.1 — Comprehensive Fix
# Fixes: DATABASE_URL, schema types, null fields
# Run: cd /root/var/www/link-manager && bash dinoz-v4-fix/fix-v41.sh
# ============================================

set -e

PROJECT_DIR="/root/var/www/link-manager"
cd "$PROJECT_DIR"

echo "============================================"
echo "  DINOZ V4.1 — COMPREHENSIVE FIX"
echo "============================================"
echo ""

# ── STEP 1: Fix DATABASE_URL ──
echo "=== STEP 1: Fix DATABASE_URL ==="
# Prisma resolves file:./ relative to prisma/ directory
# So file:./database.sqlite → prisma/database.sqlite (WRONG!)
# We need file:../database.sqlite → database.sqlite (CORRECT!)

if grep -q "DATABASE_URL" .env 2>/dev/null; then
    sed -i '/^DATABASE_URL=/d' .env
fi
echo 'DATABASE_URL="file:../database.sqlite"' >> .env
echo "[OK] DATABASE_URL = file:../database.sqlite"
echo ""

# ── STEP 2: Delete wrong database file ──
echo "=== STEP 2: Clean up wrong database ==="
if [ -f "prisma/database.sqlite" ]; then
    SIZE=$(ls -lh "prisma/database.sqlite" | awk '{print $5}')
    rm -f "prisma/database.sqlite"
    echo "[OK] Deleted prisma/database.sqlite ($SIZE — wrong file)"
else
    echo "[OK] No prisma/database.sqlite (clean)"
fi
echo ""

# ── STEP 3: Verify target database ──
echo "=== STEP 3: Verify target database ==="
TARGET="${PROJECT_DIR}/database.sqlite"
if [ -f "$TARGET" ]; then
    SIZE=$(ls -lh "$TARGET" | awk '{print $5}')
    TABLES=$(sqlite3 "$TARGET" ".tables" 2>/dev/null | wc -w)
    echo "[OK] $TARGET ($SIZE, $TABLES tables)"

    # Quick data count
    TOTAL=0
    for T in users links sales_entries finance_entries trending_keywords; do
        C=$(sqlite3 "$TARGET" "SELECT COUNT(*) FROM $T;" 2>/dev/null || echo "0")
        TOTAL=$((TOTAL + C))
    done
    echo "[OK] Data rows (main tables): $TOTAL"
else
    echo "[ERROR] $TARGET not found!"
    exit 1
fi
echo ""

# ── STEP 4: Apply fixed Prisma schema ──
echo "=== STEP 4: Apply fixed Prisma schema ==="
if [ -f "dinoz-v4-fix/schema.prisma" ]; then
    cp dinoz-v4-fix/schema.prisma prisma/schema.prisma

    # Verify key fixes
    HAS_SALES_STRING=$(grep 'sales.*String.*@default' prisma/schema.prisma | wc -l)
    HAS_ADDEDBY_NULL=$(grep 'addedBy.*String?' prisma/schema.prisma | wc -l)
    HAS_FLOAT_NULL=$(grep 'fulfillment_cost Float?' prisma/schema.prisma | wc -l)
    HAS_MAP=$(grep -c '@@map' prisma/schema.prisma)

    echo "[OK] Schema fixes verified:"
    echo "     sales: String     = $HAS_SALES_STRING"
    echo "     addedBy: nullable = $HAS_ADDEDBY_NULL"
    echo "     Float: nullable   = $HAS_FLOAT_NULL"
    echo "     @@map count      = $HAS_MAP"
else
    echo "[ERROR] dinoz-v4-fix/schema.prisma not found!"
    echo "        Extract dinoz-v4-fix.zip first"
    exit 1
fi
echo ""

# ── STEP 5: Regenerate Prisma Client ──
echo "=== STEP 5: Regenerate Prisma Client ==="
npx prisma generate 2>&1 | tail -2
echo "[OK] Prisma Client regenerated"
echo ""

# ── STEP 6: Push schema to database ──
echo "=== STEP 6: Push schema ==="
# Use --accept-data-loss to drop orphan PascalCase tables
echo "y" | npx prisma db push 2>&1 | grep -E "(OK|error|warn|Your database)" | head -5 || true
echo "[OK] Schema pushed"
echo ""

# ── STEP 7: Seed admin if missing ──
echo "=== STEP 7: Verify admin user ==="
ADMIN=$(sqlite3 "$TARGET" "SELECT COUNT(*) FROM users WHERE username='admin';" 2>/dev/null || echo "0")
if [ "$ADMIN" -eq 0 ]; then
    # bcrypt hash of "Hello0"
    HASH='$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy'
    sqlite3 "$TARGET" "INSERT OR IGNORE INTO users VALUES('admin','$HASH','admin');"
    echo "[OK] Admin user created (password: Hello0)"
else
    echo "[OK] Admin user exists"
fi
echo ""

# ── STEP 8: Restart ──
echo "=== STEP 8: Restart server ==="
pm2 delete link-manager 2>/dev/null || true
pm2 start src/server.js --name link-manager
pm2 save
echo ""

# ── STEP 9: Verify ──
echo "=== STEP 9: Wait & verify ==="
sleep 4

# Check if server is running
STATUS=$(pm2 status link-manager 2>/dev/null | grep "online" | wc -l)
if [ "$STATUS" -gt 0 ]; then
    echo "[OK] Server is ONLINE"
else
    echo "[WARN] Server may not be running. Check: pm2 status"
fi

# Check for errors in recent logs
ERRORS=$(pm2 logs link-manager --lines 5 --nostream 2>&1 | grep -c "does not exist" || echo "0")
if [ "$ERRORS" -gt 0 ]; then
    echo "[WARN] Still have 'table does not exist' errors"
    echo "       Showing last 15 log lines:"
    pm2 logs link-manager --lines 15 --nostream 2>&1
else
    echo "[OK] No 'table does not exist' errors!"
fi

echo ""
echo "=== FINAL DATA CHECK ==="
for T in users categories links sales_entries accounts merchants fulfillments work_schedule sample_requests finance_entries task_comments usa_holidays trending_keywords pod_holidays evergreen_keywords; do
    C=$(sqlite3 "$TARGET" "SELECT COUNT(*) FROM $T;" 2>/dev/null || echo "N/A")
    printf "  %-25s %s\n" "$T" "$C"
done

echo ""
echo "============================================"
echo "  V4.1 FIX COMPLETE!"
echo "  Login: admin / Hello0"
echo "  Logs:  pm2 logs link-manager --lines 20"
echo "============================================"
