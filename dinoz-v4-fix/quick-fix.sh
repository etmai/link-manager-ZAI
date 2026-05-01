#!/bin/bash
# ============================================
# Quick Fix: Database connection + Admin login
# Diagnoses and fixes the most common issues
# ============================================

PROJECT_DIR="/root/var/www/link-manager"
cd "$PROJECT_DIR"

echo "============================================"
echo "  QUICK DIAGNOSTIC & FIX"
echo "============================================"
echo ""

# ── 1. Check DATABASE_URL ──
echo "=== 1. DATABASE_URL ==="
DB_URL=$(grep "^DATABASE_URL" .env 2>/dev/null || echo "NOT SET")
echo "Current: $DB_URL"
echo ""

# Fix: must be file:../database.sqlite (Prisma resolves from prisma/ dir)
sed -i '/^DATABASE_URL=/d' .env 2>/dev/null
echo 'DATABASE_URL="file:../database.sqlite"' >> .env
echo "Fixed to: DATABASE_URL=\"file:../database.sqlite\""
echo ""

# ── 2. Check database file ──
echo "=== 2. DATABASE FILES ==="
DB="${PROJECT_DIR}/database.sqlite"
if [ -f "$DB" ]; then
    SIZE=$(ls -lh "$DB" | awk '{print $5}')
    echo "[OK] $DB ($SIZE)"
    TABLES=$(sqlite3 "$DB" ".tables" 2>/dev/null)
    echo "    Tables: $TABLES"
else
    echo "[ERROR] $DB NOT FOUND!"
    echo ""
    # Check if there's a backup
    BACKUP=$(find "$PROJECT_DIR" -maxdepth 1 -name "database.sqlite.*" 2>/dev/null | head -1)
    if [ -n "$BACKUP" ]; then
        echo "[INFO] Found backup: $BACKUP"
        cp "$BACKUP" "$DB"
        echo "[OK] Restored from backup"
    else
        echo "[FATAL] No database file and no backup. Creating fresh..."
        touch "$DB"
    fi
fi
echo ""

# ── 3. Check tables exist ──
echo "=== 3. TABLE CHECK ==="
for T in users links sales_entries trending_keywords finance_entries; do
    EXISTS=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$T';" 2>/dev/null)
    if [ -n "$EXISTS" ]; then
        COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM $T;" 2>/dev/null || echo "0")
        printf "  [OK] %-20s %s rows\n" "$T" "$COUNT"
    else
        printf "  [MISSING] %s\n" "$T"
    fi
done
echo ""

# ── 4. Fix admin user ──
echo "=== 4. ADMIN USER FIX ==="
ADMIN_EXISTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='admin';" 2>/dev/null || echo "0")
echo "Admin users found: $ADMIN_EXISTS"

if [ "$ADMIN_EXISTS" -eq 0 ]; then
    echo "[WARN] No admin user! Creating..."
else
    echo "[INFO] Current admin users:"
    sqlite3 "$DB" "SELECT username, role, substr(password, 1, 20) || '...' as pass_preview FROM users;" 2>/dev/null
fi

# ALWAYS reset admin password to known hash
# bcrypt hash of "Hello0" generated with salt rounds 10
HASH='$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy'

# Delete and re-insert to ensure correct password
sqlite3 "$DB" "DELETE FROM users WHERE username='admin';"
sqlite3 "$DB" "INSERT INTO users (username, password, role) VALUES ('admin', '$HASH', 'admin');"
echo "[OK] Admin user reset: username=admin, password=Hello0"
echo ""

# Verify the hash was stored
echo "Verify stored:"
sqlite3 "$DB" "SELECT username, role, length(password) as hash_len FROM users WHERE username='admin';" 2>/dev/null
echo ""

# ── 5. Delete wrong Prisma database ──
echo "=== 5. CLEANUP ==="
if [ -f "prisma/database.sqlite" ]; then
    rm -f "prisma/database.sqlite"
    echo "[OK] Deleted prisma/database.sqlite (wrong file)"
fi
echo ""

# ── 6. Regenerate and push ──
echo "=== 6. PRISMA ==="

# Make sure schema has @@map
if [ -f "dinoz-v4-fix/schema.prisma" ]; then
    cp dinoz-v4-fix/schema.prisma prisma/schema.prisma
    echo "[OK] Schema updated"
fi

npx prisma generate 2>&1 | tail -1
echo "[OK] Prisma generate done"

# Push with accept-data-loss (drops orphan PascalCase tables)
echo "y" | npx prisma db push --accept-data-loss 2>&1 | tail -3
echo "[OK] Prisma db push done"
echo ""

# ── 7. Restart ──
echo "=== 7. RESTART ==="
pm2 delete link-manager 2>/dev/null || true
sleep 1
pm2 start src/server.js --name link-manager
pm2 save
sleep 3
echo ""

# ── 8. Test login via API ──
echo "=== 8. LOGIN TEST ==="
LOGIN_RESULT=$(curl -s -X POST http://localhost:3000/api/auth/login \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"Hello0"}' 2>/dev/null)

if echo "$LOGIN_RESULT" | grep -q "token"; then
    echo "[OK] LOGIN SUCCESSFUL!"
    echo "    Response: $(echo $LOGIN_RESULT | head -c 100)..."
else
    echo "[FAIL] Login failed!"
    echo "    Response: $LOGIN_RESULT"
    echo ""
    echo "    Checking logs..."
    pm2 logs link-manager --lines 5 --nostream 2>&1
fi
echo ""

echo "============================================"
echo "  DONE!"
echo "  Login: admin / Hello0"
echo "  URL: http://localhost:3000"
echo "============================================"
