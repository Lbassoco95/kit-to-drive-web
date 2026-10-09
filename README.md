# kit-to-drive-back

Back de Dazon: base de datos y funciones de servidor en Supabase.

- `supabase/migrations/` — línea base documental del esquema (no se usa `supabase db push`).
- `supabase/functions/` — Edge Functions (admin-create-user, admin-update-user, admin-reset-user-password, complete-password-change, seed-demo-users).
- `docs/` — arquitectura en capas y reglas para no romper producción.

El front vive en `lbassoco95/kit-to-drive` (Vercel). Orden de cambios: primero el back, después el front.
