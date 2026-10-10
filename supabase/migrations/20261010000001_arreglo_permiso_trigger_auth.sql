-- ============================================================================
-- Arreglo: crear usuarios fallaba con "Database error creating new user"
--
-- Causa: 20261009000002 quitó EXECUTE a PUBLIC en las funciones de `public`.
-- `handle_new_user()` es el trigger que corre al crear una cuenta en auth.users
-- y lo dispara el rol `supabase_auth_admin`, que lo tenía solo por PUBLIC.
-- (`reject_public_signups()` ya tenía una concesión explícita y no se afectó.)
--
-- Se concede de forma explícita a ese rol, sin reabrir nada a anon.
-- ============================================================================
GRANT EXECUTE ON FUNCTION public.handle_new_user() TO supabase_auth_admin;

-- Verificación: ambas deben salir en true y la lista de abajo en NULL.
SELECT
  has_function_privilege('supabase_auth_admin', 'public.handle_new_user()', 'execute')      AS handle_new_user_ok,
  has_function_privilege('supabase_auth_admin', 'public.reject_public_signups()', 'execute') AS reject_public_signups_ok,
  (SELECT string_agg(p.oid::regprocedure::text, ', ')
     FROM pg_trigger t
     JOIN pg_proc p ON p.oid = t.tgfoid
     JOIN pg_class c ON c.oid = t.tgrelid
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'auth' AND NOT t.tgisinternal
      AND NOT has_function_privilege('supabase_auth_admin', p.oid, 'execute')) AS triggers_auth_sin_permiso;
