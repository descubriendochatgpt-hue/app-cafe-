# Gestión de tueste, stock y pedidos

Maestro único de inventario y pedidos multicanal para un tostador de café de
especialidad: importación de verde → tueste → empaquetado → cuatro canales de
venta.

> **Estado: las cinco fases terminadas.** Núcleo de inventario, aplicación de
> almacén con etiquetas, migración desde las hojas y los cuatro canales:
> Loyverse, WooCommerce, depósito de El Corte Inglés (manual, como se acordó)
> y hostelería por enlace.

## La idea

El stock **no se guarda: se deriva**. Hay un libro de movimientos que solo
admite inserciones, y las existencias son su suma. Cuando algo no cuadra se
puede ver exactamente qué pasó, cuándo y quién lo hizo.

Lee [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) para el diseño completo,
[`docs/adr/0001-decisiones.md`](docs/adr/0001-decisiones.md) para por qué es
así y no de otra manera, [`docs/MIGRACION.md`](docs/MIGRACION.md) para pasar
desde las hojas sin parar la operativa, y
[`docs/CONECTORES.md`](docs/CONECTORES.md) para conectar los canales y
[`docs/REVISION-SEGURIDAD.md`](docs/REVISION-SEGURIDAD.md) para lo que se
revisó antes de poner datos reales.

## Configuración: un único fichero

Todas las claves y webhooks se rellenan en un solo sitio.

```bash
cp integraciones.ejemplo.env .env.local   # y rellenar
```

Ese fichero lleva las instrucciones dentro: dónde se saca cada clave y qué URL
hay que pegar en el panel de Loyverse o de WooCommerce. **No hay que tocar
código para activar un canal**: en cuanto se pegan sus claves, se enciende.

La pantalla `/ajustes/integraciones` dice cuál está lista, cuál falta y ofrece
las URL de webhook listas para copiar.

## Puesta en marcha

```bash
npm install
cp integraciones.ejemplo.env .env.local
npm run dev
```

### Base de datos

Las migraciones de `supabase/migrations/` se aplican en orden y están pensadas
para correr tanto en Supabase como en un Postgres limpio.

```bash
# Postgres local para desarrollo y pruebas
export PGHOST=/tmp PGPORT=5433 PGUSER=postgres PGDATABASE=cafe

npm run db:rebuild    # reconstruye el esquema desde cero
npm run db:test       # suite de criterios de aceptación
```

Con el CLI de Supabase, `supabase db push` aplica las mismas migraciones.

## Verificación

```bash
npm run typecheck     # TypeScript
npm test              # 18 pruebas de la capa de aplicación
npm run db:test       # criterios de aceptación contra Postgres
```

La suite de base de datos comprueba, ejecutándolo de verdad:

| Criterio | Cómo se comprueba |
|---|---|
| Reprocesar un evento no duplica stock | Se reenvía la misma operación, el mismo recibo y el mismo tueste |
| Reprocesar el histórico da el mismo stock | Se reproduce sobre una base vacía y se comparan los saldos uno a uno |
| Dos ventas simultáneas no dan stock negativo | 50 ventas en paralelo del único paquete que queda |
| El depósito cuadra | servido − vendido − devuelto = saldo, con descuadre cero |
| La migración no pierde ni inventa stock | Se importa un export de ejemplo y se compara con la propia hoja |
| El conector no duplica ni pierde ventas | Reenvíos ignorados, reintentos con espera, devolución al lote original |
| Reservar compromete sin descontar | Un pedido web reserva, servir descuenta, cancelar devuelve |
| Un enlace de pedido no se puede usar para otra cosa | Precio del servidor, freno a repetidos, revocación inmediata |
| El PIN aguanta la fuerza bruta | Bloqueo creciente, y durante el bloqueo ni el PIN correcto abre |

## Despliegue en Vercel

1. Importar el repositorio. El framework se detecta solo.
2. Copiar las variables de [`integraciones.ejemplo.env`](integraciones.ejemplo.env)
   en *Settings → Environment Variables*.
   Poner `NEXT_PUBLIC_APP_URL` con el dominio real: es la base con la que se
   construyen las URL de webhook.
3. `SUPABASE_SERVICE_ROLE_KEY` y `SUPABASE_JWT_SECRET` **nunca** con el
   prefijo `NEXT_PUBLIC_`: se saltan RLS y firman sesiones.

## Estructura

```
integraciones.ejemplo.env   el único fichero que hay que rellenar
supabase/migrations/        esquema, funciones de dominio y políticas RLS
supabase/tests/             criterios de aceptación, ejecutables
scripts/importar.mjs        migración desde las hojas (genera SQL revisable)
src/lib/loyverse.ts         conector de TPV: firma, mapeo y proceso de recibos
src/lib/woocommerce.ts      conector web: estados del pedido y stock de vuelta
src/app/pedido/[token]/     formulario público de hostelería (único sin sesión)
src/lib/ean13.ts            codificación EAN-13 (vectorial, verificada)
src/lib/                    capa tipada sobre las funciones de dominio
src/componentes/            escáner, estado compartido, armazón
src/app/(operativa)/        pantallas: escanear, stock, tueste, ajustes
src/app/api/                rutas de servidor (único camino a los datos)
docs/                       arquitectura, decisiones y migración
```

## La aplicación de almacén

Es una PWA: se instala desde el navegador y **funciona sin cobertura**, que es
el caso real de un mercado. Todo lo que se registra va primero al móvil y
después al servidor; el indicador de la cabecera dice cuánto queda por subir.

| Pantalla | Para qué |
|---|---|
| **Escanear** | Consultar, vender, entradas, salidas, traslados e inventario. Se elige el modo una vez y se escanea seguido. |
| **Stock** | Existencias por artículo y ubicación, con avisos de mínimo y de frescura. |
| **Tueste** | Consume verde y produce paquetes, con la merma calculada y avisada si se sale de lo razonable. |
| **Pedidos** | Lo pendiente de salir, de la web y de hostelería. Marcar «Servido» descuenta el stock reservado. |
| **Etiquetas** | PDF con QR de lote para venta propia y con EAN-13 para El Corte Inglés, en rejillas A4 y rollo térmico. |
| **Ajustes** | Estado de la cola, operaciones que necesitan una decisión, e integraciones. |

## Primer acceso

La semilla crea un administrador con **PIN 1234**. Cambiarlo antes de usar la
app con datos reales, y dar de alta a cada persona con su propio usuario: los
movimientos quedan firmados con quien los hizo, y eso solo sirve si no
comparten cuenta.

Tras varios intentos fallidos el acceso se bloquea un rato, y el bloqueo crece
con cada tanda. Un administrador puede desbloquearlo.
