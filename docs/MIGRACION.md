# Migración desde las hojas de cálculo

Sin parar la operativa y sin un fin de semana de corte a ciegas. La idea es
que el sistema nuevo demuestre que cuadra **antes** de que nadie dependa de él.

## Qué se lleva y qué se queda

| | Dónde acaba |
|---|---|
| Cafés, formatos, referencias, precios, clientes | Se copian tal cual |
| Lotes, con su fecha de tueste y su saco de origen | Se conservan: es lo que mantiene la trazabilidad y los avisos de frescura desde el primer día |
| Existencias | Se calculan sumando el libro antiguo y entran como **un apunte de apertura por lote**, fechado y etiquetado |
| Movimientos anteriores al corte | Se quedan en la hoja, que pasa a ser archivo de solo lectura |
| Pedidos y facturas antiguos | Se quedan en la hoja |

**Por qué no se reproduce el histórico completo.** Daría exactamente el mismo
número con mucho más riesgo: cada apunte antiguo es una oportunidad de que
algo no case. Un apunte de apertura por lote llega al mismo sitio, se lee de
un vistazo y deja el detalle donde ya estaba. Si algún día hace falta el
histórico fino, la hoja sigue ahí.

**Facturas.** No se importan a propósito. La app no emite documentos fiscales
y arrastrar facturas emitidas por otro sistema solo crearía registros
duplicados ante la AEAT.

## Una sola ubicación, y luego el reparto

El sistema antiguo no tenía ubicaciones: todo era un almacén implícito. La
importación carga en `ALMACEN`, y el reparto real —tienda, furgoneta, web,
depósito— se hace **el día del corte con un recuento por ubicación**, desde
el escáner en modo Inventario.

Repartirlo automáticamente exigiría adivinar dónde está cada paquete. Un
recuento de media hora da la respuesta de verdad.

## Los cinco pasos

### 1 · Exportar

En la hoja, `Archivo → Descargar → CSV` para cada pestaña, conservando el
nombre: `Productos.csv`, `Formatos.csv`, `Referencias.csv`, `CafeVerde.csv`,
`Lotes.csv`, `Movimientos.csv`, `Clientes.csv`. Todos en una carpeta.

### 2 · Generar el SQL y leerlo

```bash
node scripts/importar.mjs --entrada ./export --salida ./importacion.sql
```

No toca la base: escribe un fichero. Léelo, y sobre todo lee los avisos:
señalan EAN mal copiados, lotes sin referencia reconocible y sacos de verde
que no se pueden asociar a ningún café. Un EAN inválido se importa vacío en
lugar de abortar la carga, y queda anotado para reasignarlo.

### 3 · Aplicar

```bash
psql -f importacion.sql
```

Termina ejecutando `app.verificar_saldos()`, que tiene que devolver cero
filas. Se puede aplicar varias veces: los identificadores de operación son
deterministas, así que la base reconoce lo ya contabilizado y no lo duplica.

### 4 · Doble registro

**Aquí está la seguridad de toda la migración.** Durante una o dos semanas se
sigue trabajando en la hoja como siempre, y además en la app. La hoja manda.

Cada día, exportar `Movimientos.csv` otra vez y comparar:

```bash
node scripts/importar.mjs --entrada ./export --comparar > comparacion.sql
psql -f comparacion.sql
```

La consulta enseña, lote a lote, lo que dice la hoja, lo que dice la app y la
diferencia. **Cero filas varios días seguidos es la condición para el corte.**
Cualquier fila es una discrepancia que hay que entender antes de seguir: casi
siempre es una venta registrada en un sitio y no en el otro, y eso es
justamente lo que se quiere descubrir ahora y no después.

### 5 · Corte

Cuando la comparación lleve varios días en cero:

1. Recuento por ubicación con el escáner, para repartir el stock que está
   todo en `ALMACEN`.
2. La hoja pasa a solo lectura. Conservarla: es el archivo del histórico.
3. Dar de alta los usuarios reales y **cambiar el PIN 1234** del
   administrador.
4. Revisar que cada referencia tenga precio y mínimo (`Ajustes`), porque la
   importación trae los que hubiera y algunos estarán a cero.

## Lo que hay que mirar con lupa

- **Formatos molidos.** El sistema antiguo no distinguía grano de molido:
  todo entra como grano. Si vendéis molido como referencia aparte, hay que
  darla de alta y repartir el stock con un recuento.
- **Sacos de café verde.** El saco antiguo no decía de qué café era; se
  deduce del lote tostado que lo consumió. Un saco que nunca se tostó no se
  puede deducir, y el aviso lo dice.
- **Lotes agotados.** No se importan, a propósito: un lote a cero no aporta
  nada al inventario y ensucia las pantallas. Su historia sigue en la hoja.

## Verificación

El proceso completo está cubierto por un test que se ejecuta con el resto:

```bash
npm run db:test
```

Importa el export de ejemplo de `scripts/ejemplo-export/`, compara con la
hoja y comprueba que reimportar no duplica nada.
