-- ═══════════════════════════════════════════════════════════════════════════
-- Comercial lee la bandeja completa, sin importar el nivel
--
-- `20260823000005_usuarios_niveles_areas.sql` dejó la lectura de remisiones
-- amarrada a `supervisa_area('comercial')`, o sea supervisor para arriba. Un
-- **operador** de Comercial quedaba viendo sólo lo suyo, que es justo el
-- problema que `20260824000001` había resuelto para el rol `ventas`: el equipo
-- comercial no compartía la misma información y un vendedor recién dado de
-- alta abría la bandeja vacía.
--
-- Aquí se separan las dos cosas, que no son la misma:
--
--   LEER  → toda el área comercial, en cualquier nivel. Todos trabajan sobre
--           la misma información.
--   ESCRIBIR → sigue por nivel. El operador captura y edita lo suyo; el
--           supervisor corrige lo de cualquiera; el administrador borra.
--
-- No se toca ninguna política de escritura.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. remisiones: lectura para toda el área comercial ─────────────────────
DROP POLICY IF EXISTS "comercial lee remisiones" ON public.remisiones;
CREATE POLICY "comercial lee remisiones" ON public.remisiones
FOR SELECT TO authenticated
USING (
  public.es_area(auth.uid(), 'comercial')      -- ← antes: supervisa_area(...)
  OR public.es_area(auth.uid(), 'direccion')
  OR public.es_area(auth.uid(), 'administracion')
);

-- ── 2. motocarros: lo mismo, o las tarjetas salen sin chasis ───────────────
-- Este hueco no era sólo del operador. El rol legacy se deriva de (área,nivel)
-- por trigger, así que un supervisor de Comercial queda con `coordinador_ventas`
-- y un administrador con `director_ventas`; ninguno de los dos aparece en
-- `leer motocarros por rol`, y `direccion lee motocarros` sólo cubre Dirección
-- y Administración. Resultado: veían la remisión pero no sus unidades.
DROP POLICY IF EXISTS "comercial lee motocarros" ON public.motocarros;
CREATE POLICY "comercial lee motocarros" ON public.motocarros
FOR SELECT TO authenticated
USING (public.es_area(auth.uid(), 'comercial'));

-- ── Verificación ───────────────────────────────────────────────────────────
-- 1. Las dos políticas deben resolverse por área, no por nivel.
SELECT tablename, policyname, qual
  FROM pg_policies
 WHERE schemaname = 'public'
   AND policyname IN ('comercial lee remisiones','comercial lee motocarros');

-- 2. Cada quien con su área y su nivel, y si lee la bandeja completa.
SELECT p.nombre_completo, ur.area, ur.nivel, ur.role AS rol_legacy_derivado,
       public.es_area(ur.user_id, 'comercial') AS lee_bandeja_comercial
  FROM public.user_roles ur
  JOIN public.profiles p ON p.id = ur.user_id
 ORDER BY ur.area, ur.nivel, p.nombre_completo;

-- 3. La escritura NO debe haberse abierto: sigue por nivel.
SELECT policyname, cmd, qual, with_check
  FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'remisiones' AND cmd <> 'SELECT'
 ORDER BY cmd, policyname;
