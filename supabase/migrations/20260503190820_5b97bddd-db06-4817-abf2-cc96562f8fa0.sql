-- Función trigger: auto-asignar motocarros FIFO al crear una remisión
CREATE OR REPLACE FUNCTION public.auto_asignar_motocarros_remision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  asignados integer := 0;
  _color text;
BEGIN
  _color := NULLIF(upper(NEW.color_solicitado), '');

  -- Tomar siguientes N motocarros sin remisión, FIFO por orden_armado.
  -- Permite PENDIENTE / EN_PROCESO / ARMADO / LISTO.
  WITH candidatos AS (
    SELECT id FROM public.motocarros
    WHERE remision_id IS NULL
      AND estatus_armado IN ('PENDIENTE','EN_PROCESO','ARMADO','LISTO')
      AND (_color IS NULL OR color = _color)
    ORDER BY orden_armado ASC
    LIMIT NEW.total_unidades_solicitadas
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.motocarros m
  SET remision_id = NEW.id,
      estatus_entrega = CASE WHEN m.estatus_entrega = 'NO_APLICA' THEN 'PROGRAMADA' ELSE m.estatus_entrega END
  FROM candidatos c
  WHERE m.id = c.id;

  GET DIAGNOSTICS asignados = ROW_COUNT;

  -- Actualizar estatus de la remisión recién creada
  UPDATE public.remisiones
  SET estatus = CASE
    WHEN asignados >= NEW.total_unidades_solicitadas THEN 'COMPLETA'::estatus_remision
    WHEN asignados > 0 THEN 'PARCIAL'::estatus_remision
    ELSE 'NUEVA'::estatus_remision
  END
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_asignar_motocarros ON public.remisiones;
CREATE TRIGGER trg_auto_asignar_motocarros
AFTER INSERT ON public.remisiones
FOR EACH ROW
EXECUTE FUNCTION public.auto_asignar_motocarros_remision();

-- Función helper para reintentar asignación manual desde la bandeja
CREATE OR REPLACE FUNCTION public.reintentar_asignar_remision(_remision_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r public.remisiones%ROWTYPE;
  ya_asignados integer;
  faltantes integer;
  asignados integer := 0;
  _color text;
BEGIN
  IF NOT (
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'fabrica') OR
    EXISTS (SELECT 1 FROM public.remisiones rr WHERE rr.id = _remision_id AND rr.vendedor_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO r FROM public.remisiones WHERE id = _remision_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Remisión no encontrada'; END IF;

  SELECT COUNT(*) INTO ya_asignados FROM public.motocarros WHERE remision_id = _remision_id;
  faltantes := r.total_unidades_solicitadas - ya_asignados;
  IF faltantes <= 0 THEN RETURN 0; END IF;

  _color := NULLIF(upper(r.color_solicitado), '');

  WITH candidatos AS (
    SELECT id FROM public.motocarros
    WHERE remision_id IS NULL
      AND estatus_armado IN ('PENDIENTE','EN_PROCESO','ARMADO','LISTO')
      AND (_color IS NULL OR color = _color)
    ORDER BY orden_armado ASC
    LIMIT faltantes
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.motocarros m
  SET remision_id = _remision_id,
      estatus_entrega = CASE WHEN m.estatus_entrega = 'NO_APLICA' THEN 'PROGRAMADA' ELSE m.estatus_entrega END
  FROM candidatos c
  WHERE m.id = c.id;

  GET DIAGNOSTICS asignados = ROW_COUNT;

  UPDATE public.remisiones
  SET estatus = CASE
    WHEN (ya_asignados + asignados) >= r.total_unidades_solicitadas THEN 'COMPLETA'::estatus_remision
    WHEN (ya_asignados + asignados) > 0 THEN 'PARCIAL'::estatus_remision
    ELSE 'NUEVA'::estatus_remision
  END
  WHERE id = _remision_id;

  RETURN asignados;
END;
$$;