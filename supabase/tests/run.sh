#!/usr/bin/env bash
# Suite completa: reconstruye la base, carga el escenario y verifica los
# criterios de aceptación del núcleo de inventario.
set -uo pipefail
cd "$(dirname "$0")/.."
H="${PGHOST:-/tmp}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"; DB="${PGDATABASE:-cafe}"
q() { psql -h "$H" -p "$P" -U "$U" -v ON_ERROR_STOP=1 -q -d "$DB" "$@"; }
FALLOS=0

echo "════ esquema ════"
./rebuild.sh || exit 1

echo
echo "════ escenario ════"
q -f tests/00_catalogo.sql && echo "  catálogo cargado"
q -f tests/01_historia.sql 2>&1 | grep -E "NOTICE" | sed 's/^psql.*NOTICE:  /  /'

echo
echo "════ criterios de aceptación ════"
for t in tests/02_idempotencia.sql tests/05_deposito.sql tests/07_loyverse.sql tests/08_pedidos_canal.sql tests/09_hosteleria.sql tests/10_seguridad.sql tests/11_bot.sql tests/12_bultos.sql tests/13_panel.sql tests/14_avisos.sql; do
  if out=$(q -f "$t" 2>&1); then
    echo "$out" | grep -oE "(IDEMPOTENCIA|DEPÓSITO|CONECTOR|PEDIDOS DE CANAL|HOSTELERÍA|SEGURIDAD|BOT|BULTOS|PANEL|AVISOS) ✓.*" | sed 's/^/  /'
  else
    echo "  ✗ $t"; echo "$out" | grep -E "WARNING|ERROR" | sed 's/^/     /'; FALLOS=1
  fi
done

for t in tests/03_reproducibilidad.sh tests/04_concurrencia.sh tests/06_importacion.sh; do
  if out=$("./$t" 2>&1); then
    echo "$out" | grep -oE "(REPRODUCIBILIDAD|PROYECCIÓN|RECÁLCULO|CONCURRENCIA|IMPORTACIÓN) ✓.*" | sed 's/^/  /'
  else
    echo "  ✗ $t"; echo "$out" | tail -12 | sed 's/^/     /'; FALLOS=1
  fi
done

echo
if [ "$FALLOS" = "0" ]; then echo "════ todo en verde ════"; else echo "════ HAY FALLOS ════"; fi
exit $FALLOS
