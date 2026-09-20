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

Las ranuras están preparadas en el fichero de integraciones y la pantalla de
estado ya muestra sus URL de webhook, pero **el conector todavía no está
implementado**: es la siguiente fase. Rellenar sus claves hoy no activa nada.

---

## Conciliación

**Ajustes → Conciliación** reúne todo lo que el sistema no ha sabido resolver
solo: artículos sin emparejar, ventas por encima del stock, eventos que
agotaron sus reintentos y descuadres entre la proyección de saldos y el libro.

Si está vacía, todo va solo. Es la contrapartida de no descartar nada en
silencio: los problemas aparecen aquí el mismo día, en vez de manifestarse tres
semanas después como un inventario que no cuadra.
