# Pruebas del puente (sin red ni base)

Cubren autenticación, enrutado y validación de entrada con un cliente de
Supabase falso. NO prueban las rutas que tocan la base.

    deno run --allow-env --import-map _tests/import_map.json _tests/test.ts
    deno check --import-map _tests/import_map.json index.ts   # tipos
