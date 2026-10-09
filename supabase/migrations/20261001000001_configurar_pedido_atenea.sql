-- ============================================================================
-- Configurar el pedido desde la bandeja de asignación (sólo Atenea)
-- Fecha: 2026-10-01
--
-- «Guardar configuración» en la bandeja de remisiones borra y vuelve a escribir
-- los renglones de `remision_items`. Esa tabla sigue la escalera de Comercial
-- (`puede_editar_remision`): el operador sólo toca las remisiones que capturó.
-- La allowlist de asignación (20260929000002) no la cubre, así que Atenea
-- recibía «new row violates row-level security policy for table
-- "remision_items"» al configurar remisiones de otro vendedor.
--
-- Qué queda
-- ---------
--  1. `remisiones_asignacion_acceso.puede_configurar_pedido`: permiso aparte,
--     apagado por omisión. Se enciende sólo para atenea@dazon.demo.com; el
--     resto de la allowlist (si se agrega a alguien) sigue sólo asignando.
--  2. `puede_configurar_pedido(remision, usuario)`: la escalera de Comercial
--     (`puede_editar_remision`) o ese permiso encendido.
--  3. `configurar_pedido_remision(remision, items)`: reemplaza los renglones y
--     el total solicitado en una sola transacción y deja constancia en
--     `remisiones_bitacora`. No se abren políticas nuevas de RLS sobre
--     `remision_items` ni `remisiones`: el permiso extra sólo sirve a través
--     de esta función, que sólo toca la configuración del pedido.
--
-- Para retirarlo:
--   UPDATE public.remisiones_asignacion_acceso
--      SET puede_configurar_pedido = false, updated_at = now()
--    WHERE lower(email) = 'atenea@dazon.demo.com';
--
-- Requiere 20260902000001 (puede_editar_remision, remisiones_bitacora) y
-- 20260929000002 (remisiones_asignacion_acceso).
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regclass('public.remisiones_asignacion_acceso') IS NULL THEN _faltan := _faltan || 'tabla remisiones_asignacion_acceso (20260929000002)'::text; END IF;
  IF to_regclass('public.remisiones_bitacora') IS NULL THEN _faltan := _faltan || 'tabla remisiones_bitacora (20260902000001)'::text; END IF;
  IF to_regprocedure('public.puede_editar_remision(uuid,uuid)') IS NULL THEN _faltan := _faltan || 'función puede_editar_remision (20260902000001)'::text; END IF;
  IF to_regprocedure('public.usuario_activo(uuid)') IS NULL THEN _faltan := _faltan || 'función usuario_activo (20260824000003)'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. Permiso aparte en la allowlist ───────────────────────────────────────
ALTER TABLE public.remisiones_asignacion_acceso
  ADD COLUMN IF NOT EXISTS puede_configurar_pedido BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.remisiones_asignacion_acceso.puede_configurar_pedido IS
  'Además de asignar, puede cambiar la configuración del pedido (modelo, color, cantidad y servicios) de cualquier remisión. Sólo vía configurar_pedido_remision().';

INSERT INTO public.remisiones_asignacion_acceso (user_id, email, activo, puede_configurar_pedido)
SELECT id, email, true, true
FROM auth.users
WHERE lower(email) = 'atenea@dazon.demo.com'
ON CONFLICT (user_id) DO UPDATE
SET email = EXCLUDED.email, activo = true, puede_configurar_pedido = true, updated_at = now();

-- ── 2. ¿Puede configurar el pedido de ESTA remisión? ────────────────────────
CREATE OR REPLACE FUNCTION public.puede_configurar_pedido(
  _remision_id UUID,
  _user_id     UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT _remision_id IS NOT NULL AND _user_id IS NOT NULL AND (
    public.puede_editar_remision(_remision_id, _user_id)
    OR (
      public.usuario_activo(_user_id)
      AND EXISTS (
        SELECT 1
        FROM public.remisiones_asignacion_acceso a
        WHERE a.user_id = _user_id AND a.activo AND a.puede_configurar_pedido
      )
    )
  );
$$;

REVOKE ALL ON FUNCTION public.puede_configurar_pedido(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_configurar_pedido(UUID, UUID) TO authenticated, service_role;

-- ── 3. Reemplazar la configuración del pedido ───────────────────────────────
CREATE OR REPLACE FUNCTION public.configurar_pedido_remision(
  _remision_id UUID,
  _items       JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid    UUID := auth.uid();
  _r      RECORD;
  _antes  JSONB;
  _total  INTEGER;
  _nombre TEXT;
BEGIN
  IF NOT public.puede_configurar_pedido(_remision_id, _uid) THEN
    RAISE EXCEPTION 'No tienes permiso para configurar el pedido de esta remisión';
  END IF;

  SELECT id, total_unidades_solicitadas INTO _r
  FROM public.remisiones
  WHERE id = _remision_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remisión no encontrada';
  END IF;

  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' THEN
    RAISE EXCEPTION 'La configuración debe ser una lista de renglones';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(_items) e
    WHERE COALESCE(e->>'tipo_servicio', '') NOT IN ('motocarro','cabina','instalacion_cabina','activacion','flete')
       OR COALESCE((e->>'cantidad')::int, 0) < 1
  ) THEN
    RAISE EXCEPTION 'Renglón inválido: tipo de servicio desconocido o cantidad menor a 1';
  END IF;

  SELECT COALESCE(sum((e->>'cantidad')::int), 0) INTO _total
  FROM jsonb_array_elements(_items) e
  WHERE e->>'tipo_servicio' = 'motocarro';

  IF _total < 1 THEN
    RAISE EXCEPTION 'La configuración necesita al menos un motocarro';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'tipo_servicio', ri.tipo_servicio, 'modelo', ri.modelo, 'color', ri.color,
           'cantidad', ri.cantidad, 'con_caja', ri.con_caja) ORDER BY ri.created_at, ri.id), '[]'::jsonb)
    INTO _antes
  FROM public.remision_items ri
  WHERE ri.remision_id = _remision_id;

  DELETE FROM public.remision_items WHERE remision_id = _remision_id;

  INSERT INTO public.remision_items (remision_id, tipo_servicio, modelo, color, cantidad, con_caja)
  SELECT _remision_id,
         e->>'tipo_servicio',
         NULLIF(btrim(e->>'modelo'), ''),
         NULLIF(btrim(e->>'color'), ''),
         (e->>'cantidad')::int,
         COALESCE((e->>'con_caja')::boolean, false)
  FROM jsonb_array_elements(_items) WITH ORDINALITY AS t(e, n)
  ORDER BY n;

  UPDATE public.remisiones
  SET total_unidades_solicitadas = _total
  WHERE id = _remision_id;

  SELECT COALESCE(NULLIF(btrim(p.nombre_completo), ''), u.email) INTO _nombre
  FROM auth.users u
  LEFT JOIN public.profiles p ON p.id = u.id
  WHERE u.id = _uid;

  INSERT INTO public.remisiones_bitacora
    (remision_id, usuario_id, nombre_usuario, tipo_cambio, motivo, datos_antes, datos_despues)
  VALUES (
    _remision_id, _uid, _nombre, 'configuracion',
    'Configuración del pedido desde la bandeja de asignación',
    jsonb_build_object('items', _antes, 'total_unidades_solicitadas', _r.total_unidades_solicitadas),
    jsonb_build_object('items', _items, 'total_unidades_solicitadas', _total)
  );

  RETURN jsonb_build_object('ok', true, 'remision_id', _remision_id, 'total_unidades_solicitadas', _total);
END;
$$;

REVOKE ALL ON FUNCTION public.configurar_pedido_remision(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.configurar_pedido_remision(UUID, JSONB) TO authenticated, service_role;

-- ── Comprobación ────────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.remisiones_asignacion_acceso
    WHERE lower(email) = 'atenea@dazon.demo.com' AND activo AND puede_configurar_pedido
  ) THEN
    RAISE EXCEPTION 'No existe el usuario atenea@dazon.demo.com en Auth; no se otorgó el permiso';
  END IF;
END;
$postflight$;

NOTIFY pgrst, 'reload schema';
