-- =============================================================================
-- Hardening fase 2 — go-live (residuales Media/Alta post-#30)
-- Idempotente. No toca Auth dashboard (Signups / leaked-password = ops).
-- =============================================================================

-- ── 1. Inventario: políticas de escritura con nombre engañoso y USING(true) ─
-- En remoto quedaron "admin fabrica escriben *" con qual=true (cualquier
-- autenticado escribe). Se reinstala least-privilege alineado a migraciones
-- originales + modelo área×nivel.

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'inventario_chasis',
    'inventario_motor',
    'inventario_partes',
    'inventario_colores'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'admin fabrica escriben chasis', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'admin fabrica escriben motores', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'admin fabrica escriben partes', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'admin fabrica escriben colores', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'autenticados leen inventario', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'autenticados leen colores', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'autenticados leen motores', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'autenticados leen partes', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'leer inventario chasis', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'leer inventario motor', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'leer inventario partes', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'leer inventario colores', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'escribir inventario chasis admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'escribir inventario motor admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'escribir inventario partes admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'escribir inventario colores admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'actualizar inventario chasis admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'actualizar inventario motor admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'actualizar inventario partes admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'actualizar inventario colores admin/fabrica', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'borrar inventario chasis admin', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'borrar inventario motor admin', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'borrar inventario partes admin', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'borrar inventario colores admin', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'inv_select_operativo', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'inv_insert_ops', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'inv_update_ops', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'inv_delete_admin', t);
  END LOOP;
END $$;

-- Helper: quién opera inventario de fábrica/almacén
CREATE OR REPLACE FUNCTION public.puede_escribir_inventario(_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.usuario_activo(_uid)
    AND (
      public.es_admin_global(_uid)
      OR public.es_area(_uid, 'fabrica'::public.user_area)
      OR public.es_area(_uid, 'almacen_logistica'::public.user_area)
      OR public.es_area(_uid, 'compras'::public.user_area)
      OR public.has_role(_uid, 'admin'::app_role)
      OR public.has_role(_uid, 'fabrica'::app_role)
      OR public.has_role(_uid, 'logistica'::app_role)
      OR public.has_role(_uid, 'compras'::app_role)
    );
$$;

REVOKE ALL ON FUNCTION public.puede_escribir_inventario(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_escribir_inventario(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.puede_leer_inventario(_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.usuario_activo(_uid)
    AND (
      public.puede_escribir_inventario(_uid)
      OR public.es_area(_uid, 'comercial'::public.user_area)
      OR public.es_area(_uid, 'administracion'::public.user_area)
      OR public.es_area(_uid, 'direccion'::public.user_area)
      OR public.has_role(_uid, 'ventas'::app_role)
      OR public.has_role(_uid, 'coordinador'::app_role)
      OR public.has_role(_uid, 'finanzas'::app_role)
      OR public.has_role(_uid, 'admin_financiero'::app_role)
    );
$$;

REVOKE ALL ON FUNCTION public.puede_leer_inventario(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_leer_inventario(uuid) TO authenticated, service_role;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'inventario_chasis',
    'inventario_motor',
    'inventario_partes',
    'inventario_colores'
  ]
  LOOP
    EXECUTE format(
      'CREATE POLICY inv_select_operativo ON public.%I FOR SELECT TO authenticated USING (public.puede_leer_inventario(auth.uid()))',
      t
    );
    EXECUTE format(
      'CREATE POLICY inv_insert_ops ON public.%I FOR INSERT TO authenticated WITH CHECK (public.puede_escribir_inventario(auth.uid()))',
      t
    );
    EXECUTE format(
      'CREATE POLICY inv_update_ops ON public.%I FOR UPDATE TO authenticated USING (public.puede_escribir_inventario(auth.uid())) WITH CHECK (public.puede_escribir_inventario(auth.uid()))',
      t
    );
    EXECUTE format(
      'CREATE POLICY inv_delete_admin ON public.%I FOR DELETE TO authenticated USING (public.es_admin_global(auth.uid()) OR public.has_role(auth.uid(), ''admin''::app_role))',
      t
    );
  END LOOP;
END $$;

-- ── 2. Compras / CxC / documentos inventario: quitar SELECT universal ───────
DROP POLICY IF EXISTS "leer compras" ON public.compras;
DROP POLICY IF EXISTS "leer compra lineas" ON public.compra_lineas;
DROP POLICY IF EXISTS cxc_select ON public.cuentas_por_cobrar;
DROP POLICY IF EXISTS cxc_abonos_select ON public.cxc_abonos;
DROP POLICY IF EXISTS "leer documentos inventario" ON public.documentos_inventario;
DROP POLICY IF EXISTS "leer documento inventario lineas" ON public.documento_inventario_lineas;

CREATE POLICY "leer compras" ON public.compras
  FOR SELECT TO authenticated
  USING (
    public.es_compras(auth.uid())
    OR public.es_finanzas(auth.uid())
    OR public.es_admin_global(auth.uid())
  );

CREATE POLICY "leer compra lineas" ON public.compra_lineas
  FOR SELECT TO authenticated
  USING (
    public.es_compras(auth.uid())
    OR public.es_finanzas(auth.uid())
    OR public.es_admin_global(auth.uid())
  );

CREATE POLICY cxc_select ON public.cuentas_por_cobrar
  FOR SELECT TO authenticated
  USING (
    public.es_finanzas(auth.uid())
    OR public.es_admin_global(auth.uid())
    OR public.es_area(auth.uid(), 'comercial'::public.user_area)
    OR public.has_role(auth.uid(), 'ventas'::app_role)
    OR public.has_role(auth.uid(), 'director_ventas'::app_role)
    OR public.has_role(auth.uid(), 'coordinador_ventas'::app_role)
  );

CREATE POLICY cxc_abonos_select ON public.cxc_abonos
  FOR SELECT TO authenticated
  USING (
    public.es_finanzas(auth.uid())
    OR public.es_admin_global(auth.uid())
  );

CREATE POLICY "leer documentos inventario" ON public.documentos_inventario
  FOR SELECT TO authenticated
  USING (public.puede_leer_inventario(auth.uid()));

CREATE POLICY "leer documento inventario lineas" ON public.documento_inventario_lineas
  FOR SELECT TO authenticated
  USING (public.puede_leer_inventario(auth.uid()));

-- ── 3. remisiones-docs: MIME + tamaño ───────────────────────────────────────
UPDATE storage.buckets
   SET public = false,
       file_size_limit = 15728640,
       allowed_mime_types = ARRAY[
         'application/pdf',
         'image/jpeg',
         'image/png',
         'image/webp',
         'image/heic',
         'image/heif'
       ]
 WHERE id = 'remisiones-docs';

-- ── 4. Vistas: security_invoker (respeta RLS del caller) ───────────────────
DO $$
DECLARE
  v text;
BEGIN
  FOREACH v IN ARRAY ARRAY[
    'v_reporte_remisiones',
    'v_reporte_produccion',
    'v_reporte_pagos',
    'v_reporte_pipeline',
    'v_stock_modelo_color',
    'v_carga_ya_armados',
    'v_clientes_credito'
  ]
  LOOP
    IF to_regclass('public.' || v) IS NOT NULL THEN
      EXECUTE format('ALTER VIEW public.%I SET (security_invoker = true)', v);
    END IF;
  END LOOP;
END $$;

-- ── 5. search_path en funciones residuales del advisor ─────────────────────
DO $$
BEGIN
  IF to_regprocedure('public.generar_folio_interno_cliente()') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.generar_folio_interno_cliente() SET search_path = public';
  END IF;
  IF to_regprocedure('public.trg_clientes_folio_interno()') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.trg_clientes_folio_interno() SET search_path = public';
  END IF;
END $$;

-- ── 6. patio_bridge_secret: RLS sin políticas → denegar todo a roles API ───
DO $$
BEGIN
  IF to_regclass('public.patio_bridge_secret') IS NOT NULL THEN
    REVOKE ALL ON public.patio_bridge_secret FROM PUBLIC, anon, authenticated;
    -- Sin políticas + RLS ON = nadie vía PostgREST; solo superuser/service_role.
  END IF;
END $$;
