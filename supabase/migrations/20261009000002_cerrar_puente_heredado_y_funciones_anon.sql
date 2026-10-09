-- ============================================================================
-- Cierre de seguridad: puente heredado patio_kit_* y funciones abiertas a anon
--
-- 1) Retira el puente anterior `patio_kit_*` (nada lo usa; su token vivía en
--    texto plano en `patio_bridge_secret`). Las definiciones originales siguen
--    en 20260925193000_security_hardening_fase2.sql por si hiciera falta volver.
-- 2) Ninguna función de `public` se puede ejecutar sin sesión. El acceso de
--    `anon` venía del permiso por defecto de PUBLIC, por eso se quita de ahí y
--    se concede de forma explícita a `authenticated` y `service_role`.
-- 3) Las funciones nuevas ya no nacen abiertas a anon/PUBLIC.
--
-- Una sola transacción: o se aplica completo o no cambia nada.
-- Se pega en el editor SQL de Supabase (el conector MCP se cuelga con DDL).
-- ============================================================================
DO $$
DECLARE r record;
BEGIN
  DROP FUNCTION IF EXISTS public.patio_kit_list_users(text);
  DROP FUNCTION IF EXISTS public.patio_kit_overview(text);
  DROP FUNCTION IF EXISTS public.patio_kit_set_user_active(text, uuid, boolean);
  DROP FUNCTION IF EXISTS public.patio_kit_set_user_role(text, uuid, text, text, text);
  DROP FUNCTION IF EXISTS public.patio_kit_update_config(text, text, integer, integer, integer);
  DROP FUNCTION IF EXISTS public._patio_bridge_ok(text);
  DROP TABLE IF EXISTS public.patio_bridge_secret;

  FOR r IN
    SELECT p.oid::regprocedure AS firma
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
      AND has_function_privilege('anon', p.oid, 'execute')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', r.firma);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', r.firma);
  END LOOP;

  ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;
END $$;

-- Verificación: las tres cifras deben salir en 0, 0 y NULL.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
      AND has_function_privilege('anon', p.oid, 'execute')) AS funciones_abiertas_a_anon,
  (SELECT count(*) FROM pg_proc WHERE proname LIKE '%patio%') AS funciones_patio,
  to_regclass('public.patio_bridge_secret') AS tabla_secreto;
