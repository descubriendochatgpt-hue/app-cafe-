# Revisión de seguridad

Revisión de todo el árbol, hecha antes de que el sistema toque datos reales.
El repositorio nació vacío, así que el alcance es el código entero, no un
diff.

Todo lo que se afirma aquí se comprobó **ejecutándolo** contra un PostgreSQL
real, con los roles y las políticas puestos, no leyendo el código.

---

## Resumen

| | Hallazgo | Estado |
|---|---|---|
| **Grave** | PIN de 4 cifras sin freno a la fuerza bruta | Corregido |
| **Media** | El enlace de pedido era legible por cualquier operario | Corregido |
| **Media** | `stock_publicado` sin RLS y sin poder escribirse | Corregido |
| Informativo | Dos avisos en dependencias, no explotables aquí | Documentado |

---

## 1 · Fuerza bruta contra el PIN · GRAVE · corregido

**Qué pasaba.** Un PIN de cuatro cifras son diez mil combinaciones. La
aplicación está en internet, `/api/auth/usuarios` daba la lista de usuarios
**con su perfil** sin necesidad de identificarse, y no había ningún contador
de intentos, bloqueo ni espera. Probar las diez mil era cuestión de minutos, y
la lista decía exactamente a quién atacar para entrar como administrador.

**Por qué no bastaba con alargar el PIN.** Un PIN corto es la decisión
correcta: se teclea con las manos sucias, en un mercado, con prisa. Lo que
faltaba no era un PIN más largo, sino que probar saliera caro.

**Qué se ha hecho.**

- Contador de fallos por usuario, con bloqueo que **se duplica** cada tres
  intentos hasta una hora. A los veinte fallos la espera ya hace inviable
  recorrer el espacio de PIN.
- El bloqueo se comprueba **antes** de mirar el PIN: acertarlo durante el
  bloqueo tampoco abre. Si no fuera así, el atacante seguiría probando y el
  bloqueo no serviría de nada.
- La fila se bloquea con `for update`, para que veinte peticiones simultáneas
  no cuenten como un solo intento. Sin eso, la concurrencia sorteaba el freno.
- La lista pública **ya no dice el rol**. El nombre hace falta para el
  desplegable; saber quién es administrador, no.
- Un administrador puede desbloquear a mano a quien se haya equivocado.

**Un error que apareció al probar la propia corrección.** `return query` no
termina una función de PL/pgSQL: un acceso correcto seguía hasta la rama de
fallo y se contaba como error. Un usuario legítimo se habría ido bloqueando
solo, poco a poco. Lo detectó el test, no la lectura del código.

**Lo que sigue en pie.** La lista de usuarios (solo nombres) sigue siendo
pública, porque el desplegable de acceso la necesita antes de identificarse.
Con el bloqueo puesto no es explotable; si prefieres no publicar ni los
nombres, la alternativa es escribir el usuario a mano.

---

## 2 · El enlace de pedido era legible por cualquier operario · MEDIA · corregido

**Qué pasaba.** `clientes.token_pedido` es la credencial con la que un bar
hace pedidos. La política de lectura de clientes la abría a cualquiera
identificado, incluido un operario. Que la ruta comprobara el perfil de gestor
no basta: **la capa que manda es RLS**, y ahí estaba abierta.

**Qué se ha hecho.** Permiso por columna: `token_pedido` deja de tener lectura
para `authenticated`, y sale solo por `clientes_con_enlace()`, que exige
gestor. El alta y la baja del enlace tampoco se pueden hacer con un `UPDATE`
suelto: van por `generar_enlace_pedido` y `revocar_enlace_pedido`. El operario
sigue viendo a los clientes, que los necesita para trabajar.

---

## 3 · `stock_publicado` sin RLS y sin poder escribirse · MEDIA · corregido

**Qué pasaba.** La tabla se creó después de la migración de permisos, así que
se quedó fuera: era **la única sin RLS** de las veintiuna. Y el conector de
WooCommerce no tenía permiso para escribirla, de modo que la publicación de
stock habría fallado en cada vuelta con un «permission denied».

Es el hallazgo que mejor ilustra por qué conviene revisar: no se manifestaba
como un fallo visible, sino como una tarea que no cuadraba nunca.

**Qué se ha hecho.** RLS activada y forzada, lectura para operario, y
escritura solo por `anotar_stock_publicado()`, como el resto de tablas que
sostienen el inventario.

---

## Lo que se comprobó y estaba bien

- **37 funciones `SECURITY DEFINER`, todas con `search_path` fijado.** Es la
  vía clásica de escalada de privilegios en Postgres, y estaba cerrada.
- **El libro de movimientos es inmutable de verdad.** Ni siquiera un
  superusuario puede hacerle `UPDATE`: lo impide un disparador, no una
  convención.
- **Ni `movimientos`, ni `operaciones`, ni `saldos` admiten escritura
  directa**, para ningún rol. La única vía son las funciones de dominio.
- **El operario no recibe importes.** No es que la interfaz los oculte: la
  consulta devuelve cero filas de `precios` y cero de `pedidos`, y tres por la
  vista sin importes.
- **Sin identificarse no se llega a nada** salvo la lista de acceso y la
  comprobación del PIN.
- **La clave de servicio no se usa en ningún camino de la aplicación.** Los
  conectores actúan con un JWT de perfil SISTEMA, así que pasan por las mismas
  puertas que una persona.
- **Ningún secreto lleva el prefijo `NEXT_PUBLIC_`** ni está en el repositorio.
- **Firmas de webhook** verificadas con HMAC sobre el cuerpo crudo y
  comparación en tiempo constante, en los dos conectores. Un cuerpo manipulado
  después de firmar se rechaza (probado).
- **El formulario público** no acepta el precio que le manden: lo pone el
  servidor (probado con un precio de 0,01 €). Un enlace revocado y uno
  inventado dan la misma respuesta.
- **SQL dinámico** solo en las migraciones, con `format('%I')` y valores de
  una lista fija.
- **Sin `dangerouslySetInnerHTML`, `eval` ni `new Function`.** Sin
  redirecciones con datos del usuario.
- **Cookie de sesión** `httpOnly`, `secure` en producción, `sameSite=lax`.
- **Tareas programadas** protegidas por `CRON_SECRET`, y cerradas si no está
  puesto en producción.

---

## Dependencias

`jspdf` tenía un aviso **crítico** (denegación de servicio). Se ha actualizado
a 4.2.1, que es un salto de versión mayor: se han vuelto a generar las
etiquetas y a mirarlas para confirmar que la salida no cambia. Eso arrastra
también el aviso de `dompurify`.

Quedan dos avisos, ambos en **PostCSS**, que Next incluye:

- Solo se corrigen actualizando a **Next 16**, un salto de versión mayor.
- **No son explotables aquí**: afectan al procesado de CSS en tiempo de
  compilación, sobre CSS que escribimos nosotros. Requieren CSS controlado por
  un atacante, y no hay ninguna vía por la que eso entre.

La recomendación es subir a Next 16 como un cambio aparte y probado, no
metiendo un salto de framework dentro de una revisión de seguridad.

---

## Lo que esta revisión NO cubre

Conviene ser explícito:

- **No se ha probado contra un Supabase real.** Las políticas se verificaron
  en un PostgreSQL con los mismos roles y las mismas migraciones, pero la
  configuración del proyecto en Supabase (quién puede ver qué en el panel,
  copias de seguridad, red) es otra capa.
- **No hay límite de peticiones por IP**, solo por usuario y por enlace, que
  es donde está el daño. Un atacante puede hacer muchas peticiones inútiles.
- **No se ha auditado la cadena de suministro** más allá de `npm audit`.
- **La cabecera de firma de Loyverse no está confirmada** contra su
  documentación: se aceptan las variantes conocidas y se puede fijar a mano.
  Hasta confirmarlo, conviene comprobar que los envíos se aceptan.

---

## Antes de poner datos reales

1. **Cambiar el PIN 1234** del administrador.
2. Dar de alta a cada persona con su propio usuario: los movimientos quedan
   firmados con quien los hizo, y eso solo sirve si no comparten cuenta.
3. Poner `CRON_SECRET`, o las tareas programadas quedarán apagadas.
4. `NEXT_PUBLIC_APP_URL` con el dominio real antes de dar de alta los webhooks.
