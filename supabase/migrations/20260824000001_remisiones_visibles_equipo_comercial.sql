-- ═══════════════════════════════════════════════════════════════════════════
-- Visibilidad compartida de remisiones para el equipo comercial (rol `ventas`)
--
-- Problema: el rol `ventas` sólo podía LEER las remisiones donde
-- `vendedor_id = auth.uid()`. Un vendedor recién dado de alta veía la bandeja
-- vacía y el equipo comercial no compartía la misma información.
--
-- Solución: `ventas` lee TODAS las remisiones (y sus motocarros / líneas),
-- igual que admin, coordinador, fábrica, logística y finanzas.
-- La ESCRITURA no cambia: cada vendedor sigue creando/editando sólo lo suyo
-- (ver políticas «crear remisiones» / «actualizar remisiones»).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. remisiones: lectura para todo el equipo comercial ───────────────────
DROP POLICY IF EXISTS "leer remisiones por rol" ON public.remisiones;
CREATE POLICY "leer remisiones por rol" ON public.remisiones
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR has_role(auth.uid(),'ventas'::app_role)   -- ← equipo comercial ve todo
  OR vendedor_id = auth.uid()
);

-- ── 2. motocarros: mismas reglas, si no las tarjetas salen vacías ──────────
DROP POLICY IF EXISTS "leer motocarros por rol" ON public.motocarros;
CREATE POLICY "leer motocarros por rol" ON public.motocarros
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR has_role(auth.uid(),'ventas'::app_role)   -- ← equipo comercial ve todo
  OR (remision_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM remisiones r
        WHERE r.id = motocarros.remision_id AND r.vendedor_id = auth.uid()))
);

-- ── 3. remision_items: asegurar lectura abierta a autenticados ─────────────
-- (la migración original ya la dejaba en `true`; se re-crea por idempotencia
--  en instalaciones donde se hubiera endurecido a mano)
DROP POLICY IF EXISTS "remision_items_select" ON public.remision_items;
CREATE POLICY "remision_items_select"
  ON public.remision_items FOR SELECT
  TO authenticated
  USING (true);

-- ── Verificación ───────────────────────────────────────────────────────────
SELECT tablename, policyname
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('remisiones','motocarros','remision_items')
  AND cmd = 'SELECT'
ORDER BY tablename, policyname;
