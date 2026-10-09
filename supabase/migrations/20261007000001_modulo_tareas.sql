-- ============================================================================
-- Módulo de tareas / asignaciones
-- Fecha: 2026-10-07
--
-- Todos los usuarios tienen sus tareas. Quién crea y a quién:
--   · operador   — crea tareas para sí mismo.
--   · supervisor — crea y asigna a cualquiera de su área.
--   · admin      — igual, y además VE todas las tareas de su área.
--   · Dirección (admin global) — asigna a cualquiera y ve todo.
--
-- Quién ve qué: la persona asignada, quien la creó, y el admin del área de la
-- persona asignada (`area` se congela con el área del asignado al crear).
-- La persona asignada sólo puede mover estatus / nota de avance; el contenido
-- (título, fecha, asignado…) lo cambia quien la creó o el admin del área.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regclass('public.user_roles') IS NULL OR to_regclass('public.profiles') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Faltan user_roles / profiles.';
  END IF;
  IF to_regtype('public.user_area') IS NULL OR to_regtype('public.user_nivel') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Faltan tipos user_area / user_nivel (20260823000005).';
  END IF;
END $preflight$;

CREATE TABLE IF NOT EXISTS public.tareas (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  titulo        TEXT NOT NULL CHECK (length(btrim(titulo)) > 0),
  descripcion   TEXT,
  prioridad     TEXT NOT NULL DEFAULT 'media' CHECK (prioridad IN ('baja','media','alta')),
  estatus       TEXT NOT NULL DEFAULT 'pendiente'
                  CHECK (estatus IN ('pendiente','en_proceso','completada','cancelada')),
  fecha_limite  DATE,
  -- Área de la persona asignada (la fija el trigger; no se confía en el cliente).
  area          public.user_area NOT NULL,
  asignado_a    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  creado_por    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre_asignado TEXT,
  nombre_creador  TEXT,
  nota_avance   TEXT,
  completada_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tareas_asignado ON public.tareas (asignado_a, estatus);
CREATE INDEX IF NOT EXISTS idx_tareas_creador  ON public.tareas (creado_por);
CREATE INDEX IF NOT EXISTS idx_tareas_area     ON public.tareas (area, estatus);

ALTER TABLE public.tareas ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tareas TO authenticated;

/** Área y nivel del usuario (el nivel más alto si tiene varias filas). */
CREATE OR REPLACE FUNCTION public.area_nivel_de(_user_id uuid DEFAULT auth.uid())
RETURNS TABLE (area public.user_area, nivel public.user_nivel)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT ur.area, ur.nivel
    FROM public.user_roles ur
    LEFT JOIN public.profiles p ON p.id = ur.user_id
   WHERE ur.user_id = _user_id AND COALESCE(p.activo, true)
   ORDER BY public.nivel_rank(ur.nivel) DESC
   LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION public.area_nivel_de(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.area_nivel_de(uuid) TO authenticated;

/** ¿Es admin de esa área (o admin global de Dirección)? */
CREATE OR REPLACE FUNCTION public.es_admin_de_area(_area public.user_area, _user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT a.nivel = 'admin' AND (a.area = _area OR a.area = 'direccion')
      FROM public.area_nivel_de(_user_id) a
  ), false);
$$;
REVOKE EXECUTE ON FUNCTION public.es_admin_de_area(public.user_area, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.es_admin_de_area(public.user_area, uuid) TO authenticated;

/** Personas a las que el usuario puede asignarle tareas (él mismo siempre). */
CREATE OR REPLACE FUNCTION public.usuarios_asignables()
RETURNS TABLE (id uuid, nombre text, area public.user_area, nivel public.user_nivel)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH yo AS (SELECT * FROM public.area_nivel_de(auth.uid()))
  SELECT p.id, COALESCE(NULLIF(p.nombre_completo,''), p.id::text), ur.area, ur.nivel
    FROM public.profiles p
    JOIN public.user_roles ur ON ur.user_id = p.id
    CROSS JOIN yo
   WHERE COALESCE(p.activo, true)
     AND (
       p.id = auth.uid()
       OR (yo.nivel IN ('supervisor','admin') AND (ur.area = yo.area OR yo.area = 'direccion'))
     )
   ORDER BY 2;
$$;
REVOKE EXECUTE ON FUNCTION public.usuarios_asignables() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.usuarios_asignables() TO authenticated;

-- Ver: asignado, creador o admin del área.
DROP POLICY IF EXISTS "ver tareas" ON public.tareas;
CREATE POLICY "ver tareas" ON public.tareas FOR SELECT TO authenticated
  USING (asignado_a = auth.uid() OR creado_por = auth.uid() OR public.es_admin_de_area(area));

-- Crear: firmando con su id. Asignarle a otro exige ser supervisor/admin de esa área.
DROP POLICY IF EXISTS "crear tareas" ON public.tareas;
CREATE POLICY "crear tareas" ON public.tareas FOR INSERT TO authenticated
  WITH CHECK (
    creado_por = auth.uid()
    AND (
      asignado_a = auth.uid()
      OR EXISTS (
        SELECT 1 FROM public.area_nivel_de(auth.uid()) y
         WHERE y.nivel IN ('supervisor','admin')
           AND (y.area = 'direccion' OR y.area = tareas.area)
      )
    )
  );

-- Actualizar: asignado, creador o admin (el trigger limita qué puede tocar cada uno).
DROP POLICY IF EXISTS "actualizar tareas" ON public.tareas;
CREATE POLICY "actualizar tareas" ON public.tareas FOR UPDATE TO authenticated
  USING (asignado_a = auth.uid() OR creado_por = auth.uid() OR public.es_admin_de_area(area))
  WITH CHECK (asignado_a = auth.uid() OR creado_por = auth.uid() OR public.es_admin_de_area(area));

-- Borrar: quien la creó o el admin del área.
DROP POLICY IF EXISTS "borrar tareas" ON public.tareas;
CREATE POLICY "borrar tareas" ON public.tareas FOR DELETE TO authenticated
  USING (creado_por = auth.uid() OR public.es_admin_de_area(area));

/**
 * Antes de guardar:
 *  · INSERT — fija el área y nombres a partir del asignado/creador, y el
 *    creador no puede ser otro.
 *  · UPDATE — si quien edita es sólo el asignado (ni creador ni admin del
 *    área), únicamente puede cambiar estatus y nota de avance.
 *  · Mantiene completada_at y updated_at.
 */
CREATE OR REPLACE FUNCTION public.trg_tareas_guardia()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE _area public.user_area;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT ur.area INTO _area FROM public.user_roles ur
     WHERE ur.user_id = NEW.asignado_a
     ORDER BY public.nivel_rank(ur.nivel) DESC LIMIT 1;
    IF _area IS NULL THEN
      RAISE EXCEPTION 'La persona asignada no tiene área.';
    END IF;
    NEW.area := _area;
    NEW.nombre_asignado := (SELECT nombre_completo FROM public.profiles WHERE id = NEW.asignado_a);
    NEW.nombre_creador  := (SELECT nombre_completo FROM public.profiles WHERE id = NEW.creado_por);
  ELSE
    IF auth.uid() IS NOT NULL
       AND NEW.creado_por IS NOT DISTINCT FROM OLD.creado_por
       AND OLD.creado_por <> auth.uid()
       AND NOT public.es_admin_de_area(OLD.area, auth.uid()) THEN
      -- Sólo el asignado: contenido congelado.
      NEW.titulo := OLD.titulo; NEW.descripcion := OLD.descripcion;
      NEW.prioridad := OLD.prioridad; NEW.fecha_limite := OLD.fecha_limite;
      NEW.asignado_a := OLD.asignado_a;
    END IF;
    NEW.creado_por := OLD.creado_por;
    NEW.created_at := OLD.created_at;
    IF NEW.asignado_a <> OLD.asignado_a THEN
      SELECT ur.area INTO _area FROM public.user_roles ur
       WHERE ur.user_id = NEW.asignado_a
       ORDER BY public.nivel_rank(ur.nivel) DESC LIMIT 1;
      IF _area IS NULL THEN RAISE EXCEPTION 'La persona asignada no tiene área.'; END IF;
      NEW.area := _area;
      NEW.nombre_asignado := (SELECT nombre_completo FROM public.profiles WHERE id = NEW.asignado_a);
    ELSE
      NEW.area := OLD.area;
    END IF;
    NEW.updated_at := now();
  END IF;

  IF NEW.estatus = 'completada' THEN
    NEW.completada_at := COALESCE(NEW.completada_at, now());
  ELSE
    NEW.completada_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tareas_guardia ON public.tareas;
CREATE TRIGGER tareas_guardia BEFORE INSERT OR UPDATE ON public.tareas
  FOR EACH ROW EXECUTE FUNCTION public.trg_tareas_guardia();
