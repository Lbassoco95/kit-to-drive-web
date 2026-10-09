-- Cancelar deja la remisión en el apartado de canceladas, con motivo y fecha,
-- para revisarla. No se borra. Idempotente.

ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS motivo_cancelacion TEXT,
  ADD COLUMN IF NOT EXISTS cancelada_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.cancelar_remision_refacciones(_remision_id UUID, _motivo TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
  v_rol text;
  v_item public.remision_refaccion_items%ROWTYPE;
BEGIN
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo (mínimo 3 caracteres)';
  END IF;

  SELECT * INTO v_row
  FROM public.remisiones_refacciones
  WHERE id = _remision_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa = 'cancelada' THEN
    RAISE EXCEPTION 'Esta remisión ya está cancelada';
  END IF;
  IF v_row.etapa = 'entregada' OR v_row.entregada_at IS NOT NULL THEN
    RAISE EXCEPTION 'Una remisión entregada no se cancela; queda en Entregadas';
  END IF;

  v_rol := public.rol_comercial();
  IF NOT (
    v_rol IN ('global', 'supervisor')
    OR (v_rol = 'operador' AND (v_row.vendedor_id = auth.uid() OR v_row.created_by = auth.uid()))
  ) THEN
    RAISE EXCEPTION 'No puedes cancelar esta remisión';
  END IF;

  FOR v_item IN
    SELECT * FROM public.remision_refaccion_items
    WHERE remision_id = _remision_id
      AND cantidad_bloqueada > 0
    FOR UPDATE
  LOOP
    UPDATE public.remision_refaccion_items
    SET cantidad_bloqueada = 0,
        cantidad_faltante = 0,
        estatus = 'cancelada'
    WHERE id = v_item.id;
  END LOOP;

  UPDATE public.remision_refaccion_items
  SET estatus = 'cancelada'
  WHERE remision_id = _remision_id
    AND estatus <> 'surtida';

  UPDATE public.remisiones_refacciones
  SET etapa = 'cancelada',
      area_actual = 'ventas',
      abierta = false,
      motivo_cancelacion = trim(_motivo),
      cancelada_at = now()
  WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, area, accion, detalle, usuario_id
  ) VALUES (
    _remision_id, 'ventas', 'cancelar_remision',
    'Cancelada. Quedó en Canceladas para revisión. ' || trim(_motivo),
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancelar_remision_refacciones(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancelar_remision_refacciones(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
