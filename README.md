# Gestión de tueste, stock y pedidos

Maestro único de inventario y pedidos multicanal para un tostador de café de
especialidad: importación de verde → tueste → empaquetado → cuatro canales de
venta.

> **Estado: fase 1 terminada.** El núcleo de inventario está operativo y
> verificado. La interfaz de almacén (escáner, etiquetas, cola offline) es la
> fase 2; los conectores de canal, de la 3 en adelante.

## La idea

El stock **no se guarda: se deriva**. Hay un libro de movimientos que solo
admite inserciones, y las existencias son su suma. Cuando algo no cuadra se
puede ver exactamente qué pasó, cuándo y quién lo hizo.

Lee [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) para el diseño completo y
[`docs/adr/0001-decisiones.md`](docs/adr/0001-decisiones.md) para por qué es
así y no de otra manera.

## Puesta en marcha

```bash
npm install
cp .env.example .env.local     # y rellenarlo
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

## Despliegue en Vercel

1. Importar el repositorio. El framework se detecta solo.
2. Configurar las variables de [`.env.example`](.env.example) en
   *Settings → Environment Variables*.
3. `SUPABASE_SERVICE_ROLE_KEY` y `SUPABASE_JWT_SECRET` **nunca** con el
   prefijo `NEXT_PUBLIC_`: se saltan RLS y firman sesiones.

## Estructura

```
supabase/migrations/   esquema, funciones de dominio y políticas RLS
supabase/tests/        criterios de aceptación, ejecutables
src/lib/               capa tipada sobre las funciones de dominio
src/app/api/           rutas de servidor (único camino a los datos)
docs/                  arquitectura y decisiones
```

## Primer acceso

La semilla crea un administrador con **PIN 1234**. Cambiarlo antes de usar la
app con datos reales.
