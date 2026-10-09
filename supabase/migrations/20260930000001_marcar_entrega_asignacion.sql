-- Permite a quien puede asignar remisiones (fábrica / allowlist) marcar
-- unidad entregada y remisión completa, sin cambiar de área.

CREATE OR REPLACE FUNCTION public.marcar_unidad_entregada(
  _motocarro_id UUID,
  _fecha DATE DEFAULT CURRENT_DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _m RECORD;
  _fecha_entrega DATE := COALESCE(_fecha, CURRENT_DATE);
BEGIN
  IF NOT public.puede_asignar_remisiones(auth.uid()) THEN
    RAISE EXCEPTION 'No tienes permiso para marcar unidades como entregadas';
  END IF;

  SELECT id, remision_id, estatus_armado, estatus_entrega, ns_chasis, ns_motor
    INTO _m
  FROM public.motocarros
  WHERE id = _motocarro_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unidad no encontrada';
  END IF;

  IF _m.remision_id IS NULL THEN
    RAISE EXCEPTION 'La unidad no está asignada a una remisión';
  END IF;

  IF _m.estatus_entrega = 'ENTREGADA' THEN
    RETURN jsonb_build_object('ok', true, 'ya_entregada', true, 'motocarro_id', _m.id);
  END IF;

  IF NULLIF(btrim(COALESCE(_m.ns_chasis, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(_m.ns_motor, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Captura NS chasis y NS motor antes de marcar la entrega';
  END IF;

  UPDATE public.motocarros
  SET estatus_entrega = 'ENTREGADA',
      fecha_real_entrega = _fecha_entrega,
      estatus_armado = CASE
        WHEN estatus_armado IN ('PENDIENTE', 'EN_PROCESO', 'ARMADO') THEN 'LISTO'
        ELSE estatus_armado
      END,
      fecha_real_armado = COALESCE(fecha_real_armado, _fecha_entrega)
  WHERE id = _motocarro_id;

  RETURN jsonb_build_object(
    'ok', true,
    'ya_entregada', false,
    'motocarro_id', _m.id,
    'fecha_real_entrega', _fecha_entrega
  );
END;
$$;

REVOKE ALL ON FUNCTION public.marcar_unidad_entregada(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_unidad_entregada(UUID, DATE) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.marcar_remision_entregada(_remision_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _r RECORD;
BEGIN
  IF NOT public.puede_asignar_remisiones(auth.uid()) THEN
    RAISE EXCEPTION 'No tienes permiso para marcar remisiones como entregadas';
  END IF;

  SELECT id, folio_remision, estatus
    INTO _r
  FROM public.remisiones
  WHERE id = _remision_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remisión no encontrada';
  END IF;

  IF _r.estatus = 'CANCELADA' THEN
    RAISE EXCEPTION 'No se puede marcar entregada una remisión cancelada';
  END IF;

  IF _r.estatus = 'COMPLETA' THEN
    RETURN jsonb_build_object('ok', true, 'ya_completa', true, 'remision_id', _r.id);
  END IF;

  UPDATE public.remisiones
  SET estatus = 'COMPLETA'
  WHERE id = _remision_id;

  RETURN jsonb_build_object(
    'ok', true,
    'ya_completa', false,
    'remision_id', _r.id,
    'folio_remision', _r.folio_remision
  );
END;
$$;

REVOKE ALL ON FUNCTION public.marcar_remision_entregada(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_remision_entregada(UUID) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
