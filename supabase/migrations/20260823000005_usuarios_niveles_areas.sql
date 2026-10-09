-- ============================================================================
-- Usuarios: TIPO DE USUARIO (nivel) × ÁREA
-- ----------------------------------------------------------------------------
-- Solo hay tres tipos de usuario: operador, supervisor y admin.
-- El área (Comercial, Fábrica, Almacén y Logística, Administración, Dirección)
-- es una dimensión independiente y define QUÉ módulos toca el usuario.
--
-- La columna legacy `user_roles.role` (enum app_role) se conserva y se deriva
-- automáticamente de (area, nivel) con un trigger, para que las políticas RLS
-- y funciones existentes sigan funcionando sin reescribirlas.
-- ============================================================================

-- 1. Enums nuevos ------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE public.user_nivel AS ENUM ('operador','supervisor','admin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.user_area AS ENUM ('comercial','fabrica','almacen_logistica','administracion','direccion');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 2. Columnas en user_roles --------------------------------------------------
ALTER TABLE public.user_roles
  ADD COLUMN IF NOT EXISTS nivel public.user_nivel,
  ADD COLUMN IF NOT EXISTS area  public.user_area;

-- 3. Backfill desde el rol legacy -------------------------------------------
UPDATE public.user_roles SET
  area = CASE role::TEXT
    WHEN 'admin'              THEN 'direccion'
    WHEN 'director_ventas'    THEN 'comercial'
    WHEN 'coordinador_ventas' THEN 'comercial'
    WHEN 'coordinador'        THEN 'comercial'
    WHEN 'ventas'             THEN 'comercial'
    WHEN 'auxiliar_ventas'    THEN 'comercial'
    WHEN 'fabrica'            THEN 'fabrica'
    WHEN 'logistica'          THEN 'almacen_logistica'
    WHEN 'finanzas'           THEN 'administracion'
    WHEN 'admin_financiero'   THEN 'administracion'
    ELSE 'comercial'
  END::public.user_area,
  nivel = CASE role::TEXT
    WHEN 'admin'              THEN 'admin'
    WHEN 'director_ventas'    THEN 'admin'
    WHEN 'admin_financiero'   THEN 'admin'
    WHEN 'coordinador_ventas' THEN 'supervisor'
    WHEN 'coordinador'        THEN 'supervisor'
    ELSE 'operador'
  END::public.user_nivel
WHERE nivel IS NULL OR area IS NULL;

ALTER TABLE public.user_roles
  ALTER COLUMN nivel SET DEFAULT 'operador',
  ALTER COLUMN area  SET DEFAULT 'comercial';

ALTER TABLE public.user_roles ALTER COLUMN nivel SET NOT NULL;
ALTER TABLE public.user_roles ALTER COLUMN area  SET NOT NULL;

-- 4. Funciones base ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nivel_rank(_nivel public.user_nivel)
RETURNS INTEGER LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE _nivel WHEN 'operador' THEN 1 WHEN 'supervisor' THEN 2 WHEN 'admin' THEN 3 END
$$;

-- Rol legacy equivalente a un par (área, nivel).
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
    WHEN _area = 'direccion'         AND _nivel = 'admin'      THEN 'admin'
    WHEN _area = 'direccion'                                   THEN 'coordinador'
    ELSE 'ventas'
  END)::public.app_role
$$;

-- 5. Un solo tipo de usuario por persona ------------------------------------
DELETE FROM public.user_roles ur
WHERE EXISTS (
  SELECT 1 FROM public.user_roles o
  WHERE o.user_id = ur.user_id
    AND (public.nivel_rank(o.nivel) > public.nivel_rank(ur.nivel)
      OR (public.nivel_rank(o.nivel) = public.nivel_rank(ur.nivel) AND o.id < ur.id))
);

CREATE UNIQUE INDEX IF NOT EXISTS user_roles_user_id_unico ON public.user_roles(user_id);

-- 6. Trigger que mantiene el rol legacy sincronizado ------------------------
CREATE OR REPLACE FUNCTION public.sync_rol_legacy()
RETURNS TRIGGER LANGUAGE PLPGSQL SET search_path = public AS $$
BEGIN
  -- Si solo llega el rol legacy (integraciones viejas), se deduce nivel/área.
  IF NEW.area IS NULL OR NEW.nivel IS NULL THEN
    NEW.area := COALESCE(NEW.area, CASE NEW.role::TEXT
      WHEN 'admin' THEN 'direccion'
      WHEN 'fabrica' THEN 'fabrica'
      WHEN 'logistica' THEN 'almacen_logistica'
      WHEN 'finanzas' THEN 'administracion'
      WHEN 'admin_financiero' THEN 'administracion'
      ELSE 'comercial' END::public.user_area);
    NEW.nivel := COALESCE(NEW.nivel, CASE NEW.role::TEXT
      WHEN 'admin' THEN 'admin'
      WHEN 'director_ventas' THEN 'admin'
      WHEN 'admin_financiero' THEN 'admin'
      WHEN 'coordinador_ventas' THEN 'supervisor'
      WHEN 'coordinador' THEN 'supervisor'
      ELSE 'operador' END::public.user_nivel);
  END IF;
  NEW.role := public.rol_legacy(NEW.area, NEW.nivel);
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_user_roles_sync_legacy ON public.user_roles;
CREATE TRIGGER trg_user_roles_sync_legacy
BEFORE INSERT OR UPDATE ON public.user_roles
FOR EACH ROW EXECUTE FUNCTION public.sync_rol_legacy();

-- Normalizar filas existentes con el mapeo canónico.
UPDATE public.user_roles SET role = public.rol_legacy(area, nivel)
WHERE role <> public.rol_legacy(area, nivel);

-- 7. Helpers de permisos (nivel × área) -------------------------------------
CREATE OR REPLACE FUNCTION public.mi_area()
RETURNS public.user_area LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT area FROM public.user_roles WHERE user_id = auth.uid() LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.mi_nivel()
RETURNS public.user_nivel LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT nivel FROM public.user_roles WHERE user_id = auth.uid() LIMIT 1
$$;

-- ¿El usuario pertenece a esta área?
CREATE OR REPLACE FUNCTION public.es_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND area = _area)
$$;

-- ¿El usuario alcanza al menos este tipo de usuario?
CREATE OR REPLACE FUNCTION public.nivel_al_menos(_user_id UUID, _nivel public.user_nivel)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND public.nivel_rank(nivel) >= public.nivel_rank(_nivel)
  )
$$;

-- ¿Es admin de esta área (o admin global de Dirección)?
CREATE OR REPLACE FUNCTION public.es_admin_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND nivel = 'admin' AND (area = _area OR area = 'direccion')
  )
$$;

-- admin de Dirección = administrador global del sistema.
CREATE OR REPLACE FUNCTION public.es_admin_global(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND nivel = 'admin' AND area = 'direccion'
  )
$$;

-- ¿Supervisa o administra esta área?
CREATE OR REPLACE FUNCTION public.supervisa_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id
      AND public.nivel_rank(nivel) >= 2
      AND (area = _area OR (area = 'direccion' AND nivel = 'admin'))
  )
$$;

REVOKE EXECUTE ON FUNCTION public.mi_area() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.mi_nivel() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.es_area(UUID, public.user_area) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.nivel_al_menos(UUID, public.user_nivel) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.es_admin_area(UUID, public.user_area) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.es_admin_global(UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.supervisa_area(UUID, public.user_area) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.mi_area() TO authenticated;
GRANT EXECUTE ON FUNCTION public.mi_nivel() TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_area(UUID, public.user_area) TO authenticated;
GRANT EXECUTE ON FUNCTION public.nivel_al_menos(UUID, public.user_nivel) TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_admin_area(UUID, public.user_area) TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_admin_global(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.supervisa_area(UUID, public.user_area) TO authenticated;

-- 8. Gestión de usuarios: cada admin administra su área ---------------------
DROP POLICY IF EXISTS "admin de area gestiona usuarios" ON public.user_roles;
CREATE POLICY "admin de area gestiona usuarios" ON public.user_roles
FOR ALL TO authenticated
USING (
  public.es_admin_global(auth.uid())
  OR (public.mi_nivel() = 'admin' AND area = public.mi_area())
)
WITH CHECK (
  public.es_admin_global(auth.uid())
  OR (public.mi_nivel() = 'admin' AND area = public.mi_area())
);

DROP POLICY IF EXISTS "admin de area actualiza profiles" ON public.profiles;
CREATE POLICY "admin de area actualiza profiles" ON public.profiles
FOR UPDATE TO authenticated
USING (
  public.es_admin_global(auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = profiles.id
      AND public.mi_nivel() = 'admin'
      AND ur.area = public.mi_area()
  )
);

DROP POLICY IF EXISTS "admin de area inserta profiles" ON public.profiles;
CREATE POLICY "admin de area inserta profiles" ON public.profiles
FOR INSERT TO authenticated
WITH CHECK (public.nivel_al_menos(auth.uid(), 'admin') OR id = auth.uid());

-- 9. Escritura por área y nivel en los módulos operativos -------------------
-- Las políticas históricas (basadas en el rol legacy) se conservan; estas se
-- suman para que el admin/supervisor de cada área tenga el alcance del modelo
-- nuevo sin depender del rol legacy.

-- Clientes: Comercial y Administración supervisan/editan; admin de área borra.
DROP POLICY IF EXISTS "comercial supervisa clientes" ON public.clientes;
CREATE POLICY "comercial supervisa clientes" ON public.clientes
FOR UPDATE TO authenticated
USING (
  public.supervisa_area(auth.uid(), 'comercial')
  OR public.supervisa_area(auth.uid(), 'administracion')
);

DROP POLICY IF EXISTS "comercial crea clientes" ON public.clientes;
CREATE POLICY "comercial crea clientes" ON public.clientes
FOR INSERT TO authenticated
WITH CHECK (
  public.es_area(auth.uid(), 'comercial')
  OR public.es_area(auth.uid(), 'administracion')
  OR public.es_admin_global(auth.uid())
);

DROP POLICY IF EXISTS "admin de area borra clientes" ON public.clientes;
CREATE POLICY "admin de area borra clientes" ON public.clientes
FOR DELETE TO authenticated
USING (
  public.es_admin_area(auth.uid(), 'comercial')
  OR public.es_admin_area(auth.uid(), 'administracion')
);

-- Remisiones: Comercial supervisa todas las de su área; su admin puede borrar.
DROP POLICY IF EXISTS "comercial supervisa remisiones" ON public.remisiones;
CREATE POLICY "comercial supervisa remisiones" ON public.remisiones
FOR UPDATE TO authenticated
USING (public.supervisa_area(auth.uid(), 'comercial'));

DROP POLICY IF EXISTS "comercial lee remisiones" ON public.remisiones;
CREATE POLICY "comercial lee remisiones" ON public.remisiones
FOR SELECT TO authenticated
USING (
  public.supervisa_area(auth.uid(), 'comercial')
  OR public.es_area(auth.uid(), 'direccion')
  OR public.es_area(auth.uid(), 'administracion')
);

DROP POLICY IF EXISTS "admin de area borra remisiones" ON public.remisiones;
CREATE POLICY "admin de area borra remisiones" ON public.remisiones
FOR DELETE TO authenticated
USING (public.es_admin_area(auth.uid(), 'comercial'));

-- Producción: admin de Fábrica / Almacén y Logística puede borrar y corregir.
DROP POLICY IF EXISTS "admin de area borra motocarros" ON public.motocarros;
CREATE POLICY "admin de area borra motocarros" ON public.motocarros
FOR DELETE TO authenticated
USING (
  public.es_admin_area(auth.uid(), 'fabrica')
  OR public.es_admin_area(auth.uid(), 'almacen_logistica')
);

DROP POLICY IF EXISTS "admin de area borra contenedores" ON public.contenedores;
CREATE POLICY "admin de area borra contenedores" ON public.contenedores
FOR DELETE TO authenticated
USING (
  public.es_admin_area(auth.uid(), 'fabrica')
  OR public.es_admin_area(auth.uid(), 'almacen_logistica')
);

-- Dirección y Administración ven la operación completa (solo lectura).
DROP POLICY IF EXISTS "direccion lee motocarros" ON public.motocarros;
CREATE POLICY "direccion lee motocarros" ON public.motocarros
FOR SELECT TO authenticated
USING (
  public.es_area(auth.uid(), 'direccion')
  OR public.es_area(auth.uid(), 'administracion')
);

-- Bitácora: la consulta cualquier admin de área; Dirección la ve completa.
DROP POLICY IF EXISTS "admin de area lee bitacora" ON public.bitacora_eventos;
CREATE POLICY "admin de area lee bitacora" ON public.bitacora_eventos
FOR SELECT TO authenticated
USING (public.nivel_al_menos(auth.uid(), 'admin') OR public.es_area(auth.uid(), 'direccion'));

-- Configuración general: solo el admin global (Dirección).
DROP POLICY IF EXISTS "admin global actualiza config" ON public.config_general;
CREATE POLICY "admin global actualiza config" ON public.config_general
FOR UPDATE TO authenticated
USING (public.es_admin_global(auth.uid()));

COMMENT ON COLUMN public.user_roles.nivel IS 'Tipo de usuario: operador | supervisor | admin';
COMMENT ON COLUMN public.user_roles.area  IS 'Área: comercial | fabrica | almacen_logistica | administracion | direccion';
COMMENT ON COLUMN public.user_roles.role  IS 'DERIVADO de (area, nivel) por trigger. Solo para compatibilidad con RLS histórico.';
