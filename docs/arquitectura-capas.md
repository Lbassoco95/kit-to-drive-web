# Arquitectura en tres capas (back / middle / front)

Estado: **propuesta**, nada migrado todavía.

## Decisión: el middle vive en el mismo repo

El middle es una capa de código (`src/services`), no un servidor aparte.

Un servicio middle desplegado por separado (Node/API propia) se descarta por
ahora: añade otro despliegue, otro punto de fallo y otra autenticación, y el
problema real no es de infraestructura sino de que el front consulta la base
directamente desde 40 archivos. Se reevalúa solo si aparece una necesidad que
el front y Postgres no cubren (ver «Cuándo sí un servicio aparte»).

## Las tres capas

| Capa | Dónde | Responsabilidad | No debe |
|---|---|---|---|
| **Back** | Supabase: tablas, RLS, funciones RPC, Edge Functions | Integridad, permisos y operaciones críticas transaccionales | Depender de que el front valide |
| **Middle** | `src/services/<módulo>/` | Único lugar que habla con Supabase. Devuelve datos tipados, lanza errores explícitos, pagina | Importar React ni componentes |
| **Front** | `src/pages`, `src/components`, hooks `use<Módulo>` (React Query) | Pantallas y estado de UI | Llamar a `supabase.from/rpc/storage` |

Las reglas puras (cálculos, parsers) siguen en `src/lib` y se prueban sin red.

```
src/services/
  base.ts            # cliente, `unwrap()` que lanza el error, paginar()
  remisiones/        # index.ts (API), queries.ts, tipos.ts
  clientes/
  ...
src/hooks/queries/   # useRemisiones, useClientes… (React Query sobre services)
```

Regla central: **un error de Supabase nunca se convierte en lista vacía**.
`unwrap()` lo lanza y la pantalla muestra el error (origen de los incidentes
«Sin resultados» de `docs/no-romper-produccion.md`).

## Qué es lo importante migrar (por acoplamiento hoy)

Llamadas directas a Supabase por archivo (de mayor a menor):

| Prioridad | Módulo | Archivos clave (llamadas) |
|---|---|---|
| 1 | Remisiones motocarro | `pages/Remisiones.tsx` (47), `components/BandejaRemisiones.tsx` (27) |
| 2 | Remisiones refacciones / almacén | `RemisionesRefacciones.tsx` (21), `AlmacenRefacciones.tsx` (6) |
| 3 | Clientes | `Clientes.tsx` (21), `lib/catalogoClientes.ts` |
| 4 | Producción / Inventario | `Produccion.tsx` (19), `Inventario.tsx` (8), `RecibirContenedor.tsx`, `ConfigurarUnidad.tsx` |
| 5 | CRM | `pages/crm/*` (~40 en total) |
| 6 | Dashboard / reportes | `Dashboard.tsx` (20), `ReportesTurno.tsx` |
| 7 | Usuarios / Auth | `Usuarios.tsx`, `AuthContext.tsx` (ya apoyado en Edge Functions) |

Primero Remisiones: es lo más usado, lo más acoplado y donde más han fallado
las consultas. Los módulos de almacén y remisiones de refacciones son parte de
la versión base y no se eliminan ni se reescriben a ciegas.

## Cómo se migra un módulo (PR pequeño por módulo)

1. Crear `services/<módulo>` copiando **las mismas consultas** (sin cambiar
   comportamiento) y un test que fije las columnas/forma de las consultas.
2. Cambiar la pantalla para usar el service/hook. Sin cambios visuales.
3. Mover las operaciones de varios pasos a una función RPC transaccional **en
   un PR aparte** (cambia la base; ver abajo).
4. `npm run typecheck`, `npm run test`, `npm run build` antes de integrar.
5. Cuando un módulo queda limpio, regla ESLint (`no-restricted-imports` /
   `no-restricted-syntax` sobre `supabase.from`) para su carpeta, de modo que
   no vuelva a filtrarse.

## Reglas de base de datos (back)

- Todo cambio de esquema que necesite un service nuevo se aplica **antes** de
  desplegar el código que lo pide (ver `docs/no-romper-produccion.md`).
- Pendiente de cerrar: tabla de migraciones aplicadas y `diagnostico_esquema.sql`
  como paso previo, para eliminar el desfase código/base.
- Operaciones con varios pasos hoy hechas en el cliente (por ejemplo asignar
  chasis a remisión, aplicar pagos) deben ser RPC: todo o nada en servidor.

## Cuándo sí un servicio aparte

Solo si se requiere algo que no cabe en RLS + RPC + Edge Functions: secretos de
terceros (ERP, correo, WhatsApp), trabajos programados largos, o integraciones
entrantes (webhooks). En ese caso, empezar por **Edge Functions** (ya existen
cinco) y no por un servidor nuevo.
