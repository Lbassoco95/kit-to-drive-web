-- ═══════════════════════════════════════════════════════════════════════════
-- `profiles.activo` deja de ser decorativo
--
-- Hasta ahora desactivar a alguien desde Sistema → Usuarios sólo lo pintaba en
-- gris en esa lista: no se validaba en el login, ni en `ProtectedRoute`, ni en
-- ninguna política de RLS. Un usuario «inactivo» entraba igual y leía igual.
--
-- En vez de perseguir cada política una por una, se aprovecha que TODAS pasan
-- por el mismo puñado de helpers (`has_role`, `es_area`, `nivel_al_menos`,
-- `es_admin_area`, `es_admin_global`, `supervisa_area`). Con que esos devuelvan
-- FALSE para un usuario dado de baja, el corte aplica en todo el sistema de
-- golpe y sin reescribir una sola política.
--
-- Criterio conservador a propósito: se bloquea sólo a quien está marcado
-- explícitamente como inactivo. Un `profiles` inexistente o un `activo` nulo
-- NO deja a nadie fuera — un error de datos no debe convertirse en un usuario
-- que no puede trabajar.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. El predicado, en un solo lugar ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.usuario_activo(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = _user_id AND p.activo IS FALSE
  )
$$;

COMMENT ON FUNCTION public.usuario_activo(UUID) IS
  'FALSE sólo si el usuario está marcado explícitamente como inactivo en '
  'profiles.activo. Un perfil ausente o nulo cuenta como activo, para que un '
  'hueco de datos no bloquee a nadie. Lo consultan todos los helpers de rol.';

REVOKE EXECUTE ON FUNCTION public.usuario_activo(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.usuario_activo(UUID) TO authenticated;

-- ── 2. Los helpers de rol lo respetan ──────────────────────────────────────
-- Rol legacy.
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

-- Área.
CREATE OR REPLACE FUNCTION public.es_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND area = _area)
$$;

-- Nivel mínimo.
CREATE OR REPLACE FUNCTION public.nivel_al_menos(_user_id UUID, _nivel public.user_nivel)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id AND public.nivel_rank(nivel) >= public.nivel_rank(_nivel)
     )
$$;

-- Administrador de área (o global).
CREATE OR REPLACE FUNCTION public.es_admin_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id AND nivel = 'admin' AND (area = _area OR area = 'direccion')
     )
$$;

-- Administrador global (Dirección).
CREATE OR REPLACE FUNCTION public.es_admin_global(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id AND nivel = 'admin' AND area = 'direccion'
     )
$$;

-- Supervisa o administra el área.
CREATE OR REPLACE FUNCTION public.supervisa_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id
          AND public.nivel_rank(nivel) >= 2
          AND (area = _area OR (area = 'direccion' AND nivel = 'admin'))
     )
$$;

-- ── 3. El dueño de una remisión tampoco entra si está dado de baja ─────────
-- Varias políticas caen a `vendedor_id = auth.uid()` cuando el rol no alcanza.
-- Sin esto, un vendedor desactivado seguiría leyendo y editando lo suyo.
DROP POLICY IF EXISTS "leer remisiones por rol" ON public.remisiones;
CREATE POLICY "leer remisiones por rol" ON public.remisiones
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR has_role(auth.uid(),'ventas'::app_role)
  OR (vendedor_id = auth.uid() AND public.usuario_activo(auth.uid()))
);

DROP POLICY IF EXISTS "actualizar remisiones" ON public.remisiones;
CREATE POLICY "actualizar remisiones" ON public.remisiones
FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR (vendedor_id = auth.uid() AND public.usuario_activo(auth.uid()))
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
  OR has_role(auth.uid(),'ventas'::app_role)
  OR (public.usuario_activo(auth.uid()) AND remision_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM remisiones r
         WHERE r.id = motocarros.remision_id AND r.vendedor_id = auth.uid()))
);

-- ── Verificación ───────────────────────────────────────────────────────────
-- 1. Nadie activo debe perder permisos: esta consulta lista a cada usuario con
--    lo que los helpers responden hoy. Los activos deben verse igual que antes.
SELECT p.nombre_completo, p.activo, ur.area, ur.nivel,
       public.usuario_activo(ur.user_id)              AS activo_efectivo,
       public.es_area(ur.user_id, ur.area)            AS pasa_su_area,
       public.has_role(ur.user_id, ur.role)           AS pasa_su_rol_legacy
  FROM public.user_roles ur
  JOIN public.profiles p ON p.id = ur.user_id
 ORDER BY p.activo DESC, ur.area, ur.nivel, p.nombre_completo;

-- 2. Ningún usuario activo debe salir con `pasa_su_area = false`. Si aparece
--    alguno aquí, algo se rompió y hay que revisar antes de seguir.
SELECT p.nombre_completo, ur.area, ur.nivel
  FROM public.user_roles ur
  JOIN public.profiles p ON p.id = ur.user_id
 WHERE p.activo AND NOT public.es_area(ur.user_id, ur.area);
