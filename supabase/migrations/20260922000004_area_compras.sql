-- ============================================================================
-- Área Compras — paso 2/2: rol_legacy, helpers y RLS de proveedores
-- Fecha: 2026-09-22
--
-- Requiere que `20260922000003_area_compras_enum.sql` ya haya corrido
-- (y hecho COMMIT). Si falta el label `compras` en user_area/app_role,
-- el preflight se niega a tocar nada.
--
-- Compras escribe proveedores sin meterse a movimientos financieros.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
      JOIN pg_type ty ON ty.oid = e.enumtypid
      JOIN pg_namespace n ON n.oid = ty.typnamespace
     WHERE n.nspname = 'public' AND ty.typname = 'user_area' AND e.enumlabel = 'compras'
  ) THEN
    RAISE EXCEPTION 'No se modificó nada. Corre antes 20260922000003_area_compras_enum.sql (y confirma el COMMIT).';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
      JOIN pg_type ty ON ty.oid = e.enumtypid
      JOIN pg_namespace n ON n.oid = ty.typnamespace
     WHERE n.nspname = 'public' AND ty.typname = 'app_role' AND e.enumlabel = 'compras'
  ) THEN
    RAISE EXCEPTION 'No se modificó nada. Corre antes 20260922000003_area_compras_enum.sql (falta app_role.compras).';
  END IF;
  IF to_regclass('public.proveedores') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta la tabla proveedores (corre antes 20260823000004_finanzas_ingresos_egresos.sql).';
  END IF;
  IF to_regprocedure('public.es_finanzas(uuid)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta es_finanzas(uuid).';
  END IF;
END $preflight$;

-- 1. rol_legacy: Compras ↔ app_role.compras ----------------------------------
CREATE OR REPLACE FUNCTION public.rol_legacy(_area public.user_area, _nivel public.user_nivel)
RETURNS public.app_role LANGUAGE SQL IMMUTABLE AS $$
  SELECT (CASE
    WHEN _area = 'comercial'         AND _nivel = 'admin'      THEN 'director_ventas'
    WHEN _area = 'comercial'         AND _nivel = 'supervisor' THEN 'coordinador_ventas'
    WHEN _area = 'comercial'                                   THEN 'ventas'
    WHEN _area = 'fabrica'                                     THEN 'fabrica'
    WHEN _area = 'almacen_logistica'                           THEN 'logistica'
    WHEN _area = 'administracion'    AND _nivel = 'operador'   THEN 'finanzas'
    WHEN _area = 'administracion'                              THEN 'admin_financiero'
    WHEN _area = 'compras'                                     THEN 'compras'
    WHEN _area = 'direccion'         AND _nivel = 'admin'      THEN 'admin'
    WHEN _area = 'direccion'                                   THEN 'coordinador'
    ELSE 'ventas'
  END)::public.app_role
$$;

-- 2. Helpers -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.es_compras(_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.es_area(_uid, 'compras'::public.user_area)
      OR public.es_admin_global(_uid)
$$;

CREATE OR REPLACE FUNCTION public.es_compras_admin(_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.es_admin_area(_uid, 'compras'::public.user_area)
$$;

REVOKE EXECUTE ON FUNCTION public.es_compras(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.es_compras_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_compras(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_compras_admin(uuid) TO authenticated;

-- 3. Proveedores: Compras escribe; Finanzas también (como antes) ------------
DROP POLICY IF EXISTS proveedores_insert ON public.proveedores;
CREATE POLICY proveedores_insert ON public.proveedores
  FOR INSERT TO authenticated
  WITH CHECK (public.es_finanzas(auth.uid()) OR public.es_compras(auth.uid()));

DROP POLICY IF EXISTS proveedores_update ON public.proveedores;
CREATE POLICY proveedores_update ON public.proveedores
  FOR UPDATE TO authenticated
  USING (public.es_finanzas(auth.uid()) OR public.es_compras(auth.uid()));

DROP POLICY IF EXISTS proveedores_delete ON public.proveedores;
CREATE POLICY proveedores_delete ON public.proveedores
  FOR DELETE TO authenticated
  USING (public.es_finanzas_admin(auth.uid()) OR public.es_compras_admin(auth.uid()));

-- 4. Postflight --------------------------------------------------------------
DO $postflight$
BEGIN
  IF to_regprocedure('public.es_compras(uuid)') IS NULL THEN
    RAISE EXCEPTION 'No quedó la función es_compras(uuid).';
  END IF;
  IF to_regprocedure('public.es_compras_admin(uuid)') IS NULL THEN
    RAISE EXCEPTION 'No quedó la función es_compras_admin(uuid).';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'proveedores'
       AND policyname = 'proveedores_insert'
       AND COALESCE(with_check, '') LIKE '%es_compras%'
  ) THEN
    RAISE EXCEPTION 'La política proveedores_insert no menciona es_compras.';
  END IF;
END $postflight$;
