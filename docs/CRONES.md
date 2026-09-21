# Tareas programadas

Hay cuatro cosas que conviene hacer cada cierto tiempo:

| Ruta | Qué hace | Cada cuánto querría correr |
|---|---|---|
| `/api/cron/loyverse` | Trae los recibos que el webhook no trajo | 5 min |
| `/api/cron/eventos` | Reintenta lo que quedó atascado, con espera creciente | 10 min |
| `/api/cron/woocommerce` | Publica el stock disponible en la tienda | 15 min |
| `/api/cron/avisos` | Manda el correo del día | 1 vez |

Y una quinta, `/api/cron/diario`, que las ejecuta las cuatro en orden.

## Por qué no están las cuatro en `vercel.json`

**El plan gratuito de Vercel permite una sola tarea al día.** Intentar
desplegar con más falla, sin más:

```
Hobby accounts are limited to daily cron jobs.
```

Así que lo que se despliega por defecto es `/api/cron/diario`, una vez al
día. Las otras cuatro rutas siguen existiendo y se pueden llamar a mano.

## Lo que eso cambia, y conviene tener claro

Con una sola pasada diaria, **las tareas programadas dejan de ser el camino
por el que entran las ventas**. Pasan a ser solo la red de seguridad que
recoge lo que se perdió.

El camino son los **webhooks**, que son inmediatos y no cuestan nada. Uno de
los criterios de aceptación era que una venta se vea en el stock en menos de
un minuto sin que nadie toque nada; eso lo cumple el webhook, no el cron.

**Con plan gratuito, los webhooks no son opcionales.** Si no se configuran,
una venta puede tardar hasta un día en verse. Las URL que hay que pegar en
Loyverse y en WooCommerce están en *Ajustes → Integraciones*.

## Si se pasa al plan de pago

Sustituir el bloque `crons` de `vercel.json` por:

```json
"crons": [
  { "path": "/api/cron/loyverse",    "schedule": "*/5 * * * *" },
  { "path": "/api/cron/eventos",     "schedule": "*/10 * * * *" },
  { "path": "/api/cron/woocommerce", "schedule": "*/15 * * * *" },
  { "path": "/api/cron/avisos",      "schedule": "0 5 * * *" }
]
```

`/api/cron/diario` puede quedarse o quitarse; no estorba, y sirve para
forzar una pasada completa a mano.

## El horario va en UTC

`0 5 * * *` son las 5:00 UTC: las **7:00 en España** en horario de verano y
las 6:00 en invierno. Vercel no entiende de husos.

## El secreto

Todas comprueban la cabecera `Authorization: Bearer $CRON_SECRET`. Sin esa
variable puesta, **en producción se rechazan a sí mismas** — es a propósito:
están expuestas en internet como cualquier otra ruta, y sin secreto
cualquiera podría dispararlas y agotar la cuota de la API de Loyverse.

En desarrollo, sin `CRON_SECRET`, pasan sin fricción.

## Forzar una a mano

Desde el ordenador, con el secreto puesto:

```bash
curl -H "Authorization: Bearer $CRON_SECRET" \
     https://tu-dominio.vercel.app/api/cron/diario
```

Y para reenviar el correo de un día concreto:

```bash
curl -H "Authorization: Bearer $CRON_SECRET" \
     "https://tu-dominio.vercel.app/api/cron/avisos?fecha=2026-09-20"
```
