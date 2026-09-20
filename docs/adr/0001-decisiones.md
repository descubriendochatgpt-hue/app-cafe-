# Decisiones de arquitectura

Registro breve de por qué las cosas son como son, para que dentro de seis
meses nadie las deshaga sin saber qué se rompe.

---

## 1 · Supabase (Postgres) como maestro único

**Decidido por el cliente antes de empezar.** Se descartó Notion como almacén
transaccional de stock: sin transacciones, sin bloqueo de filas y con un
límite de unas 3 peticiones por segundo, dos ventas concurrentes descuadrarían
el inventario.

Esa decisión resulta ser la que sostiene todo lo demás: la garantía de
no-negatividad bajo concurrencia es un `CHECK` sobre una fila bloqueada, y eso
necesita un Postgres de verdad.

---

## 2 · Libro inmutable con proyección de saldos

**Alternativa descartada:** una columna `stock` que se actualiza.

Un campo que se sobrescribe no puede explicar un descuadre: cuando el número
está mal, no queda rastro de cómo llegó ahí. El libro sí, y por eso se puede
cumplir «todo descuadre es trazable hasta el evento y el canal que lo originó».

**Tensión asumida:** `saldos` es un caché, y un caché puede desincronizarse.
Se mitiga con tres cosas: solo lo escribe un disparador, `verificar_saldos()`
lo compara con el libro y debe dar cero filas, y `recalcular_saldos()` lo
reconstruye desde cero.

**Bache encontrado al implementarlo:** el patrón `INSERT … ON CONFLICT DO
UPDATE` no vale aquí. Postgres evalúa las restricciones `CHECK` sobre la fila
*propuesta* antes de resolver el conflicto, así que una salida de 20 sobre un
saldo de 60 proponía `cantidad = -20` y saltaba la restricción aunque el
resultado correcto fuese 40: **ningún movimiento negativo funcionaba**. Se
resolvió con `UPDATE` primero e `INSERT` solo si no existía la fila. El
`UPDATE` además toma el bloqueo, que es lo que se quería.

---

## 3 · Idempotencia con UUID generado en el cliente

**Alternativa descartada:** que el servidor genere el identificador.

No sirve con cola offline. Si el móvil graba una venta sin cobertura y la sube
dos veces, el servidor generaría dos identificadores y contabilizaría dos
ventas. Que el UUID nazca en el móvil, antes de saber si hay red, es lo que
permite reintentar a ciegas.

La segunda clave, `(origen, origen_id)`, cubre la otra repetición real: los
reenvíos de webhook de Loyverse y WooCommerce, que llegan con el mismo
identificador de recibo pero serían operaciones distintas.

---

## 4 · Lote activo por ubicación, deducido del escaneo

**Alternativa descartada:** FIFO global en todos los canales.

FIFO es determinista y cómodo, pero miente sobre la realidad física: si en la
tienda está abierta la caja del lote B, las ventas de esa tienda son del lote
B aunque quede lote A en el almacén.

**Tensión con «cero entrada manual», y cómo se resuelve:** el lote activo no
se declara en un formulario. Reponer ya es un traslado escaneado, y ese gesto
deja la marca que luego usan los webhooks. Si el lote activo no llega para
cubrir una venta, el resto va a conciliación en vez de repartirse en silencio.

**Excepción asumida:** el depósito de El Corte Inglés es FIFO por fuerza. Sus
tiendas mezclan lotes y reportan ventas agregadas, así que ahí la trazabilidad
por lote será siempre aproximada. Conviene saberlo antes de prometérsela a
nadie.

---

## 5 · La app no emite documentos fiscales

Loyverse y WooCommerce ya son emisores con Verifactu. Las facturas de ECI y
hostelería las emite la gestoría a partir de lo que exporte la app.

La app guarda la referencia (`pedidos.documento_fiscal` y
`documento_fiscal_sistema`) y nunca genera numeración propia, para no duplicar
registros ante la AEAT.

Esto **cambia respecto al sistema anterior**, que sí emitía facturas con serie
correlativa. Esa funcionalidad no se porta.

---

## 6 · El Corte Inglés, manual en esta fase

**Decisión del cliente:** ECI es una prueba comercial, y automatizar EDI antes
de saber si el canal cuaja es trabajo a fondo perdido.

Lo que sí se ha hecho es dejarlo modelado: `DEPOSITO_ECI` es una ubicación de
tipo `DEPOSITO` como cualquier otra, y `v_deposito` calcula el invariante y la
antigüedad. Los apuntes se cargan a mano.

**Lo que esto compra:** el día que haya integración, el conector escribe las
mismas operaciones que ahora teclea una persona. No hay que rehacer el modelo,
solo añadir quién las escribe.

---

## 7 · Todo el acceso pasa por el servidor

**Alternativa descartada:** que el navegador hable directamente con Supabase.

Es lo habitual con Supabase y habría sido menos código. Se descarta porque
parte el control de acceso en dos sitios y obliga a repartir la clave pública.
Con todo el acceso en rutas de servidor, el navegador no lleva ninguna clave y
las políticas RLS siguen aplicándose como segunda capa, porque el servidor
llama con el JWT de la persona y no con la clave de servicio.

La clave de servicio se reserva a los conectores automáticos, donde no hay
nadie detrás.
