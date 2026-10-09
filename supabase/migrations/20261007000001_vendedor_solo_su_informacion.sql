-- El vendedor solo ve SU información · parte 1/3: helper, remisiones, unidades y partidas
-- Correr en orden: 20261007000001, 20261007000002, 20261007000003.

-- ── 0. Helper: ¿ve a todo el equipo comercial? (supervisor+ de Comercial,
--       o admin global de Dirección)
CREATE OR REPLACE FUNCTION public.ve_todo_comercial(_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.supervisa_area(_user_id, 'comercial'::public.user_area)
$$;
REVOKE ALL ON FUNCTION public.ve_todo_comercial(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ve_todo_comercial(uuid) TO authenticated;

-- ── 1. remisiones ──────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "comercial lee remisiones" ON public.remisiones;
CREATE POLICY "comercial lee remisiones" ON public.remisiones
FOR SELECT TO authenticated
USING (
  public.ve_todo_comercial(auth.uid())
  OR (public.es_area(auth.uid(), 'comercial') AND vendedor_id = auth.uid()
      AND public.usuario_activo(auth.uid()))
  OR public.es_area(auth.uid(), 'direccion')
  OR public.es_area(auth.uid(), 'administracion')
);

-- Quita `ventas` (veía todo); el dueño sigue viendo lo suyo.
DROP POLICY IF EXISTS "leer remisiones por rol" ON public.remisiones;
CREATE POLICY "leer remisiones por rol" ON public.remisiones
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR (vendedor_id = auth.uid() AND public.usuario_activo(auth.uid()))
);

-- ── 2. motocarros (unidades de la remisión) ────────────────────────────────
DROP POLICY IF EXISTS "comercial lee motocarros" ON public.motocarros;
CREATE POLICY "comercial lee motocarros" ON public.motocarros
FOR SELECT TO authenticated
USING (
  public.ve_todo_comercial(auth.uid())
  OR (public.es_area(auth.uid(), 'comercial') AND remision_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.remisiones r
                   WHERE r.id = motocarros.remision_id AND r.vendedor_id = auth.uid()))
);

DROP POLICY IF EXISTS "leer motocarros por rol" ON public.motocarros;
CREATE POLICY "leer motocarros por rol" ON public.motocarros
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR (remision_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.remisiones r
         WHERE r.id = motocarros.remision_id AND r.vendedor_id = auth.uid()))
);

-- ── 3. remision_items: ya no «true»; sigue a la visibilidad de la remisión ─
DROP POLICY IF EXISTS "remision_items_select" ON public.remision_items;
CREATE POLICY "remision_items_select" ON public.remision_items
FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = remision_items.remision_id));
