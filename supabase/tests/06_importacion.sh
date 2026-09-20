#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  CRITERIO DE MIGRACIÓN: «El stock que sale de las hojas es exactamente el
#  que entra en la app.»
#
#  Se importa un export de ejemplo del sistema antiguo y se compara con la
#  propia hoja. Cero diferencias, o no hay corte que valga.
#  De paso se comprueba que reimportar no duplica nada.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd "$(dirname "$0")/../.."
H="${PGHOST:-/tmp}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DB="${PGDATABASE:-cafe}_importacion"
TMP="$(mktemp -d)"
q() { psql -h "$H" -p "$P" -U "$U" -d "$DB" "$@"; }

PGDATABASE="$DB" ./supabase/rebuild.sh >/dev/null || exit 1

node scripts/importar.mjs --entrada scripts/ejemplo-export \
  --salida "$TMP/importacion.sql" --fecha 2026-09-20 2>"$TMP/avisos.txt" || exit 1
node scripts/importar.mjs --entrada scripts/ejemplo-export \
  --comparar > "$TMP/comparacion.sql" 2>/dev/null || exit 1

if ! q -v ON_ERROR_STOP=1 -q -f "$TMP/importacion.sql" >/dev/null 2>"$TMP/error.txt"; then
  echo "IMPORTACIÓN ✗  el SQL generado no se pudo aplicar:"; tail -5 "$TMP/error.txt"; exit 1
fi

DIFS=$(q -tAc "$(cat "$TMP/comparacion.sql" | tr '\n' ' ' | sed 's/;.*//')" 2>/dev/null | wc -l)
MOVS_1=$(q -tAc "select count(*) from movimientos")

# Reimportar: los identificadores son deterministas, así que la base
# reconoce las operaciones como ya contabilizadas.
q -v ON_ERROR_STOP=1 -q -f "$TMP/importacion.sql" >/dev/null 2>&1
MOVS_2=$(q -tAc "select count(*) from movimientos")
DESC=$(q -tAc "select count(*) from app.verificar_saldos()")

FALLOS=0
[ "$DIFS" = "0" ]       || { echo "IMPORTACIÓN ✗  $DIFS lotes no cuadran con la hoja"; q -f "$TMP/comparacion.sql"; FALLOS=1; }
[ "$MOVS_1" = "$MOVS_2" ] || { echo "IMPORTACIÓN ✗  reimportar pasó de $MOVS_1 a $MOVS_2 movimientos"; FALLOS=1; }
[ "$DESC" = "0" ]       || { echo "IMPORTACIÓN ✗  $DESC saldos no cuadran con el libro"; FALLOS=1; }

if [ "$FALLOS" = "0" ]; then
  AVISOS=$(grep -c '·' "$TMP/avisos.txt" 2>/dev/null || echo 0)
  echo "IMPORTACIÓN ✓  stock idéntico a la hoja, reimportar no duplica ($MOVS_1 movimientos, $AVISOS aviso(s))"
fi
rm -rf "$TMP"
exit $FALLOS
