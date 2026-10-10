# Guía del equipo: protecciones y cómo correrlas

Kit-to-Drive está separada en tres capas y cada una tiene sus pruebas. Esta guía dice **qué comando
corre cada protección**, **en qué repo**, y **qué hacer cuando cambias algo**. La versión corta para
quien llega al front está en `kit-to-drive/docs/guia-del-equipo.md`.

## Quién es quién

| Capa | Repo | Qué contiene |
| --- | --- | --- |
| Back | `kit-to-drive-web` (este) | Migraciones, Edge Functions, diagnóstico, pruebas de base. **Única fuente de verdad de `supabase/`.** |
| Middle | `kit-to-drive-api` y `mati-app/mati-api` | La compuerta de datos del front y la API de administración. |
| Front | `kit-to-drive` y `mati-app/mati-admin` | Interfaces. No tienen llaves de Supabase. |

## Comandos por repo

Todos se corren desde la raíz del repo, con Node 22.

| Repo | Comando | Qué protege |
| --- | --- | --- |
| `kit-to-drive-web` | `npm install` y luego `npm test` | Migraciones registradas en el diagnóstico, seguridad de las migraciones, Edge Functions de acceso por correo, contrato con el front. |
| `kit-to-drive-web` | `npm run contrato` | Regenera `contrato/funciones.json` (las funciones que crean las migraciones). |
| `kit-to-drive-web` | `npm run deno:test` | Puente de administración y correo de acceso. **Requiere Deno 2.x** instalado. |
| `kit-to-drive-web` | `KIT_PG_PRUEBAS=1 PGHOST=… PGPORT=… npx vitest run compras-inventario-db` | Migraciones contra un Postgres local de verdad. Opcional; necesita Postgres. |
| `kit-to-drive` | `npm run typecheck`, `npm test`, `npm run build` | El front. Obligatorios antes de integrar a `main`. |
| `kit-to-drive` | `npm run sync:contrato` | Copia el contrato de funciones desde el back. |
| `kit-to-drive-api` | `npm install`, `npm test`, `npm run typecheck` | La compuerta: lista blanca, sesión, CORS, módulos apagados. |
| `mati-app/mati-api` | `npm test` | La API de administración (usuarios, módulos, soporte, correo). |

El back corre sus pruebas solo en cada cambio (`.github/workflows/pruebas.yml`).

## Qué hacer cuando cambias algo

**Agregas una migración** (en `kit-to-drive-web/supabase/migrations/`):
1. Regístrala en `supabase/diagnostico_esquema.sql` (objeto que deja la migración). `npm test` falla si no.
2. Si crea o cambia funciones: `npm run contrato`, y en el front `npm run sync:contrato`.
3. Pégala a mano en el SQL Editor de Supabase, corre la consulta de verificación y guarda el resultado en la tabla de control (`supabase/control/`).
4. Nunca dejes una función abierta a `anon`: las nuevas ya nacen cerradas, pero verifícalo.

**El front necesita una tabla, función o bucket nuevo:**
1. Agrégalo a `kit-to-drive-api/src/allowlist.ts` en un cambio revisado. Si no, la compuerta responde 403 «Tabla no permitida».
2. Corre `npm test` en `kit-to-drive-api` y despliega.

**Cambias una Edge Function:**
1. Edítala solo en `kit-to-drive-web/supabase/functions/`. Corre `npm test` y `npm run deno:test`.
2. Despliégala (flujo manual `deploy-edge-functions.yml` o desde el panel de Supabase).
3. Las contraseñas temporales **nunca** se escriben ni se devuelven al navegador: se generan en el servidor y viajan solo por correo.

## Protecciones que NO son comandos (se hacen a mano en paneles)

| Qué | Dónde | Estado |
| --- | --- | --- |
| Protección contra contraseñas filtradas | Supabase → Auth → Passwords | Pendiente de activar |
| SMTP propio de Auth (para «olvidé mi contraseña») | Supabase → Auth → SMTP Settings | Pendiente de revisar |
| `RESEND_API_KEY` y `RESEND_FROM_EMAIL` | Supabase → Edge Functions → Secrets | Configurados |
| Rotar la llave pública anterior | Supabase → API Keys (con plan: afecta a MATI Admin y funciones) | Pendiente |

## Reglas que no se negocian

- Ninguna función de `public` ejecutable por `anon`.
- El registro público de usuarios sigue cerrado; las altas las autoriza un administrador (`altas_autorizadas`).
- El front en producción habla solo con `kit-to-drive-api`; no lleva URL ni llave de Supabase.
- Una tabla o función nueva del front entra por la lista blanca de la compuerta, con revisión.
