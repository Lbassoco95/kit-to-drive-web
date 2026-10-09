-- El vendedor solo ve SU información · parte 3/3: CRM: vendedor lo suyo, supervisor asigna
-- Ver 20261007000001 (parte 1) para el contexto completo. Correr en orden 1, 2, 3.

-- ── 7. CRM: vendedor = lo suyo; supervisor/admin = todo y asigna ───────────
-- Lectura
DROP POLICY IF EXISTS "crm_oport_select" ON public.crm_oportunidades;
CREATE POLICY "crm_oport_select" ON public.crm_oportunidades FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR vendedor_id = auth.uid()
);
DROP POLICY IF EXISTS "crm_act_select" ON public.crm_actividades;
CREATE POLICY "crm_act_select" ON public.crm_actividades FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR vendedor_id = auth.uid()
);
DROP POLICY IF EXISTS "crm_rutas_select" ON public.crm_rutas;
CREATE POLICY "crm_rutas_select" ON public.crm_rutas FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR vendedor_id = auth.uid()
);

-- Alta: el vendedor solo a su nombre; el supervisor/admin a nombre de cualquiera
-- (así asigna actividades, oportunidades y rutas).
DROP POLICY IF EXISTS "crm_oport_insert" ON public.crm_oportunidades;
CREATE POLICY "crm_oport_insert" ON public.crm_oportunidades FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR (public.es_area(auth.uid(),'comercial') AND vendedor_id = auth.uid())
);
DROP POLICY IF EXISTS "crm_act_insert" ON public.crm_actividades;
CREATE POLICY "crm_act_insert" ON public.crm_actividades FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR (public.es_area(auth.uid(),'comercial') AND vendedor_id = auth.uid())
);
DROP POLICY IF EXISTS "crm_rutas_insert" ON public.crm_rutas;
CREATE POLICY "crm_rutas_insert" ON public.crm_rutas FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR (public.es_area(auth.uid(),'comercial') AND vendedor_id = auth.uid())
);

-- Edición: supervisor/admin (incluye `director_ventas`, que antes quedaba fuera)
DROP POLICY IF EXISTS "crm_oport_update" ON public.crm_oportunidades;
CREATE POLICY "crm_oport_update" ON public.crm_oportunidades FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR vendedor_id = auth.uid()
);
DROP POLICY IF EXISTS "crm_act_update" ON public.crm_actividades;
CREATE POLICY "crm_act_update" ON public.crm_actividades FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR vendedor_id = auth.uid()
);
DROP POLICY IF EXISTS "crm_rutas_update" ON public.crm_rutas;
CREATE POLICY "crm_rutas_update" ON public.crm_rutas FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR public.ve_todo_comercial(auth.uid())
  OR vendedor_id = auth.uid()
);

-- Paradas de ruta: siguen a la ruta visible.
DROP POLICY IF EXISTS "crm_paradas_all" ON public.crm_ruta_paradas;
CREATE POLICY "crm_paradas_all" ON public.crm_ruta_paradas FOR ALL
USING (EXISTS (SELECT 1 FROM public.crm_rutas r WHERE r.id = crm_ruta_paradas.ruta_id))
WITH CHECK (EXISTS (SELECT 1 FROM public.crm_rutas r WHERE r.id = crm_ruta_paradas.ruta_id));
