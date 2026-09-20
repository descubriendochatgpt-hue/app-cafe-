# Conectores de canal

## Cómo se conecta un canal

Todo se rellena en **un único fichero**: copia `integraciones.ejemplo.env` a
`.env.local` (y los mismos valores a *Vercel → Settings → Environment
Variables*). No hay que tocar código: en cuanto están las claves, el canal se
enciende. `/ajustes/integraciones` dice cuál está lista y da las URL de
webhook listas para copiar.

Un canal sin claves queda **inactivo**, no roto: su webhook responde que no
está configurado en vez de fallar de una forma que haya que investigar.

---

## Loyverse

### Qué hay que pegar, y dónde

| Dónde | Qué |
|---|---|
| `.env.local` → `LOYVERSE_ACCESS_TOKEN` | Loyverse → Integraciones → Access tokens. Permisos: **RECEIPTS** e **ITEMS**, lectura |
| `.env.local` → `LOYVERSE_WEBHOOK_SECRET` | El secreto que muestra Loyverse al crear el webhook |
| Loyverse → Integraciones → Webhooks | `https://TU-DOMINIO/api/webhooks/loyverse`, evento `receipts.update` |

Después, en **Ajustes → Artículos de Loyverse**, empareja cada artículo del
TPV con su referencia interna. Con 20-30 referencias son diez minutos, y se
hace a mano a propósito: un emparejamiento automático por nombre se
equivocaría en silencio entre dos cafés parecidos, que es el error más caro
de detectar.

### Dos caminos que llevan al mismo sitio

**Webhook** para el tiempo real y **consulta periódica** como red de
seguridad. Un webhook se pierde más a menudo de lo que parece —un despliegue
a mitad, un corte de red, unos minutos de caída— y una venta perdida no se
detecta sola: simplemente el stock deja de cuadrar. Cada cinco minutos se
pregunta por los recibos nuevos desde el último traído, con cinco minutos de
solape.

Como todo entra indexado por **número de recibo**, que un recibo llegue por
las dos vías no lo contabiliza dos veces.

Si el plan de Loyverse no incluye webhooks, deja `LOYVERSE_WEBHOOK_SECRET`
vacío: el sistema funciona solo con la consulta periódica. Eso sí, entonces
el retraso es de hasta cinco minutos en lugar de instantáneo.

> **Atención al plan de Vercel.** El gratuito solo permite tareas
> **diarias**. Con él, el webhook sigue siendo instantáneo, pero la red de
> seguridad pasa a ser de una vez al día.

### Qué pasa con cada recibo

```
webhook / consulta
        ↓
  se guarda CRUDO en eventos_entrada        ← clave: número de recibo
        ↓
  se emparejan sus líneas con los SKU internos
        ↓
 ┌──────┴───────┐
 todos           alguno sin emparejar
 emparejados      ↓
 ↓                queda en cola + incidencia; NO se registra a medias
 venta o devolución → movimientos de stock
```

**Guardar primero, procesar después.** Si el procesamiento falla, el hecho no
se pierde: se reintenta con espera creciente (1 min → ~4 h, ocho intentos) y,
si sigue fallando, pasa a **Ajustes → Conciliación** para que lo mire alguien.

**Un recibo con artículos sin emparejar no se registra a medias.** Se queda
esperando entero. Media venta contabilizada es peor que una venta pendiente:
la pendiente se ve, la media no. Cuando emparejas el artículo y pulsas
«Reintentar», la venta se procesa completa.

### Devoluciones

Un reembolso en el TPV vuelve **a los mismos lotes de los que salió**, no al
lote activo. Si no fuera así, devolver dos bolsas de un lote viejo las metería
en el lote nuevo y la trazabilidad contaría una historia que no ocurrió.

Lo que no case con la venta original entra por el lote activo, y si no hay
ninguno, se abre una incidencia en lugar de inventarse un lote.

### Recibos anulados

No se deshacen solos. Si la venta ya se contabilizó, revertirla movería stock
que quizá se recontó entretanto. Se abre una incidencia con lo necesario para
decidir. Es de los pocos sitios donde el sistema prefiere preguntar.

### Lo que este conector NO hace

- **No sincroniza stock hacia Loyverse.** El TPV mantiene su propio
  inventario; aquí solo se leen sus ventas. Si en la tienda quieres ver el
  stock real, hoy hay que mirarlo en esta app.
- **No trae clientes.** Las ventas de mostrador van al cliente genérico.
- **No emite documentos fiscales.** Loyverse ya lo hace con su Verifactu; la
  app guarda el número de recibo como referencia y nada más.

---

## El Corte Inglés

Sin claves: durante la prueba se lleva a mano.

| Qué pasa | Qué se hace en la app |
|---|---|
| Se sirve mercancía | Escanear → Traslado → `ALMACEN` a `DEPOSITO_ECI` |
| Llega el informe mensual | Se registra como venta desde `DEPOSITO_ECI` |
| Vuelve lo no vendido | Traslado → `DEPOSITO_ECI` a `ALMACEN` |

`v_deposito` calcula en todo momento *servido − vendido − devuelto = saldo*,
con una columna `descuadre` que tiene que ser cero, y la antigüedad de cada
lote. El día que haya integración por EDI, el conector escribirá **las mismas
operaciones** y esa vista no cambia.

---

## WooCommerce

### Qué hay que pegar, y dónde

| Dónde | Qué |
|---|---|
| `.env.local` → `WOOCOMMERCE_URL` | La dirección de la tienda, sin barra final |
| `.env.local` → `WOOCOMMERCE_CONSUMER_KEY` y `_SECRET` | Ajustes → Avanzado → API REST → Añadir clave, con permiso de **Lectura/Escritura** |
| `.env.local` → `WOOCOMMERCE_WEBHOOK_SECRET` | El mismo valor que pongas en el campo «Secreto» de cada webhook |
| WooCommerce → Ajustes → Avanzado → Webhooks | `https://TU-DOMINIO/api/webhooks/woocommerce`, tres webhooks: pedido creado, actualizado y eliminado |

La escritura hace falta para lo segundo que hace este conector: publicar el
stock de vuelta en la tienda.

Después, en **Ajustes → Productos de WooCommerce**, empareja cada producto con
su referencia interna.

> **Desactiva la gestión de stock de WooCommerce** en los productos
> sincronizados. Si la dejas puesta, la tienda descontará por su cuenta además
> de recibir nuestros números, y los dos se irán separando. Aquí manda el
> stock de esta app.

### Un pedido no es un recibo

Es la diferencia de fondo con Loyverse. Un recibo de TPV es un hecho cerrado;
un pedido web es una **máquina de estados**. El mismo pedido avisa al crearse,
al pagarse, al enviarse y al reembolsarse, y cada aviso trae el pedido entero.
Contar cada aviso como una venta multiplicaría el stock que sale.

Por eso aquí no se registra una venta: se **avanza un pedido**.

| Estado en WooCommerce | Qué pasa con el stock |
|---|---|
| `pending` | Nada. Es un carrito sin pagar. |
| `processing`, `on-hold` | Se **reserva**: queda comprometido, pero sigue en el almacén. |
| `completed` | Se **sirve**: ahora sí sale del libro. |
| `cancelled`, `failed`, `refunded` | Se suelta lo reservado, o vuelve el stock si ya se había servido. |

Esos estados se ajustan en el fichero de integraciones sin tocar código. Si tu
tienda envía en cuanto entra el pago, sin pasar por `completed`, pon
`processing` en `WOOCOMMERCE_ESTADOS_SERVIDO`.

**Por qué reservar y no vender directamente.** Entre que alguien paga en la web
y que sale el paquete pasan horas o días. Durante ese hueco la mercancía sigue
en el almacén, pero ya no es vendible: sin la reserva, el mismo último paquete
se puede vender por la web el viernes y en un mercado el sábado, y uno de los
dos clientes se queda sin café.

Cada paso lleva su propio identificador derivado del pedido, así que repetir un
aviso no repite el paso. El evento se indexa por pedido **y estado**: indexarlo
solo por pedido haría que el aviso de «enviado» se descartara como repetido del
de «pagado», y el stock nunca llegaría a descontarse.

### Publicar el stock en la tienda

Cada quince minutos se publica lo **disponible** —existencias menos lo ya
comprometido por otros pedidos— en la ubicación dedicada a la web, menos el
colchón configurado. Sin esto, la web seguiría vendiendo el café que se vendió
el sábado en un mercado.

Solo se envían las referencias cuyo número ha cambiado. No es por rendimiento,
sino para no llenar el registro de cambios de la tienda con ruido que oculte
los cambios de verdad.

Tener una ubicación `ONLINE` separada del almacén es lo que permite decidir
cuánto se expone a la web sin arriesgar lo que va cargado en la furgoneta.

### Lo que este conector NO hace

- **No trae clientes ni direcciones de envío.** Los pedidos se asocian sin
  cliente; para preparar el envío se mira en WooCommerce.
- **No emite documentos fiscales.** WooCommerce ya lo hace con su Verifactu;
  la app guarda el número de pedido como referencia.
- **No gestiona reembolsos parciales línea a línea.** Un pedido reembolsado
  devuelve todo. Un reembolso parcial hay que ajustarlo a mano.

---

## Hostelería · pedidos por enlace

**No necesita ninguna clave.** Ni token de Meta, ni aprobación, ni coste por
conversación.

### Por qué un formulario y no la Cloud API de WhatsApp

Se plantearon las dos. Gana el formulario por tres razones, y la tercera es la
que decide:

1. No hay coste por conversación ni aprobación de Meta que esperar.
2. El cliente no instala nada: abre un enlace y pide.
3. **No hay que interpretar lenguaje natural**, que es justo donde se
   equivocaría. «Ponme 3 de la mezcla» no dice el formato. «Lo de siempre» no
   dice nada. Un desplegable no tiene ese problema, y un pedido mal entendido
   cuesta un viaje en furgoneta.

La Cloud API compensaría a partir de varios cientos de pedidos al mes. Por
debajo de eso es matar moscas a cañonazos.

### Cómo se pone en marcha

1. La ficha del cliente tiene que ser de tipo **Hostelería** y con su
   descuento habitual puesto.
2. **Ajustes → Enlaces de hostelería → Generar enlace**.
3. **Mandar por WhatsApp**: abre la conversación con el mensaje ya escrito.
   El cliente guarda el enlace y pide cuando quiera.

### Qué pasa cuando piden

El pedido entra con el stock **reservado**, igual que uno de la web: apartado
pero sin salir del libro. Aparece en la pantalla **Pedidos**, y al marcarlo
como servido es cuando se descuenta.

Si piden más de lo que hay, el pedido entra igual y se abre una incidencia.
Es lo correcto: el café se tuesta al pedido, y negarse solo perdería el
encargo. El formulario marca esos artículos como «se tuesta al pedido», sin
impedir pedirlos.

### Sobre la seguridad del enlace

**El enlace es la credencial.** Quien lo tenga puede pedir en nombre de ese
cliente. Por eso:

- Son 32 caracteres al azar: no se adivinan probando.
- Se revocan **de uno en uno**, sin afectar a los demás clientes, y el viejo
  deja de funcionar al momento.
- Un enlace revocado y uno inventado dan **la misma respuesta**, para no
  decirle a nadie cuál de las dos cosas es.
- **El precio lo pone el servidor**, nunca el formulario. Si alguien manipula
  lo que se envía, se ignora.
- Hay un tope de pedidos por hora y enlace. No es tanto contra un ataque como
  contra el doble clic y el «no sé si se ha enviado» que lo manda tres veces.

Lo que un enlace filtrado permitiría es encargar café a nombre de ese cliente,
que se detecta al preparar el pedido. No da acceso a ningún dato del negocio:
el formulario solo devuelve el catálogo con el precio de ese cliente.

### Lo que esto NO hace

- **No cobra.** El pedido se factura como siempre, fuera de la app.
- **No confirma la entrega.** El cliente ve «te avisamos», y el aviso se manda
  a mano por WhatsApp.
- **No guarda un historial para el cliente.** No hay cuenta ni contraseña: es
  deliberado, porque mantener contraseñas de veinte bares es peor que no
  tenerlas.

---

## Conciliación

**Ajustes → Conciliación** reúne todo lo que el sistema no ha sabido resolver
solo: artículos sin emparejar, ventas por encima del stock, eventos que
agotaron sus reintentos y descuadres entre la proyección de saldos y el libro.

Si está vacía, todo va solo. Es la contrapartida de no descartar nada en
silencio: los problemas aparecen aquí el mismo día, en vez de manifestarse tres
semanas después como un inventario que no cuadra.
