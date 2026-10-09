-- ============================================================================
-- Asignación manual de motocarros a remisiones
-- Baseline documental para el SQL editor de Supabase (dmhzhyeivvuliumcgsmm).
-- Fecha: 2026-08-26
--
-- ADVERTENCIA: Este proyecto no usa supabase db push / db reset / migration up.
-- Aplicar directamente en el SQL editor de Supabase.
--
-- Cambios:
--  1. Elimina el trigger de asignación automática FIFO al crear una remisión.
--  2. Crea asignar_motocarro_a_remision(): asigna una unidad específica a una
--     remisión. Solo admin o fábrica.
--  3. Crea desasignar_motocarro_de_remision(): libera una unidad de su remisión
--     (incluso si ya está armada o lista, pero no entregada). Solo admin o fábrica.
-- ============================================================================

-- 1. Eliminar asignación automática al insertar remisiones.
DROP TRIGGER IF EXISTS trg_auto_asignar_motocarros ON public.remisiones;

-- 2. Asignar una unidad específica a una remisión.
CREATE OR REPLACE FUNCTION public.asignar_motocarro_a_remision(
  _motocarro_id uuid,
  _remision_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _m public.motocarros%ROWTYPE;
  _r public.remisiones%ROWTYPE;
BEGIN
  IF NOT (
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'fabrica')
  ) THEN
    RAISE EXCEPTION 'Solo admin o fábrica puede asignar unidades';
  END IF;

  SELECT * INTO _m FROM public.motocarros WHERE id = _motocarro_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Motocarro no encontrado'; END IF;
  IF _m.remision_id IS NOT NULL THEN
    RAISE EXCEPTION 'El motocarro % ya está asignado a otra remisión', _m.orden_armado;
  END IF;
  IF _m.estatus_armado NOT IN ('PENDIENTE','EN_PROCESO','ARMADO','LISTO') THEN
    RAISE EXCEPTION 'La unidad no está disponible para asignación';
  END IF;

  SELECT * INTO _r FROM public.remisiones WHERE id = _remision_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Remisión no encontrada'; END IF;

  UPDATE public.motocarros
     SET remision_id = _remision_id,
         estatus_entrega = CASE WHEN estatus_entrega = 'NO_APLICA' THEN 'PROGRAMADA' ELSE estatus_entrega END
   WHERE id = _motocarro_id;

  UPDATE public.remisiones
     SET estatus = CASE
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = _r.id) >= _r.total_unidades_solicitadas
         THEN 'COMPLETA'::estatus_remision
       ELSE 'PARCIAL'::estatus_remision
     END
   WHERE id = _remision_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.asignar_motocarro_a_remision(uuid, uuid) TO authenticated;

-- 3. Desasignar una unidad de su remisión (incluso si ya está armada o lista).
CREATE OR REPLACE FUNCTION public.desasignar_motocarro_de_remision(
  _motocarro_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _m public.motocarros%ROWTYPE;
  _remision_id uuid;
BEGIN
  IF NOT (
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'fabrica')
  ) THEN
    RAISE EXCEPTION 'Solo admin o fábrica puede desasignar unidades';
  END IF;

  SELECT * INTO _m FROM public.motocarros WHERE id = _motocarro_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Motocarro no encontrado'; END IF;
  IF _m.remision_id IS NULL THEN
    RAISE EXCEPTION 'El motocarro no está asignado a ninguna remisión';
  END IF;
  IF _m.estatus_entrega = 'ENTREGADA' THEN
    RAISE EXCEPTION 'No se puede desasignar una unidad ya entregada';
  END IF;

  _remision_id := _m.remision_id;

  UPDATE public.motocarros
     SET remision_id = NULL,
         estatus_entrega = 'NO_APLICA'
   WHERE id = _motocarro_id;

  UPDATE public.remisiones
     SET estatus = CASE
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = _remision_id) = 0
         THEN 'NUEVA'::estatus_remision
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = _remision_id) >= total_unidades_solicitadas
         THEN 'COMPLETA'::estatus_remision
       ELSE 'PARCIAL'::estatus_remision
     END
   WHERE id = _remision_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.desasignar_motocarro_de_remision(uuid) TO authenticated;
