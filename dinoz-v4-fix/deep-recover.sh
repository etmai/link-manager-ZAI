#!/bin/bash
# ============================================
# Dinoz Link Manager — Deep Database Recovery
# Scans ALL tables, freed pages, backup files
# ============================================

DB_FILE="/root/var/www/link-manager/database.sqlite"

echo "============================================"
echo "  DEEP DATABASE SCAN & RECOVERY"
echo "============================================"
echo ""

# 1. File info
echo "=== FILE INFO ==="
if [ -f "$DB_FILE" ]; then
    ls -lh "$DB_FILE"
    file "$DB_FILE"
    echo ""
else
    echo "Database file not found!"
    exit 1
fi

# 2. ALL tables (including system)
echo "=== ALL TABLES (including system) ==="
sqlite3 "$DB_FILE" "SELECT type, name FROM sqlite_master ORDER BY type, name;"
echo ""

# 3. Count rows in EVERY table that exists
echo "=== ROW COUNT PER TABLE ==="
TABLES=$(sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
TOTAL=0
for TABLE in $TABLES; do
    COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM [$TABLE];" 2>/dev/null || echo "ERROR")
    printf "  %-35s %s rows\n" "$TABLE" "$COUNT"
    if [ "$COUNT" != "ERROR" ]; then
        TOTAL=$((TOTAL + COUNT))
    fi
done
echo "  ----------------------------------------"
echo "  TOTAL:                                  $TOTAL rows"
echo ""

# 4. Try SQLite .recover (extracts data from freed pages)
echo "=== ATTEMPTING DATA RECOVERY FROM RAW PAGES ==="
echo "    (This extracts deleted data still in the file)"

RECOVERY_SQL="/tmp/dinoz-recovery-$(date +%s).sql"

sqlite3 "$DB_FILE" ".recover" > "$RECOVERY_SQL" 2>/dev/null

if [ -s "$RECOVERY_SQL" ]; then
    echo "[OK] Recovery SQL generated: $RECOVERY_SQL ($(ls -lh "$RECOVERY_SQL" | awk '{print $5}'))"
    echo ""
    echo "=== RECOVERY SQL PREVIEW (first 100 lines) ==="
    head -100 "$RECOVERY_SQL"
    echo ""
    echo "=== FULL RECOVERY SQL SAVED TO: $RECOVERY_SQL ==="
    echo "    Total lines: $(wc -l < "$RECOVERY_SQL")"
    echo ""
    echo "    Data tables found in recovery:"
    grep -oP 'CREATE TABLE \K[^ (]+' "$RECOVERY_SQL" 2>/dev/null | sort -u
    echo ""
    echo "    INSERT statements per table:"
    grep -oP "INSERT INTO \K[^ (]+" "$RECOVERY_SQL" 2>/dev/null | sort | uniq -c | sort -rn
else
    echo "[WARN] .recover produced no output."
    echo "       Trying alternative: .dump"
    sqlite3 "$DB_FILE" ".dump" > "$RECOVERY_SQL" 2>/dev/null
    if [ -s "$RECOVERY_SQL" ]; then
        echo "[OK] .dump produced output: $(wc -l < "$RECOVERY_SQL") lines"
        head -50 "$RECOVERY_SQL"
    else
        echo "[FAIL] No data recoverable from this file."
    fi
fi
echo ""

# 5. Search for backup files EVERYWHERE
echo "=== SEARCHING FOR BACKUP FILES ==="
echo "    Scanning /root for database backups..."
find /root -type f \( -name "*.sqlite" -o -name "*.sqlite3" -o -name "*.db" \) 2>/dev/null | while read F; do
    SIZE=$(ls -lh "$F" | awk '{print $5}')
    MOD=$(stat -c %y "$F" 2>/dev/null | cut -d'.' -f1)
    ROWS=$(sqlite3 "$F" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "?")
    echo "  $F ($SIZE, modified: $MOD, $ROWS tables)"
done
echo ""

# 6. Check for WAL/journal files
echo "=== WAL / JOURNAL FILES ==="
find /root/var/www/link-manager -type f \( -name "*.wal" -o -name "*.journal" -o -name "-wal" -o -name "-journal" \) 2>/dev/null | while read F; do
    SIZE=$(ls -lh "$F" | awk '{print $5}')
    echo "  $F ($SIZE)"
done
if [ -z "$(find /root/var/www/link-manager -type f \( -name "*.wal" -o -name "*.journal" -o -name "-wal" -o -name "-journal" \) 2>/dev/null)" ]; then
    echo "  (No WAL/journal files found)"
fi
echo ""

# 7. Check if there's recoverable data in the raw SQLite header
echo "=== SQLITE FILE HEADER ==="
sqlite3 "$DB_FILE" "PRAGMA page_count; PRAGMA page_size; PRAGMA integrity_check;" 2>/dev/null
echo ""

echo "============================================"
echo "  SCAN COMPLETE"
echo "============================================"
