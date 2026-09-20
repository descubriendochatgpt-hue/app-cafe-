#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  CRITERIO: «Dos ventas simultáneas del último producto no generan stock
#             negativo.»
#
#  Se deja UN solo paquete en la tienda y se lanzan 50 ventas de golpe, de
#  verdad en paralelo y en procesos distintos. Tiene que vender exactamente
#  una, rechazar limpiamente las otras 49 y terminar con saldo cero.
#
#  Lo que se está probando es el bloqueo de fila del disparador de saldos:
#  la segunda venta espera a la primera, vuelve a leer el saldo ya confirmado
#  y es entonces cuando la restricción saldo_nunca_negativo la rechaza.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
H="${PGHOST:-/tmp}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DB="${PGDATABASE:-cafe}_concurrencia"
VENDEDORES="${VENDEDORES:-50}"
TMP="$(mktemp -d)"
psql() { command psql -h "$H" -p "$P" -U "$U" "$@"; }

echo "· preparando el escenario: un único paquete en la tienda"
PGDATABASE="$DB" "$DIR/rebuild.sh" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$DIR/tests/00_catalogo.sql"
psql -v ON_ERROR_STOP=1 -q -d "$DB" <<'SQL'
set app.rol = 'ADMIN';
do $$
declare u uuid := (select usuario_id from usuarios limit 1); r jsonb; lote text;
begin
  r := registrar_recepcion_verde(gen_random_uuid(), 'VRD-ETHYIR', 1, 'ALMACEN',
         'Imp', '2026-09-01', 8.20, u, '2026-09-01T09:00:00+02'::timestamptz);
  r := registrar_tueste(gen_random_uuid(),
         jsonb_build_array(jsonb_build_object('lote_id', r ->> 'lote_id', 'cantidad', 1)),
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 1)),
         'ALMACEN', u, '2026-09-05T08:00:00+02'::timestamptz);
  lote := r -> 'lotes' -> 0 ->> 'lote_id';
  perform registrar_traslado(gen_random_uuid(), lote, 'ALMACEN', 'TIENDA', 1, u,
            '2026-09-06T09:00:00+02'::timestamptz);
end $$;
SQL

DISPONIBLE=$(psql -tAc "select cantidad from saldos where ubicacion_id='TIENDA'" -d "$DB")
echo "  stock en tienda: $DISPONIBLE paquete"
[ "$DISPONIBLE" = "1.000" ] || { echo "el escenario no se preparó bien"; exit 1; }

echo "· lanzando $VENDEDORES ventas simultáneas del mismo paquete"
for i in $(seq 1 "$VENDEDORES"); do
  (
    if psql -v ON_ERROR_STOP=1 -q -d "$DB" -c "
      set app.rol = 'ADMIN';
      select registrar_venta(
        p_operacion_id => gen_random_uuid(),
        p_ubicacion_id => 'TIENDA',
        p_lineas => jsonb_build_array(jsonb_build_object(
                      'sku','ETHYIR-250-GR','cantidad',1,'precio_unit',12.50)),
        p_canal => 'Mostrador',
        p_usuario_id => (select usuario_id from usuarios limit 1));" \
      > "$TMP/ok.$i" 2> "$TMP/err.$i"
    then echo ok > "$TMP/r.$i"
    else echo ko > "$TMP/r.$i"
    fi
  ) &
done
wait || true

VENDIDAS=$(grep -lx ok "$TMP"/r.* 2>/dev/null | wc -l || true)
RECHAZADAS=$(grep -lx ko "$TMP"/r.* 2>/dev/null | wc -l || true)
SALDO=$(psql -tAc "select coalesce(cantidad,0) from saldos where ubicacion_id='TIENDA'" -d "$DB")
NEGATIVOS=$(psql -tAc "select count(*) from saldos where cantidad < 0" -d "$DB")
MOVS=$(psql -tAc "select count(*) from movimientos where ubicacion_id='TIENDA' and cantidad < 0" -d "$DB")
# ¿Los rechazos son por falta de stock, o por algo que no tocaba?
POR_STOCK=$(cat "$TMP"/err.* 2>/dev/null | grep -c "No hay stock" || true)

echo
echo "  vendidas ............ $VENDIDAS"
echo "  rechazadas .......... $RECHAZADAS  (por falta de stock: $POR_STOCK)"
echo "  saldo final ......... $SALDO"
echo "  saldos negativos .... $NEGATIVOS"
echo "  salidas en el libro . $MOVS"
echo

FALLOS=0
[ "$VENDIDAS"   = "1" ] || { echo "✗ se vendieron $VENDIDAS paquetes y solo había 1"; FALLOS=1; }
[ "$NEGATIVOS"  = "0" ] || { echo "✗ hay $NEGATIVOS saldos en negativo"; FALLOS=1; }
[ "$SALDO"      = "0.000" ] || { echo "✗ el saldo final es $SALDO y debería ser 0"; FALLOS=1; }
[ "$MOVS"       = "1" ] || { echo "✗ el libro tiene $MOVS salidas y debería tener 1"; FALLOS=1; }
[ "$POR_STOCK" = "$RECHAZADAS" ] || {
  echo "✗ $((RECHAZADAS - POR_STOCK)) rechazos no fueron por falta de stock:"
  cat "$TMP"/err.* | grep -v "No hay stock" | grep ERROR | sort -u | head -5
  FALLOS=1; }

if [ "$FALLOS" = "0" ]; then
  echo "CONCURRENCIA ✓  $VENDEDORES ventas a la vez, 1 servida, $RECHAZADAS rechazadas, stock 0 y sin negativos"
else
  exit 1
fi
rm -rf "$TMP"
