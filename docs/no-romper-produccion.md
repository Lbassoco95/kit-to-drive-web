# Cambiar algo sin romper lo que ya funcionaba

Este proyecto tiene una particularidad que explica casi todos los incidentes de
producción: **no hay tabla de migraciones**. Los scripts de
`supabase/migrations/` se pegan a mano en el SQL editor de Supabase. Nadie
registra cuáles corrieron.

Eso significa que **el código y la base van por caminos distintos**. Vercel
despliega el código en cuanto se hace merge; la base sólo cambia cuando alguien
abre el SQL editor y pega un archivo. Entre esos dos momentos hay una ventana en
la que el sistema pide a la base cosas que no existen.

Y cuando eso pasa, casi nunca se ve como un error: se ve como si se hubiera
perdido la información.

## Los tres incidentes de Clientes, para no repetirlos

**«Los clientes no se están viendo».** La pantalla pedía
`clientes.folio_interno` en una base donde el script `20260827000001` no se
había corrido. Postgres contestaba `42703 column ... does not exist`, la
pantalla tiraba el `error` a la basura y pintaba «Sin resultados» — lo mismo que
se ve cuando de verdad no hay clientes. Nadie perdió nada: los clientes estaban
ahí, sólo no se podían leer.

Y el script no se había corrido por una razón peor: **tronaba**. En su renglón 5
hacía `setval(seq, 0)`, que no es válido porque la secuencia arranca en 1. En el
SQL editor todo el archivo va en **una** transacción, así que ese error revertía
el script completo — la columna nunca se creaba y no quedaba rastro. Ya está
corregido (usa el tercer argumento `is_called`).

**«El sistema no me deja elegir cliente».** El selector de la remisión llegaba
vacío por `.order("folio_interno, codigo_erp")`. `supabase-js` manda **una**
columna por llamada: eso viaja como `order=folio_interno, codigo_erp.asc`,
PostgREST no puede leer el segundo término y contesta 400. Lo correcto es
encadenar: `.order("a").order("b")`.

**«No aparecen los clientes nuevos».** (2026-09-09) Un cliente recién dado de
alta —N100, NESTOR ALEJANDRO GALLEGOS— existía en la base, se encontraba
filtrando por su código, y no salía en ningún selector. Nada estaba roto:
**PostgREST corta toda respuesta en 1000 filas** (`db-max-rows`, el valor por
omisión de Supabase). `clientes` había llegado a 1784. El catálogo se pedía
ordenado por `folio_interno, codigo_erp`, así que de la J en adelante —784
clientes— nadie existía para la app. En los logs se ve tal cual:

    Content-Range: 0-999/*

Y ahí está lo traicionero: es un **200**, no un error. `data ?? []` recibe mil
renglones y se queda tan contento con media tabla.

El arreglo es `traerTodo()` (`src/lib/paginar.ts`): pide la consulta por tramos
de mil hasta que uno vuelve corto. Dos reglas al usarlo:

- **Ordena por algo único al final** (`.order("id")`). Cada tramo es una
  consulta distinta; si el orden empata, Postgres puede acomodar los empates
  distinto en cada una y un renglón se pierde entre página y página.
- **Si un tramo falla, no entregues lo que ya juntaste.** Media lista se ve
  igual que una lista completa: es el mismo modo de fallar, otra vez.

Para saber qué tablas ya piden paginarse:

```sql
select relname, n_live_tup from pg_stat_user_tables
 where schemaname = 'public' order by n_live_tup desc;
```

Hoy sólo `clientes` pasa de mil. La lista vive en `TABLAS_GRANDES`, dentro de
`src/test/consultas-supabase.test.ts`.

## Antes de tocar la base

1. **Corre el diagnóstico primero.** Pega
   `supabase/diagnostico_esquema.sql` en el SQL editor. Por cada script dice
   `APLICADO`, `FALTA`, `PARCIAL` o `SUPERADO`. Es de solo lectura. Si aparece un
   `FALTA`, eso es el problema — y muy probablemente la explicación de la
   pantalla que se ve vacía.
2. **Si un script en particular no corre, revísalo aparte.** Los archivos
   `supabase/revisar_antes_de_<script>.sql` revisan objeto por objeto, sin
   abortar, y dicen cuál es el que falla en vez de un mensaje que el editor
   puede cortar.
3. **Corre el archivo completo.** Todos los scripts son idempotentes; volver a
   correr uno que ya estaba no rompe nada. Y si revienta a media página, se
   revierte entero: no existe «a medias» que sirva.
4. **Vuelve a correr el diagnóstico.** Si el script quedó, el renglón cambia a
   `APLICADO`.

## Al escribir código que le pide algo nuevo a la base

**El código se despliega antes que la migración.** Aunque se corra el script el
mismo día, hay minutos en que producción tiene el código nuevo y la base vieja —
y si alguien recarga en esos minutos, ve la pantalla rota. Así que:

- **Nunca tires el `error` de Supabase.** `const { data } = await ...` y
  `data ?? []` convierten una falla de la base en una lista vacía, que el usuario
  lee como pérdida de información. Revisa el `error` y muéstralo.
- **Traduce el error a la acción.** `explicarError()` (en `src/lib/dazon.ts`)
  convierte `42703 / 42P01 / 42883` en «falta correr
  supabase/migrations/XXX.sql». Cuando agregues un objeto nuevo, agrégalo
  también a `SCRIPT_DE_OBJETO` — si no, el usuario recibe el error crudo de
  Postgres y nadie sabe qué hacer.
- **Deja respaldo cuando la columna es opcional para trabajar.** El catálogo de
  clientes se lee con `cargarClientes()` (`src/lib/catalogoClientes.ts`):
  intenta con `folio_interno` y, si la base va atrás, vuelve a pedir el
  catálogo de siempre. La pantalla funciona degradada en vez de no funcionar.
  Ojo con la bandera `degradado`: «funcionó degradado» y «no se pudo leer»
  tienen que verse distinto, porque confundirlos es lo que dejó la lista
  vacía en silencio.
- **Distingue «vacío» de «falló».** «Sin resultados» y «no se pudo leer» son
  dos estados distintos y tienen que verse distintos.
- **Una sola forma de leer cada cosa.** Clientes y Remisiones leían el mismo
  catálogo de dos maneras y sólo una tenía respaldo: la que no lo tenía es la que
  se vació. Si dos pantallas piden lo mismo, que compartan la función.
- **Las RPC también.** Un `supabase.rpc(...)` contra una función que no está
  contesta `42883 function ... does not exist`. Pasa el error por
  `explicarError()`, nunca `error.message` pelón: así fue como el botón de
  liberar unidad y la importación de packing list se veían como «no funciona» en
  vez de «falta correr tal script».

## Registra cada script en el diagnóstico

`supabase/diagnostico_esquema.sql` sólo ve los scripts que tiene registrados.
Un archivo sin registrar es un hueco invisible — así estuvo `20260827000001`
mientras Clientes salía vacía.

Al agregar una migración, agrega también uno o más renglones a `esperado` con un
objeto que ese script deje: una tabla, una columna, una función, una política,
un índice, una secuencia, un valor de enum, una restricción, o el default de
una columna. La
cabecera del archivo lista los tipos disponibles y su sintaxis. Si otro script
posterior lo reemplaza por completo, va a `superado` en vez de `esperado`.

Dos detalles que ya dieron falsos avisos:

- **La firma de la función tiene que ser la real.** `crear_motocarro_ya_armado`
  estaba registrada con seis argumentos y tiene cinco: el diagnóstico reportaba
  `FALTA` un script que sí estaba aplicado.
- **No registres un objeto que otro script borra a propósito.**
  `remisiones_tipo_remision_check` la elimina `20260629000005`, así que no sirve
  para reconocer `20260629000004`; ahí se revisa el default de la columna.

La prueba `src/test/inventario-migraciones.test.ts` falla si la carpeta y el
diagnóstico no cuadran, en las dos direcciones.

## Qué se revisa solo

`npm test` corre estos guardianes; ninguno necesita base de datos:

| Prueba | Qué evita |
|---|---|
| `inventario-migraciones` | Un script que el diagnóstico no ve. |
| `consultas-supabase` | `.order("a, b")` en una sola llamada; leer clientes sin el lector compartido; leer sin paginar una tabla de más de mil filas; una RPC que ninguna migración crea, o que al fallar no dice qué script correr. |
| `paginar` | Que `traerTodo()` deje renglones fuera, entregue media lista tras un error, o se cicle. |
| `catalogo-clientes` | Que el catálogo se quede sin respaldo o se trague el error. |
| `clientes-visibilidad` | Que la pantalla de Clientes vuelva a decir «Sin resultados» cuando en realidad falló. |
| `esquema-pendiente` | Que un error de esquema no diga qué script correr. |
| `nombres-indefinidos` | Identificadores que no existen (pantalla en blanco). |
| `pantallas` | Que una pantalla truene al dibujarse. |

Antes de subir: `npm run typecheck && npm test`.
