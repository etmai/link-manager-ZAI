#!/bin/bash
# ============================================
# Dinoz — COMPLETE SELF-CONTAINED FIX
# Writes schema directly, generates bcrypt on server
# Run: cd /root/var/www/link-manager && bash dinoz-v4-fix/full-fix.sh
# ============================================

set -e

cd /root/var/www/link-manager

echo "============================================"
echo "  COMPLETE FIX — SELF CONTAINED"
echo "============================================"
echo ""

# ═══════════════════════════════════════════
# PHASE 1: Stop everything
# ═══════════════════════════════════════════
echo "=== PHASE 1: Stop server ==="
pm2 stop link-manager 2>/dev/null || true
pm2 delete link-manager 2>/dev/null || true
echo "[OK] Server stopped"
echo ""

# ═══════════════════════════════════════════
# PHASE 2: Fix DATABASE_URL
# ═══════════════════════════════════════════
echo "=== PHASE 2: Fix DATABASE_URL ==="
# Prisma resolves file:./ relative to prisma/ directory
# file:../database.sqlite → project root (CORRECT)
sed -i '/^DATABASE_URL=/d' .env 2>/dev/null || true
echo 'DATABASE_URL="file:../database.sqlite"' >> .env
grep "DATABASE_URL" .env
echo ""

# ═══════════════════════════════════════════
# PHASE 3: Write correct schema.prisma DIRECTLY
# ═══════════════════════════════════════════
echo "=== PHASE 3: Write schema.prisma (directly) ==="
mkdir -p prisma

cat > prisma/schema.prisma << 'SCHEMA_EOF'
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "sqlite"
  url      = env("DATABASE_URL")
}

model User {
  username String @id
  password String
  role     String
  salesEntries      SalesEntry[]
  workSchedule      WorkSchedule[]
  sampleRequests    SampleRequest[]
  financeEntries    FinanceEntry[]
  taskComments      TaskComment[]
  scheduleCreatedBy WorkSchedule[] @relation("ScheduleCreator")
  @@map("users")
}

model Category {
  name String @id
  @@map("categories")
}

model Link {
  id         String  @id @default(uuid())
  url        String
  date       String
  categories String  @default("[]")
  updatedAt  String?
  createdAt  String
  addedBy    String?
  updatedBy  String?
  @@map("links")
}

model SalesEntry {
  id          String  @id @default(uuid())
  account     String
  merchant    String  @default("")
  category    String  @default("")
  fulfillment String  @default("")
  design_id   String  @default("")
  sku         String
  title       String  @default("")
  ord_id      String  @default("")
  custom      String  @default("")
  size        String  @default("N/A")
  filename    String  @default("")
  sales       String  @default("0")
  date        String
  createdAt   String
  addedBy     String?
  user        User?   @relation(fields: [addedBy], references: [username])
  @@map("sales_entries")
}

model Account {
  id   String @id @default(uuid())
  name String @unique
  @@map("accounts")
}

model Merchant {
  id   String @id @default(uuid())
  name String @unique
  @@map("merchants")
}

model Fulfillment {
  id   String @id @default(uuid())
  name String @unique
  @@map("fulfillments")
}

model WorkSchedule {
  id           String  @id @default(uuid())
  title        String
  description  String?
  date         String
  userId       String
  status       String  @default("pending")
  createdBy    String?
  creatorRole  String  @default("user")
  createdAt    String
  trelloCardId String?
  categories   String  @default("[]")
  user         User?   @relation(fields: [userId], references: [username])
  creator      User?   @relation("ScheduleCreator", fields: [createdBy], references: [username])
  comments     TaskComment[]
  @@map("work_schedule")
}

model SampleRequest {
  id          String @id @default(uuid())
  designId    String
  requester   String
  requestDate String
  status      String  @default("Process")
  productLink String  @default("N/A")
  expiryDate  String  @default("N/A")
  createdAt   String
  user        User?   @relation(fields: [requester], references: [username])
  @@map("sample_requests")
}

model FinanceEntry {
  id               String  @id @default(uuid())
  date             String
  fulfillment_cost Float?
  fulfillment_note String  @default("")
  other_cost       Float?
  other_note       String  @default("")
  payment          Float?
  payment_note     String  @default("")
  createdAt        String
  addedBy          String?
  user             User?   @relation(fields: [addedBy], references: [username])
  @@map("finance_entries")
}

model TaskComment {
  id        String       @id @default(uuid())
  taskId    String
  username  String
  content   String
  createdAt String
  task      WorkSchedule @relation(fields: [taskId], references: [id])
  user      User?        @relation(fields: [username], references: [username])
  @@map("task_comments")
}

model UsaHoliday {
  id             String  @id @default(uuid())
  name           String
  date           String
  days_left      Int?
  priority_group String?
  updatedAt      String
  @@map("usa_holidays")
}

model TrendingKeyword {
  id                 String  @id @default(uuid())
  keyword            String  @unique
  heat_score         Int     @default(50)
  category           String  @default("general")
  ai_summary         String?
  search_url_etsy    String?
  search_url_amazon  String?
  search_url_pinterest String?
  is_pinned          Int     @default(0)
  source             String  @default("google_trends")
  fetched_at         String?
  @@map("trending_keywords")
}

model PodHoliday {
  id         Int    @id @default(autoincrement())
  name       String
  date       String
  heat_score Int    @default(50)
  prep_start String?
  emoji      String @default("")
  @@map("pod_holidays")
}

model EvergreenKeyword {
  id        String  @id @default(uuid())
  keyword   String  @unique
  category  String?
  source    String  @default("google_sheet")
  createdAt String?
  @@map("evergreen_keywords")
}
SCHEMA_EOF

# Verify key fields
echo "Schema verification:"
grep "sales" prisma/schema.prisma | head -2
grep "addedBy" prisma/schema.prisma | head -2
echo "@@map count: $(grep -c '@@map' prisma/schema.prisma)"
echo ""

# ═══════════════════════════════════════════
# PHASE 4: Prisma generate + db push
# ═══════════════════════════════════════════
echo "=== PHASE 4: Prisma generate ==="
npx prisma generate 2>&1 | tail -2
echo ""

echo "=== PHASE 4b: Prisma db push ==="
echo "y" | npx prisma db push 2>&1 | tail -5
echo ""

# Delete wrong Prisma database
if [ -f "prisma/database.sqlite" ]; then
    rm -f "prisma/database.sqlite"
    echo "[OK] Deleted prisma/database.sqlite"
fi
echo ""

# ═══════════════════════════════════════════
# PHASE 5: Generate bcrypt hash ON SERVER
# then insert admin AFTER prisma push
# ═══════════════════════════════════════════
echo "=== PHASE 5: Generate bcrypt hash & insert admin ==="

HASH=$(node -e "
const bcrypt = require('bcryptjs');
bcrypt.hash('Hello0', 10).then(h => console.log(h));
")

if [ -z "$HASH" ]; then
    echo "[ERROR] Failed to generate bcrypt hash!"
    exit 1
fi

echo "[OK] Generated hash: ${HASH:0:20}..."

# Insert admin into database.sqlite (AFTER prisma push)
DB="$PWD/database.sqlite"

if [ ! -f "$DB" ]; then
    echo "[ERROR] $DB not found!"
    exit 1
fi

sqlite3 "$DB" "DELETE FROM users WHERE username='admin';"
sqlite3 "$DB" "INSERT INTO users (username, password, role) VALUES ('admin', '$HASH', 'admin');"
echo "[OK] Admin user inserted"

# Verify
echo "Verify:"
sqlite3 "$DB" "SELECT username, role FROM users WHERE username='admin';"
echo ""

# ═══════════════════════════════════════════
# PHASE 6: Data check
# ═══════════════════════════════════════════
echo "=== PHASE 6: Data summary ==="
for T in users links sales_entries trending_keywords finance_entries evergreen_keywords usa_holidays accounts merchants fulfillments sample_requests work_schedule task_comments categories pod_holidays; do
    C=$(sqlite3 "$DB" "SELECT COUNT(*) FROM $T;" 2>/dev/null || echo "N/A")
    if [ "$C" != "0" ] && [ "$C" != "N/A" ]; then
        printf "  %-25s %s\n" "$T" "$C"
    fi
done
echo ""

# ═══════════════════════════════════════════
# PHASE 7: Start server & test login
# ═══════════════════════════════════════════
echo "=== PHASE 7: Start server ==="
pm2 start src/server.js --name link-manager
pm2 save
sleep 4
echo ""

echo "=== PHASE 8: Login test ==="
RESULT=$(curl -s -X POST http://localhost:3000/api/auth/login \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"Hello0"}')

if echo "$RESULT" | grep -q "token"; then
    echo "[OK] LOGIN SUCCESSFUL!"
    echo ""
    echo "============================================"
    echo "  ALL FIXED!"
    echo "  Login: admin / Hello0"
    echo "============================================"
else
    echo "[FAIL] Login failed!"
    echo "  Response: $RESULT"
    echo ""
    echo "  Last 10 error logs:"
    pm2 logs link-manager --lines 10 --nostream 2>&1 | grep "error\|Error\|FAIL" | head -10
fi
