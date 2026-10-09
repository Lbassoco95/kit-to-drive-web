# Supabase / Base de datos

## Aviso importante sobre migraciones

Este proyecto **no usa `supabase db push`**. El historial de cambios de base de
datos se ha mantenido aplicando scripts idempotentes directamente en el SQL
editor de Supabase; no existe una tabla de migraciones reproducible por el CLI.

Los archivos bajo `supabase/migrations/` son la **línea base documental** del
esquema real, no migraciones ejecutables en secuencia. Si necesitas reproducir
el esquema en otro proyecto, copia el contenido del script al SQL editor y
ejecútalo de arriba a abajo revisando que no falle por objetos previos.

### El riesgo de este modelo, y cómo se revisa

El SQL editor manda el archivo completo en **una sola transacción**. Si algo
revienta en la línea 400, no queda ni la línea 1: es todo o nada. Y como no hay
tabla de migraciones, un script que no se corrió —o que se corrió y se
revirtió— **no deja rastro**: el repo lo tiene, la app se compila igual, y el
hueco sale semanas después como `column ... does not exist` en una pantalla
cualquiera. Ya pasó dos veces (ver «Qué se perdió y por qué» más abajo).

Por eso, antes de dar por buena una base:

```
supabase/diagnostico_esquema.sql
```

Se pega completo en el SQL editor, es de **sólo lectura**, y por cada script
dice `APLICADO`, `PARCIAL`, `FALTA` o `SUPERADO` buscando los objetos que ese
script debería haber dejado. Es la única forma que hay hoy de saber qué corrió
de verdad. Córrelo después de aplicar cualquier script y cuando una pantalla
empiece a comportarse como si le faltaran datos.

Ahí están registrados **todos** los archivos de `supabase/migrations/`, no una
selección: un script sin registrar es un hueco que el diagnóstico no puede ver,
y así estuvo `20260827000001` mientras Clientes salía vacía. La prueba
`src/test/inventario-migraciones.test.ts` falla si la carpeta y el diagnóstico
dejan de cuadrar. El procedimiento completo —qué correr, en qué orden, y qué
cuidar al escribir código que le pide algo nuevo a la base— está en
[`docs/no-romper-produccion.md`](../docs/no-romper-produccion.md).

En la app, los errores `42703 / 42P01 / 42883` ya no se muestran crudos:
`explicarError()` (en `src/lib/dazon.ts`) los traduce a «falta correr
supabase/migrations/<archivo> en el SQL editor», que es la acción real.

### Qué se perdió y por qué

1. **KIT-4c (`20260823000003_color_efectivo_capacidad.sql`) nunca se aplicó.**
   El script se mergeó al repo en `44814ce`, pero no llegó a correrse en
   producción. Como `inventario_chasis.color_original` es lo primero que crea,
   no quedó nada del módulo: ni la columna, ni `bitacora_color`, ni
   `cambiar_color_chasis`, ni el 4º parámetro `_color` de `configurar_unidad`.
   Se notó en Producción → **Configurar unidad**: el modal pide
   `color_original` en la consulta de chasis y todo el `load()` va en un solo
   `try/catch`, así que un 42703 dejaba la pantalla sin chasis, **sin motores**
   y sin catálogo — parecía pérdida de datos y era una columna que faltaba.
   Los datos nunca se tocaron.

2. **`20260717000004_crm_fixes.sql` no podía aplicarse.** Traía tres
   `ALTER TYPE crm_actividad_tipo ADD VALUE ...` sobre un enum que en esta base
   no existe (`crm_actividades.tipo` es `text` con CHECK). En una transacción
   eso revierte el archivo entero, así que las columnas `limitante_*` y la
   vista `v_reporte_pipeline` tampoco existían. Se sustituyó por la ampliación
   del CHECK, que es lo que de verdad hacía falta.

3. **`20260827000001_folio_interno_clientes_nuevos.sql` tronaba en el renglón
   5.** Hacía `PERFORM setval('clientes_folio_interno_seq', max_seq)`, y
   `max_seq` sale `0` mientras ningún cliente traiga folio `CLI-AAAA-NNN` —
   que es justo el arranque. `setval(seq, 0)` no es válido (la secuencia
   empieza en 1) y, en una transacción, ese error se llevó el archivo entero:
   `clientes.folio_interno` nunca se creó y no quedó rastro. Producción se
   quedó así, y como la pantalla de Clientes pedía esa columna, la lista salía
   vacía: se leyó como «se perdieron los clientes» cuando en realidad estaban
   todos ahí. Ya usa el tercer argumento (`is_called`), que resuelve el
   arranque y la recorrida. Chequeo previo:
   `supabase/revisar_antes_de_20260827000001.sql`.

Para que no se repita, los scripts de la era KIT ahora se pueden volver a pegar
completos sin miedo, y **KIT-4c se revisa a sí mismo**: abre con un preflight
que nombra el archivo que falta si no están los cimientos (y no toca nada), y
cierra con un postflight que tumba la transacción si el módulo quedó a medias.
Un `COMMIT` limpio ahora sí es prueba de que quedó.

Se corrigieron además tres scripts que no se podían volver a correr y que, al
abortar, se llevaban todo su archivo por delante:

- `20260714000001_fix_asignar_chasis_modelo.sql` — `GRANT` sin firma explícita
  («function name is not unique» cuando conviven dos versiones de la función).
- `20260821000001_unidad_chasis_motor.sql` — `ALTER COLUMN ... TYPE uuid` con
  un `~*` que truena en la segunda corrida, cuando la columna ya es `uuid`.
- `20260717000003_clientes_expediente_digital.sql` — faltaban los
  `DROP POLICY IF EXISTS` de dos políticas que el propio archivo vuelve a crear.

### Qué salió del diagnóstico del 2026-08-25

Con KIT-4c ya aplicado, el diagnóstico destapó **seis scripts que nunca
llegaron a producción**. Tres estaban rompiendo cosas en vivo:

| Script | Qué rompía |
|---|---|
| `20260819000010_bitacora_eliminaciones` | Borrar una remisión fallaba y **ni siquiera borraba**: el código inserta en esa tabla y salía «Error al registrar la eliminación». KIT-4d construyó encima un trigger de borrado que apunta a la misma tabla. |
| `20260823000002_capturar_seriales_unidad` | KIT-4b. Producción → Editar llama a esa RPC. Además es la que liga la pieza a la unidad: sin ella un chasis con serial capturado se queda `disponible` y fábrica lo puede volver a configurar en otra unidad — **inventario contado doble**. |
| `20260824000003_usuario_activo_se_aplica` | Sin `usuario_activo()`, dar de baja a alguien no significaba nada en la base: la app lo cortaba del lado del cliente, el RLS lo seguía dejando leer. |
| `20260824000002_comercial_lee_toda_la_bandeja` | Faltaba `comercial lee motocarros`: el equipo veía la remisión pero no sus unidades. |
| `20260717000003_clientes_expediente_digital` | Columnas del expediente (`rfc`, `codigo_postal`, `razon_social`, `email_cobranza`) que la pantalla de Clientes ya captura. |
| `20260819000001_parts_inventory` | `contenedor_partes`. Nadie la escribe: la RPC que lo hacía (`importar_partes_excel`) nunca se aplicó y se borró del repo el 2026-09-08. La tabla sigue en la base, vacía. |

Los seis van juntos en **`supabase/reparar_pendientes.sql`**: se pega completo
en el SQL editor y aplica los seis en el orden correcto, en una sola
transacción. Es idempotente — correrlo de más no hace daño — y cierra
comprobando los seis objetos. Verificado sobre una base que reproduce el estado
exacto de producción, corriéndolo tres veces seguidas.

De paso se volvieron re-ejecutables `20260819000001` y `20260819000010`
(`CREATE TABLE`/`CREATE INDEX` sin `IF NOT EXISTS`, `CREATE POLICY` y
`CREATE TRIGGER` sin `DROP` previo): al abortar por «already exists» se
llevaban su archivo completo por delante.

**Un modelo que no se podía vender:** el diagnóstico de colores sacó a
`DZ-K1 / NARANJA`, un código de fábrica crudo sin fila en `modelos_producto`.
Remisiones tenía la lista de modelos escrita a mano (`["200cc 2026",
"300cc 2026"]`), así que esa unidad existía en inventario y era invisible para
ventas. Ahora el selector lee `modelos_producto` como el resto del sistema, y
un modelo sin nombre comercial entra con su código de fábrica en vez de
perderse. Si la consulta falla, se cae a la lista vieja para no dejar el
selector vacío.

### La escalera de Comercial estaba invertida

Al revisar las políticas de `remisiones` después de la reparación salió que
**mientras más alto el nivel en Comercial, menos se podía hacer.** Medido con
RLS real sobre producción reproducida:

| operación | com/operador | com/supervisor | com/admin | dirección |
|---|---|---|---|---|
| crear remisión | SÍ | **no** | **no** | SÍ |
| agregar renglón a la remisión | SÍ | **no** | **no** | SÍ |
| crear oportunidad / actividad / ruta | SÍ | SÍ | **no** | SÍ |
| comentar una unidad | SÍ | **no** | **no** | SÍ |

La causa: cuando se migró a ÁREA × NIVEL (`20260823000005`) el rol legado pasó a
**derivarse** — un supervisor de Comercial es `coordinador_ventas` y un
administrador `director_ventas` — pero estas políticas de **escritura** se
quedaron escritas contra los roles viejos (`ventas`, `coordinador`, `admin`),
que ya no incluyen a esos dos. La lectura sí se migró (`20260824000001/2`), y el
UPDATE de remisiones también (`comercial supervisa remisiones`); el INSERT
nunca.

`20260825000001_comercial_escalera_de_permisos.sql` lo endereza con la regla del
modelo: **cada nivel puede al menos lo que puede el de abajo.** Operador, lo
suyo; supervisor y administrador, todo lo de su área; Dirección, todo. No se
ensancha nada más — se comprobó que fábrica y almacén siguen sin poder crear
remisiones ni registros de CRM, y quien está dado de baja sigue fuera porque
`usuario_activo` vive dentro de `es_area` y `supervisa_area`.

**Pendiente conocido:** los scripts legados de finanzas y CRM
(`20260713000001`, `20260714000002`) agregan un valor a `app_role` y lo usan en
el mismo archivo. Postgres no permite usar un valor de enum recién agregado
dentro de la misma transacción, así que si algún día se reconstruye la base
desde cero hay que correr esos `ALTER TYPE` aparte, en una primera pasada. En
producción ya están aplicados y no estorban.

## Proyecto correcto

Producción: `dmhzhyeivvuliumcgsmm`.

El archivo `.env` ya no se versiona. Para trabajar localmente:

1. Copia `.env.example` a `.env`.
2. Pide a Polo los valores reales del proyecto y colócalos en tu `.env` local.
3. Nunca commitees URLs ni llaves de Supabase.

## Scripts

- `supabase/migrations/20260821000001_unidad_chasis_motor.sql` — KIT-1:
  esquema, contadores, funciones de importación y pareo 1:1 de chasis + motor.
  El pareo automático (`parear_unidades_contenedor`) quedó sin usarse desde
  KIT-3: la importación deja chasis y motores como piezas sueltas, y la
  unidad se configura a mano (ver siguiente script).
- `supabase/migrations/20260822000001_configuracion_manual_unidades.sql` —
  KIT-3: catálogo `modelos_producto` (línea motocarro/mototaxi/otro y
  `nombre_comercial`: código de fábrica DZ200Q1/DZ300Q7 vs. lo que pide
  ventas, "200cc 2026"/"300cc 2026"), normalización de datos ya cargados
  (colores en inglés, seriales de motor con espacios) y de la propia
  importación (`importar_vins_inventario` / `importar_motores_inventario`
  ahora sanean el serial con la misma regla que la captura manual),
  `configurar_unidad` / `desconfigurar_unidad` (chasis + motor a mano, por
  fábrica), `cambiar_orden_armado` con bitácora (`bitacora_orden_armado`)
  y `asignar_chasis_remision` corregida para cruzar por nombre comercial +
  color en vez de código de fábrica.
- `supabase/migrations/20260823000001_incidencias_chasis_colores_cierre.sql` —
  KIT-4, tres cosas que no cerraban el ciclo:
  1. **Colores registrados, no contados.** `inventario_colores` dejó de ser un
     contador que se incrementaba en la importación y se decrementaba a mano:
     ahora se recalcula de los datos reales (`recalcular_inventario_colores()`,
     disparada por triggers en `inventario_chasis` y `motocarros`) y lleva
     columnas nuevas (piezas detenidas, unidades configuradas / libres /
     comprometidas / entregadas). `incrementar_inventario_color` y
     `decrementar_inventario_color` quedan como envoltura del recálculo.
     La vista `v_stock_modelo_color` da la foto por **nombre comercial +
     color**: piezas disponibles, unidades libres (con serial), detenidas,
     comprometidas, demanda pendiente de remisiones NUEVA/PARCIAL y holgura.
  2. **El proceso no cierra sin serial.** El trigger
     `exigir_serial_para_cerrar` en `motocarros` impide pasar a ARMADO/LISTO,
     marcar ENTREGADA o asignar a una remisión sin NS chasis **y** NS motor.
     Se valida en la transición, así que las unidades legadas que ya están
     ARMADO sin serial siguen editables para poder capturárselo.
     `asignar_remision_items(_remision_id)` reemplaza el criterio viejo de
     asignación: cruza **línea por línea de `remision_items`** (modelo
     comercial + color), exige serial, salta chasis detenidos y devuelve el
     detalle del faltante. `reintentar_asignar_remision` y
     `asignar_chasis_remision` delegan / aplican los mismos filtros, y el
     trigger de alta de remisión ya no amarra unidades a ciegas cuando la
     remisión todavía no tiene modelo/color.
  3. **Incidencias de chasis.** `incidencias_chasis` +
     `incidencias_chasis_eventos` con folio `INC-####`: se levanta el reporte
     (`reportar_incidencia_chasis`), el chasis **no** se deshabilita salvo que
     se pida retenerlo, pasa a revisión (`revisar_incidencia_chasis`) y se
     cierra (`resolver_incidencia_chasis`) como *adaptación* (vuelve a servir,
     con el registro pegado a la pieza y a la unidad), *garantía* (identificado
     y fuera del disponible, con folio) o *no útil* (deja de contar, **nunca se
     elimina**). `reabrir_incidencia_chasis` permite que un chasis no útil al
     que después le dan garantía —o que sí se pudo adaptar— vuelva a revisión
     sin perder su historia.
- `supabase/migrations/20260823000002_capturar_seriales_unidad.sql` — KIT-4b:
  `capturar_seriales_unidad()`. KIT-4 exige los dos seriales para cerrar el
  proceso, pero la captura manual escribía nada más en `motocarros`: si el
  serial teclado SÍ estaba en el embarque, la pieza se quedaba en `disponible` y
  fábrica podía volver a configurarla en otra unidad (inventario contado doble).
  Ahora la captura liga la pieza, libera la anterior si se corrigió un serial
  mal capturado, respeta el estatus de una pieza en garantía (no la "lava" a
  `configurado`) y recalcula colores. Producción → Editar ya usa esta RPC.

- `supabase/migrations/20260823000003_color_efectivo_capacidad.sql` — KIT-4c:
  el color se puede cambiar en fábrica, pero no se puede inventar.
  · `inventario_chasis.color_original` guarda lo que declaró el VIN (un trigger
    lo llena en cada importación) y `color` es el color efectivo con el que se
    arma.
  · La **capacidad** de un color son los juegos de piezas que llegaron:
    se deriva del VIN + `inventario_colores.piezas_extra` (ajuste manual con
    bitácora), así que una importación futura la sube sola.
  · `cambiar_color_chasis()` usa un juego libre; `intercambiar_color_chasis()`
    permuta el color de dos chasis del mismo modelo (neutro en capacidad — es
    la operación de piso cuando todos los colores están a tope);
    `ajustar_capacidad_color()` registra juegos que llegaron fuera del VIN.
    Ninguna deja cambiar el color de una unidad ya remisionada o entregada: ahí
    el color es parte del pedido.
  · `configurar_unidad()` recibe un 4º parámetro opcional `_color` para armar en
    otro color en ese momento (valida la capacidad igual).
  · Red de seguridad: el trigger `trg_verificar_capacidad_color` tumba cualquier
    movimiento —incluido un UPDATE directo por RLS— que deje un color con más
    chasis que juegos.
  · `v_stock_modelo_color` agrega `capacidad_color`, `juegos_usados`,
    `capacidad_libre` y `piezas_recoloreadas`.
  · **BLOQUE 0 (preflight)** revisa los cimientos (KIT-3, KIT-4,
    `remision_items.tipo_servicio`, el UNIQUE de `inventario_colores`) y, si
    falta alguno, aborta diciendo qué archivo correr antes — sin tocar nada.
    **BLOQUE 11 (postflight)** verifica los 13 objetos del módulo y revierte si
    quedó incompleto. Correrlo de nuevo es inocuo: es idempotente y respeta los
    colores ya cambiados y las piezas extra registradas.
- `supabase/migrations/20260823000004_finanzas_ingresos_egresos.sql` — KIT-4d:
  Control Financiero deja de ser una lista de gastos y pasa a ser un libro
  mayor de caja. `pagos` queda **obsoleta** (se conserva de respaldo, con
  `migrado_a_movimiento` apuntando al registro nuevo).
  · `movimientos_financieros` lleva ingresos y egresos en la misma línea de
    tiempo: folio `ING-######` / `EGR-######`, estatus
    (BORRADOR → PENDIENTE → CONFIRMADO / CANCELADO — solo lo CONFIRMADO afecta
    saldo) y `monto_mxn` como columna generada para poder sumar monedas.
  · **La contraparte se amarra al catálogo**, no es texto libre:
    `contraparte_tipo` + el FK que corresponda (`cliente_id`, `proveedor_id`,
    `empleado_id`) o «OTRO» con el nombre a mano. El CHECK `chk_contraparte`
    impide declarar un tipo y apuntar al catálogo equivocado.
  · **Quién pagó ≠ quién trajo el dinero.** `via` distingue DIRECTO (el cliente
    vino a caja / le pagamos al proveedor) de INTERMEDIARIO (alguien trajo el
    efectivo o alguien lo llevó a pagar), con `intermediario_id` /
    `intermediario_nombre` y `recibido_por`.
  · **Comprobación de efectivo.** `marcar_comprobacion_movimiento` enciende
    `requiere_comprobacion` cuando es EGRESO + EFECTIVO + INTERMEDIARIO: el
    movimiento queda abierto hasta que hay `monto_comprobado` y
    `monto_devuelto`. Es la cuenta que se le lleva a quien se le dio el
    efectivo para que fuera a pagar.
  · `proveedores` (RFC, banco, CLABE, días de crédito) y
    `cuentas_financieras` + `v_saldos_cuentas` (saldo real por caja y banco).
    `validar_moneda_cuenta` impide meter un movimiento en dólares a una caja
    en pesos, que si no el saldo mezcla monedas.
  · `movimiento_adjuntos`: expediente de N documentos por movimiento
    clasificados por tipo (factura, recibo, comprobante, vale de efectivo,
    foto del efectivo…) en el bucket privado `finanzas-docs`. Un trigger
    mantiene `tiene_factura` al día. Las sentencias de `storage` van aisladas
    en bloques `DO` que atrapan `insufficient_privilege`: el SQL editor manda
    todo en una transacción, y sin aislarlas un error de permisos sobre
    `storage.objects` revertía el módulo completo.
  · `movimiento_bitacora`: trigger que registra alta, edición, confirmación,
    cancelación y comprobación. Los borrados van a `bitacora_eliminaciones`.
  · RLS con **separación de funciones**: `finanzas` captura y edita lo suyo
    mientras esté PENDIENTE, pero **no** puede confirmar ni cancelar; eso es de
    `admin_financiero`. Las vistas llevan `security_invoker = true` para que
    respeten el RLS de las tablas base en lugar de saltárselo.
  · Los folios usan secuencia, así que **pueden tener huecos** si un insert se
    rechaza. Es a propósito: un contador sin huecos obliga a serializar la
    captura.
- `supabase/migrations/20260824000001_remisiones_visibles_equipo_comercial.sql` —
  **Bandeja de remisiones compartida para el equipo comercial.** Antes el rol
  `ventas` sólo podía leer las remisiones con `vendedor_id = auth.uid()`: un
  vendedor recién dado de alta abría Remisiones y veía la bandeja vacía, y dos
  vendedores nunca veían la misma información.
  · `leer remisiones por rol` y `leer motocarros por rol` ahora incluyen
    `has_role(auth.uid(),'ventas')`, igual que admin / coordinador / fábrica /
    logística / finanzas. Se conserva el `OR vendedor_id = auth.uid()` para
    cualquier usuario sin rol operativo.
  · **La escritura no cambia**: `crear remisiones` y `actualizar remisiones`
    siguen exigiendo `vendedor_id = auth.uid()` para `ventas`, así que cada
    vendedor sólo captura, edita, cancela y sube comprobantes de lo suyo. La
    lectura es compartida; la responsabilidad sigue siendo individual.
  · `remision_items_select` se re-crea (`USING (true)`, sólo `authenticated`)
    por idempotencia, en caso de que se hubiera endurecido a mano.
  · En la app, `src/pages/Remisiones.tsx` muestra la bandeja completa con un
    selector **Todo el equipo / Solo las mías** y marca con la etiqueta «Tuya»
    las remisiones del usuario en sesión.

- `supabase/migrations/20260823000005_usuarios_niveles_areas.sql` —
  **Modelo de usuarios: ÁREA × NIVEL.** Columnas `user_roles.area` y
  `user_roles.nivel`, sus enums (`user_area`, `user_nivel`), los helpers de RLS
  (`es_area`, `nivel_al_menos`, `es_admin_area`, `es_admin_global`,
  `supervisa_area`) y políticas por área. La columna histórica
  `user_roles.role` se conserva y se **deriva por trigger** de (área, nivel),
  para que el RLS y los scripts de carga anteriores sigan funcionando.
  El detalle del modelo está en `docs/usuarios-y-permisos.md`.
  · **Ojo con el historial:** este script se aplicó a la base de producción
    pero su rama (`claude/user-types-permissions-zg25y5`) nunca se mergeó, así
    que durante semanas la base corrió el modelo nuevo mientras `main` seguía
    con el enum plano `app_role` — de ahí que la pantalla de Usuarios siguiera
    ofreciendo la lista vieja de roles. Se renumeró de `20260823000001` a
    `20260823000005` porque colisionaba con
    `20260823000001_incidencias_chasis_colores_cierre.sql`.
- `supabase/migrations/20260824000002_comercial_lee_toda_la_bandeja.sql` —
  **Leer es del área; escribir es del nivel.** El script anterior dejó
  `comercial lee remisiones` amarrada a `supervisa_area('comercial')`, o sea
  supervisor para arriba, con lo que un **operador** volvía a ver sólo lo suyo
  — el mismo problema que `20260824000001` había resuelto para el rol `ventas`.
  · `comercial lee remisiones` pasa a `es_area(...,'comercial')`: cualquier
    nivel del área lee la bandeja completa, más Dirección y Administración.
  · Se agrega `comercial lee motocarros`. Este hueco no era sólo del operador:
    como el rol legacy se deriva de (área, nivel), un supervisor de Comercial
    queda con `coordinador_ventas` y un administrador con `director_ventas`, y
    ninguno aparece en `leer motocarros por rol`; `direccion lee motocarros`
    sólo cubre Dirección y Administración. Veían la remisión pero no sus
    unidades.
  · No se toca ninguna política de escritura: el operador edita lo suyo, el
    supervisor lo de su área, el administrador borra.

- `supabase/migrations/20260824000003_usuario_activo_se_aplica.sql` —
  **`profiles.activo` deja de ser decorativo.** Hasta aquí, desactivar a alguien
  desde Sistema → Usuarios sólo lo pintaba en gris en esa lista: no se validaba
  en el login, ni en `ProtectedRoute`, ni en ninguna política. Un usuario
  «inactivo» entraba y leía igual.
  · En vez de tocar cada política, se corta en el punto de paso: todas pasan por
    `has_role`, `es_area`, `nivel_al_menos`, `es_admin_area`, `es_admin_global`
    y `supervisa_area`. Los seis ahora exigen `usuario_activo(uid)`, así que la
    baja aplica en todo el sistema sin reescribir una sola política.
  · `usuario_activo` es deliberadamente conservador: bloquea **sólo** a quien
    está marcado explícitamente como inactivo. Un `profiles` inexistente o un
    `activo` nulo cuentan como activo — un hueco de datos no debe convertirse
    en alguien que no puede trabajar.
  · Las políticas que caían a `vendedor_id = auth.uid()` (leer y actualizar
    remisiones, leer motocarros) llevan el chequeo aparte: sin eso, un vendedor
    dado de baja seguía leyendo y editando lo suyo.
  · En la app, `ProtectedRoute` muestra una pantalla que explica el motivo
    —cuenta desactivada, o sin área y tipo asignados— en vez de dejar a la
    persona en un tablero vacío que parece descompuesto.
  · Para dar de baja las cuentas de demostración hay un script aparte en la raíz
    del repo: `desactivar_usuarios_demo.sql`. **No filtres por `@dazon.demo`**:
    las cuentas reales del equipo usan ese mismo dominio.

## Cómo se propaga un cambio de permisos

Los dos lados no se comportan igual, y conviene tenerlo claro antes de tocar
roles o políticas:

- **La base es inmediata.** El rol no viaja en el JWT: `has_role()` consulta
  `user_roles` en cada query. Un cambio de política o de rol aplica en la
  siguiente petición, sin cerrar sesión ni recargar.
- **La app revisa sola.** `AuthContext` vuelve a leer el área y el nivel al
  recuperar el foco de la pestaña, al volver a ella y cada dos minutos mientras
  está visible. Si detecta un cambio actualiza el menú y avisa con un toast
  («Tus permisos cambiaron»). Antes se leía una sola vez por sesión y había que
  pedirle a la persona que recargara a mano.
- Un error de red en esa revisión **no** borra el rol vigente: se conserva y se
  reintenta en el siguiente ciclo, para no degradar permisos por un tropiezo
  de conexión.

## Verificación manual recomendada

Después de aplicar KIT-1 o importar datos:

```sql
SELECT count(*) FROM inventario_chasis;
SELECT count(*) FROM inventario_motor;
SELECT count(*) FROM motocarros;
SELECT id, folio_contenedor, total_chasis, total_motores, total_unidades, estatus_carga
  FROM contenedores ORDER BY fecha_arribo DESC;
```

Después de aplicar KIT-3:

```sql
SELECT modelo, linea, nombre_comercial FROM modelos_producto ORDER BY linea, modelo;
SELECT DISTINCT color FROM inventario_chasis;             -- no debe quedar WHITE/BLUE/ORANGE
SELECT DISTINCT color FROM inventario_colores;
SELECT count(*) FROM inventario_motor
  WHERE numero_motor <> regexp_replace(upper(numero_motor),'[^A-Z0-9-]','','g');  -- debe ser 0
SELECT count(*) FROM inventario_chasis WHERE motocarro_id IS NULL;   -- "por configurar"
SELECT count(*) FROM motocarros m JOIN modelos_producto mp
  ON mp.modelo = m.modelo AND mp.linea = 'motocarro';                -- "programadas"

-- Cruce por nombre comercial: una unidad DZ300Q7 BLANCO debe salir aquí para
-- una remisión que pida "300cc 2026" BLANCO.
SELECT m.id, m.modelo, mp.nombre_comercial, m.color
  FROM motocarros m LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
 WHERE m.remision_id IS NULL AND upper(coalesce(mp.nombre_comercial, m.modelo)) = '300CC 2026' AND m.color = 'BLANCO';
```

Después de aplicar KIT-4:

```sql
-- 1. Colores: el conteo tiene que cuadrar con los datos reales.
SELECT public.recalcular_inventario_colores();
SELECT modelo, color, cantidad_disponible, piezas_en_revision, piezas_garantia,
       piezas_no_util, unidades_configuradas, unidades_libres, unidades_comprometidas
  FROM inventario_colores ORDER BY modelo, color;

-- Debe dar 0 filas: el disponible por color siempre es el conteo de chasis sanos.
SELECT ic.modelo, ic.color, ic.cantidad_disponible, c.reales
  FROM inventario_colores ic
  JOIN (SELECT modelo, upper(color) AS color, count(*) AS reales
          FROM inventario_chasis
         WHERE motocarro_id IS NULL AND estatus = 'disponible'
         GROUP BY 1,2) c ON c.modelo = ic.modelo AND c.color = ic.color
 WHERE ic.cantidad_disponible <> c.reales;

-- 2. La foto por color que ve dirección (disponible vs. comprometido vs. demanda).
SELECT * FROM v_stock_modelo_color ORDER BY modelo_comercial, color;

-- 3. Cierre de proceso: no debe existir una unidad cerrada sin los dos seriales.
SELECT orden_armado, estatus_armado, estatus_entrega, ns_chasis, ns_motor
  FROM motocarros
 WHERE (estatus_armado IN ('ARMADO','LISTO') OR estatus_entrega = 'ENTREGADA'
        OR remision_id IS NOT NULL)
   AND (ns_chasis IS NULL OR ns_motor IS NULL);
-- (Las filas que salgan aquí son de antes de KIT-4: el trigger sólo valida
--  la transición. Captúrales el serial desde Producción → Editar.)

-- 4. Incidencias abiertas y chasis detenidos.
SELECT folio, ns_chasis, parte_afectada, estatus, retiene_chasis, folio_garantia
  FROM incidencias_chasis ORDER BY reportado_at DESC;
SELECT estatus, count(*) FROM inventario_chasis GROUP BY estatus ORDER BY 1;
```

Después de aplicar KIT-4b y KIT-4c:

```sql
-- 1. Capacidad de color: cuántos juegos llegaron, cuántos se usan, cuántos quedan.
SELECT modelo, color, piezas_recibidas AS juegos, piezas_extra AS extra,
       juegos_usados AS usados, piezas_recibidas - juegos_usados AS libres
  FROM inventario_colores ORDER BY modelo, color;

-- 2. Debe dar 0 filas: ningún color puede tener más chasis que juegos.
WITH usados AS (SELECT modelo, upper(color) AS color, count(*) n FROM inventario_chasis GROUP BY 1,2),
     vin    AS (SELECT modelo, upper(COALESCE(color_original,color)) AS color, count(*) n
                  FROM inventario_chasis GROUP BY 1,2)
SELECT u.modelo, u.color, u.n AS usados,
       COALESCE(v.n,0) + COALESCE(ic.piezas_extra,0) AS capacidad
  FROM usados u
  LEFT JOIN vin v ON v.modelo = u.modelo AND v.color = u.color
  LEFT JOIN inventario_colores ic ON ic.modelo = u.modelo AND ic.color = u.color
 WHERE u.n > COALESCE(v.n,0) + COALESCE(ic.piezas_extra,0);

-- 3. Chasis que se armaron en un color distinto al del VIN (con su bitácora).
SELECT numero_chasis, color_original AS vin, color AS efectivo
  FROM inventario_chasis
 WHERE upper(COALESCE(color_original, color)) <> upper(color)
 ORDER BY numero_chasis;

SELECT tipo, ns_chasis, modelo, color_anterior, color_nuevo,
       cantidad_antes, cantidad_nueva, motivo, creado_at
  FROM bitacora_color ORDER BY creado_at DESC;

-- 4. Debe dar 0 filas: ninguna pieza usada por una unidad puede seguir
--    contándose como disponible (lo que arregla KIT-4b).
SELECT ic.numero_chasis, ic.estatus, m.orden_armado
  FROM inventario_chasis ic
  JOIN motocarros m ON m.ns_chasis = ic.numero_chasis
 WHERE ic.motocarro_id IS NULL;

SELECT im.numero_motor, im.estatus, m.orden_armado
  FROM inventario_motor im
  JOIN motocarros m ON m.ns_motor = im.numero_motor
 WHERE im.motocarro_id IS NULL;
```

Después de aplicar KIT-4d (Control Financiero):

```sql
-- 1. Cajas y catálogo sembrados.
SELECT nombre, tipo, moneda, saldo_inicial, saldo_actual
  FROM v_saldos_cuentas ORDER BY orden;
SELECT tipo, count(*) FROM categorias_financieras GROUP BY tipo;   -- 8 ingreso / 10 egreso

-- 2. El bucket del expediente y sus políticas (si dio 0, créalos en Storage
--    → New bucket: «finanzas-docs», privado, 20 MB).
SELECT (SELECT count(*) FROM storage.buckets WHERE id = 'finanzas-docs') AS bucket,
       (SELECT count(*) FROM pg_policies
         WHERE tablename = 'objects' AND policyname LIKE 'finanzas_docs%') AS politicas;

-- 3. Los `pagos` viejos quedaron migrados: no debe haber ninguno sin su
--    movimiento equivalente.
SELECT count(*) FROM pagos WHERE migrado_a_movimiento IS NULL;      -- debe ser 0

-- 4. Efectivo entregado que nadie ha comprobado (la cuenta abierta).
SELECT folio, fecha_movimiento, concepto, contraparte_nombre,
       COALESCE(intermediario_nombre, '(del equipo)') AS se_le_dio_a, monto
  FROM movimientos_financieros
 WHERE requiere_comprobacion AND NOT comprobado AND estatus <> 'CANCELADO'
 ORDER BY fecha_movimiento;

-- 5. Debe dar 0 filas: una comprobación cerrada tiene que cuadrar.
SELECT folio, monto, monto_comprobado, monto_devuelto,
       monto - COALESCE(monto_comprobado,0) - COALESCE(monto_devuelto,0) AS diferencia
  FROM movimientos_financieros
 WHERE comprobado
   AND monto - COALESCE(monto_comprobado,0) - COALESCE(monto_devuelto,0) <> 0;

-- 6. Debe dar 0 filas: ningún movimiento en una cuenta de otra moneda.
SELECT m.folio, m.moneda, c.nombre, c.moneda
  FROM movimientos_financieros m JOIN cuentas_financieras c ON c.id = m.cuenta_id
 WHERE m.moneda <> c.moneda;

-- 7. Estado de cuenta por cliente (lo que nos ha pagado cada uno).
SELECT nombre_comercial, pagos_registrados, total_pagado_mxn, ultimo_pago
  FROM v_estado_cuenta_cliente
 WHERE pagos_registrados > 0 ORDER BY total_pagado_mxn DESC;
```

Después de aplicar `20260824000001_remisiones_visibles_equipo_comercial.sql`
(entrar con un usuario de `ventas`, p. ej. Atenea / Marco / Ana Karen):

```sql
-- 1. Las tres políticas de lectura deben mencionar 'ventas'.
SELECT tablename, policyname, qual LIKE '%ventas%' AS incluye_ventas
  FROM pg_policies
 WHERE schemaname = 'public'
   AND tablename IN ('remisiones','motocarros','remision_items')
   AND cmd = 'SELECT';

-- 2. La escritura NO debe haberse abierto: 'crear remisiones' y
--    'actualizar remisiones' siguen amarradas a vendedor_id = auth.uid().
SELECT policyname, cmd, qual, with_check
  FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'remisiones' AND cmd <> 'SELECT';

-- 3. Cuántas remisiones debería ver el equipo comercial (todas las no
--    canceladas) contra cuántas son de un vendedor en particular.
SELECT count(*) FILTER (WHERE estatus <> 'CANCELADA') AS activas_totales,
       count(*) FILTER (WHERE estatus <> 'CANCELADA'
                          AND vendedor_id = (SELECT id FROM profiles
                                              WHERE nombre_completo ILIKE '%Atenea%')) AS activas_de_atenea
  FROM remisiones;
```

En la app, con sesión de `ventas`: la cabecera debe decir
«N remisiones registradas — todo el equipo · M tuyas», el selector **Ver**
debe alternar entre *Todo el equipo* y *Solo las mías*, y en las remisiones de
otro vendedor **no** deben aparecer los botones de asignar chasis / subir PDF /
proponer fecha / cancelar: la tarjeta queda de sólo lectura (folio, cliente,
avance, chasis y entregas).
