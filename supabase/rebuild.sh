#!/usr/bin/env bash
# Reconstruye la base desde cero aplicando todas las migraciones en orden.
# Es la comprobación de que el esquema nace limpio, no solo de que evoluciona.
set -euo pipefail
PSQL="psql -h ${PGHOST:-/tmp} -p ${PGPORT:-5433} -U ${PGUSER:-postgres} -v ON_ERROR_STOP=1 -q"
DB="${PGDATABASE:-cafe}"

$PSQL -d postgres -c "drop database if exists $DB with (force)" >/dev/null
$PSQL -d postgres -c "create database $DB" >/dev/null

for f in "$(dirname "$0")"/migrations/*.sql; do
  printf '  → %s\n' "$(basename "$f")"
  $PSQL -d "$DB" -f "$f"
done
echo "✓ esquema reconstruido"
