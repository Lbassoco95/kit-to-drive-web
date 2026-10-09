-- ============================================================================
-- Atenea: corregir cualquier remisión y cargar remisiones anteriores (físicas)
-- Fecha: 2026-10-01
--
-- Dos permisos individuales nuevos en `remisiones_asignacion_acceso`, apagados
-- por omisión y encendidos sólo para atenea@dazon.demo.com:
--
--  1. `puede_editar_remisiones` — corrige y complementa CUALQUIER remisión de
--     motocarro con el flujo normal de «Editar» (motivo obligatorio en
--     `remisiones_bitacora`), como lo hace un supervisor de Comercial. Se
--     resuelve dentro de `puede_editar_remision()`, así que cubre las mismas
--     políticas de `remisiones` y `remision_items` que ya usa la escalera.
--
--  2. `puede_cargar_anteriores` — habilita en «Nueva remisión» el selector
--     «Nueva / Anterior (en físico)» para dar de alta remisiones que ya
--     existían en papel: folio y fecha del documento, a nombre del vendedor
--     original y sin el bloqueo de existencias ni de cartera, porque esas
--     unidades ya salieron. Es temporal: se apaga con el UPDATE de abajo y el
--     selector desaparece.
--
-- La remisión cargada así queda marcada con `remisiones.es_anterior = true`.
--
-- Para retirarlos:
--   UPDATE public.remisiones_asignacion_acceso
--      SET puede_cargar_anteriores = false,      -- sólo el selector
--          puede_editar_remisiones = false,      -- sólo la corrección
--          updated_at = now()
--    WHERE lower(email) = 'atenea@dazon.demo.com';
--
-- Requiere 20260902000001 (puede_editar_remision, puede_capturar_remision,
-- rol_comercial) y 20260929000002 (remisiones_asignacion_acceso).
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.remisiones_asignacion_acceso') IS NULL THEN _faltan := _faltan || 'tabla remisiones_asignacion_acceso (20260929000002)'::text; END IF;
  IF to_regprocedure('public.puede_editar_remision(uuid,uuid)') IS NULL THEN _faltan := _faltan || 'función puede_editar_remision (20260902000001)'::text; END IF;
  IF to_regprocedure('public.puede_capturar_remision(uuid,uuid)') IS NULL THEN _faltan := _faltan || 'función puede_capturar_remision (20260902000001)'::text; END IF;
  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN _faltan := _faltan || 'función rol_comercial (20260902000001)'::text; END IF;
  IF to_regprocedure('public.usuario_activo(uuid)') IS NULL THEN _faltan := _faltan || 'función usuario_activo (20260824000003)'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Permisos en la allowlist ─────────────────────────────────────────────
ALTER TABLE public.remisiones_asignacion_acceso
  ADD COLUMN IF NOT EXISTS puede_editar_remisiones BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS puede_cargar_anteriores BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.remisiones_asignacion_acceso.puede_editar_remisiones IS
  'Corrige y complementa cualquier remisión de motocarro (con motivo en remisiones_bitacora), como supervisor de Comercial.';
COMMENT ON COLUMN public.remisiones_asignacion_acceso.puede_cargar_anteriores IS
  'Temporal: puede dar de alta remisiones anteriores que existen en físico, a nombre de cualquier vendedor de Comercial.';

INSERT INTO public.remisiones_asignacion_acceso
  (user_id, email, activo, puede_editar_remisiones, puede_cargar_anteriores)
SELECT id, email, true, true, true
FROM auth.users
WHERE lower(email) = 'atenea@dazon.demo.com'
ON CONFLICT (user_id) DO UPDATE
SET email = EXCLUDED.email,
    activo = true,
    puede_editar_remisiones = true,
    puede_cargar_anteriores = true,
    updated_at = now();

-- ── 2. Marca de remisión anterior ───────────────────────────────────────────
ALTER TABLE public.remisiones
  ADD COLUMN IF NOT EXISTS es_anterior BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.remisiones.es_anterior IS
  'Remisión que ya existía en papel y se cargó después al sistema («Anterior (en físico)»).';

-- ── 3. Funciones de permiso ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.puede_editar_todas_remisiones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT _user_id IS NOT NULL
     AND public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.remisiones_asignacion_acceso a
        WHERE a.user_id = _user_id AND a.activo AND a.puede_editar_remisiones
     );
$$;

CREATE OR REPLACE FUNCTION public.puede_cargar_remisiones_anteriores(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT _user_id IS NOT NULL
     AND public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.remisiones_asignacion_acceso a
        WHERE a.user_id = _user_id AND a.activo AND a.puede_cargar_anteriores
     );
$$;

COMMENT ON FUNCTION public.puede_editar_todas_remisiones(uuid) IS
  'Allowlist individual: corrige cualquier remisión (remisiones_asignacion_acceso.puede_editar_remisiones).';
COMMENT ON FUNCTION public.puede_cargar_remisiones_anteriores(uuid) IS
  'Allowlist individual y temporal: carga remisiones anteriores en físico (remisiones_asignacion_acceso.puede_cargar_anteriores).';

-- Misma escalera de 20260902000001, más la allowlist:
--   · puede_editar_remisiones → cualquier remisión;
--   · puede_cargar_anteriores → las remisiones anteriores (para poder escribir
--     los renglones de la que acaba de cargar a nombre de otro vendedor).
CREATE OR REPLACE FUNCTION public.puede_editar_remision(
  _remision_id uuid,
  _user_id     uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _rol text;
BEGIN
  IF _remision_id IS NULL THEN RETURN false; END IF;
  _rol := public.rol_comercial(_user_id);
  IF _rol IN ('global','supervisor') THEN RETURN true; END IF;
  IF public.puede_editar_todas_remisiones(_user_id) THEN RETURN true; END IF;
  IF public.puede_cargar_remisiones_anteriores(_user_id) AND EXISTS (
       SELECT 1 FROM public.remisiones r
        WHERE r.id = _remision_id AND r.es_anterior
     ) THEN
    RETURN true;
  END IF;
  IF _rol <> 'operador' THEN RETURN false; END IF;
  -- El operador, sólo lo que él capturó.
  RETURN EXISTS (
    SELECT 1 FROM public.remisiones r
     WHERE r.id = _remision_id AND r.vendedor_id = _user_id
  );
END;
$$;

-- Captura a nombre de otro vendedor: supervisor para arriba, o quien carga
-- anteriores (la remisión en papel es de quien la vendió).
CREATE OR REPLACE FUNCTION public.puede_capturar_remision(
  _vendedor_id uuid,
  _user_id     uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE public.rol_comercial(_user_id)
           WHEN 'global'     THEN true
           WHEN 'supervisor' THEN true
           WHEN 'operador'   THEN _vendedor_id = _user_id
                                  OR public.puede_cargar_remisiones_anteriores(_user_id)
           ELSE false
         END;
$$;

COMMENT ON FUNCTION public.puede_editar_remision(uuid, uuid) IS
  'Quién puede corregir o complementar una remisión: administrador global y supervisor/administrador de Comercial, todas; allowlist puede_editar_remisiones, todas; allowlist puede_cargar_anteriores, las marcadas es_anterior; el operador, las que capturó.';
COMMENT ON FUNCTION public.puede_capturar_remision(uuid, uuid) IS
  'Quién puede capturar una remisión a nombre de un vendedor: supervisor para arriba, o el operador con puede_cargar_anteriores; el resto de operadores, sólo al suyo.';

REVOKE ALL ON FUNCTION public.puede_editar_todas_remisiones(uuid)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_cargar_remisiones_anteriores(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_editar_remision(uuid, uuid)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_capturar_remision(uuid, uuid)      FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_editar_todas_remisiones(uuid)      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.puede_cargar_remisiones_anteriores(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.puede_editar_remision(uuid, uuid)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.puede_capturar_remision(uuid, uuid)      TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ── Verificación ────────────────────────────────────────────────────────────
SELECT email, activo, puede_editar_remisiones, puede_cargar_anteriores
  FROM public.remisiones_asignacion_acceso
 WHERE lower(email) = 'atenea@dazon.demo.com';
