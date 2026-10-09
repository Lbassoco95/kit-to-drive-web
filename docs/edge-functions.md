# Edge Functions

Fuente de verdad: `supabase/functions/` de este repo. Se despliegan con el
workflow **Deploy Edge Function** (manual, una función a la vez).

| Función | verify_jwt | Qué hace |
|---|---|---|
| `admin-create-user` | sí | Alta de usuarios (admin) |
| `admin-update-user` | sí | Edita usuario, correo y rol (admin) |
| `admin-reset-user-password` | sí | Contraseña temporal (admin) |
| `complete-password-change` | sí | El usuario cambia su propia contraseña |
| `seed-demo-users` | sí | Deshabilitada en producción (410) |
| `mati-admin-bridge` | **no** | Puente para mati-admin; se autentica con `MATI_ADMIN_BRIDGE_SECRET` |

## Estado de la verificación (2026-10-09, proyecto kit-to-drive)

- Las seis funciones están desplegadas. `mati-admin-bridge` **no estaba en
  ningún repo**; su código se rescató aquí tal cual estaba desplegado (v3).
- `admin-update-user`, `admin-reset-user-password`, `complete-password-change`
  y `seed-demo-users` coinciden con lo desplegado en lo revisado.
- **`admin-create-user`: el repo iba adelante de producción; ya se desplegó
  (v12, 2026-10-09).** La v11 no aceptaba el área `compras` y escribía
  `must_change_password` en `user_metadata`, que el front ignora, así que los
  usuarios nuevos con contraseña temporal no eran forzados a cambiarla. La v12
  (la del repo) corrige ambas cosas y usa `profiles.debe_cambiar_password`.

## Secreto del puente

`MATI_ADMIN_BRIDGE_SECRET` no lo entrega nadie: se inventa una vez (cadena
aleatoria larga, p. ej. `openssl rand -hex 32`) y se guarda **igual** en dos
lados: Supabase (Edge Functions → Secrets) y el entorno de mati-api/mati-admin,
que es quien lo manda. Sin él la función responde 503; con él mal puesto, 401.
Prueba sin riesgo: `GET .../functions/v1/mati-admin-bridge/health` → 503 = falta
el secreto, 401 = existe.
