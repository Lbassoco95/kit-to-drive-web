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
- **`admin-create-user`: el repo va adelante de producción.** La versión
  desplegada (v11) no acepta el área `compras`; la del repo sí. Pendiente de
  desplegar.
