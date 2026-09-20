#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  CRITERIO: «Reprocesar el histórico de eventos produce exactamente el mismo
#             stock final.»
#
#  No se compara la proyección consigo misma, que no demostraría nada. Se
#  levanta una base VACÍA, se le da el mismo catálogo de partida y se le
#  reproduce el histórico llamando a las mismas funciones de dominio. Después
#  se comparan los saldos de las dos bases, lote a lote y ubicación a ubicación.
#
#  Las ventas no guardan qué lote consumieron: al reproducirlas se vuelven a
#  resolver. Que el resultado coincida es lo que prueba que la asignación de
#  lote es determinista.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
H="${PGHOST:-/tmp}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
ORIGEN="${PGDATABASE:-cafe}"
COPIA="${ORIGEN}_replay"
TMP="$(mktemp -d)"; chmod 755 "$TMP"
psql() { command psql -h "$H" -p "$P" -U "$U" -v ON_ERROR_STOP=1 "$@"; }

echo "· levantando base de reproducción ($COPIA)"
PGDATABASE="$COPIA" "$DIR/rebuild.sh" >/dev/null

echo "· copiando el catálogo (maestros, no hechos)"
psql -d "$COPIA" -q -c "delete from parametros; delete from ubicaciones; delete from usuarios;"
pg_dump -h "$H" -p "$P" -U "$U" -d "$ORIGEN" --data-only \
  -t usuarios -t cafes -t formatos -t articulos -t precios \
  -t clientes -t mapeo_articulos -t parametros -t ubicaciones \
  | psql -d "$COPIA" -q

echo "· exportando el histórico"
psql -d "$ORIGEN" -tAc "select app.exportar_historico()" > "$TMP/historico.json"
chmod 644 "$TMP/historico.json"
OPS=$(psql -d "$ORIGEN" -tAc "select count(*) from operaciones")
echo "  $OPS operaciones"

echo "· reproduciendo"
psql -d "$COPIA" -tAc "
  set app.rol = 'ADMIN';
  select app.reproducir(pg_read_file('$TMP/historico.json')::jsonb);"

echo "· comparando saldos"
CONSULTA="select lote_id, ubicacion_id, cantidad from saldos order by lote_id, ubicacion_id"
psql -d "$ORIGEN" -tAF'|' -c "$CONSULTA" > "$TMP/original.txt"
psql -d "$COPIA"  -tAF'|' -c "$CONSULTA" > "$TMP/copia.txt"

if diff -u "$TMP/original.txt" "$TMP/copia.txt" > "$TMP/diff.txt"; then
  echo "REPRODUCIBILIDAD ✓  $(wc -l < "$TMP/original.txt") saldos idénticos tras reproducir $OPS operaciones"
else
  echo "REPRODUCIBILIDAD ✗  el stock reproducido NO coincide:"
  cat "$TMP/diff.txt"
  exit 1
fi

# La proyección también tiene que cuadrar con el libro en las dos bases.
for db in "$ORIGEN" "$COPIA"; do
  D=$(psql -d "$db" -tAc "select count(*) from app.verificar_saldos()")
  if [ "$D" != "0" ]; then
    echo "DESCUADRE ✗  $db tiene $D saldos que no cuadran con el libro"
    psql -d "$db" -c "select * from app.verificar_saldos()"
    exit 1
  fi
done
echo "PROYECCIÓN ✓  saldos y libro cuadran en ambas bases"

# Y reconstruir la proyección desde cero debe dar lo mismo.
psql -d "$ORIGEN" -q -c "select app.recalcular_saldos()" >/dev/null
psql -d "$ORIGEN" -tAF'|' -c "$CONSULTA" > "$TMP/recalculado.txt"
if diff -q "$TMP/original.txt" "$TMP/recalculado.txt" >/dev/null; then
  echo "RECÁLCULO ✓  reconstruir los saldos desde el libro da el mismo resultado"
else
  echo "RECÁLCULO ✗"; diff -u "$TMP/original.txt" "$TMP/recalculado.txt"; exit 1
fi

rm -rf "$TMP"
