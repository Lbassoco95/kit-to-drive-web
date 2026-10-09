-- Fix: asignar_chasis_remision ahora filtra también por modelo
-- El bug era que se asignaba cualquier motocarro disponible sin importar modelo,
-- resultando en, por ejemplo, un 300cc asignado a una remisión de 200cc.

CREATE OR REPLACE FUNCTION public.asignar_chasis_remision(
  _remision_id uuid,
  _cantidad integer,
  _color text DEFAULT NULL,
  _modelo text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  asignados integer := 0;
BEGIN
  -- Solo admin o vendedor dueño de la remisión
  IF NOT (
    public.has_role(auth.uid(), 'admin') OR
    EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = _remision_id AND r.vendedor_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'No autorizado para asignar chasis a esta remisión';
  END IF;

  WITH candidatos AS (
    SELECT id FROM public.motocarros
    WHERE remision_id IS NULL
      AND estatus_armado IN ('PENDIENTE','EN_PROCESO','ARMADO','LISTO')
      AND (_color  IS NULL OR upper(color)  = upper(_color))
      AND (_modelo IS NULL OR upper(modelo) = upper(_modelo))
    ORDER BY orden_armado ASC
    LIMIT _cantidad
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.motocarros m
  SET remision_id = _remision_id,
      estatus_entrega = CASE
        WHEN m.estatus_entrega = 'NO_APLICA' THEN 'PROGRAMADA'
        ELSE m.estatus_entrega
      END
  FROM candidatos c
  WHERE m.id = c.id;

  GET DIAGNOSTICS asignados = ROW_COUNT;

  -- Recalcular estatus de la remisión
  UPDATE public.remisiones r
  SET estatus = CASE
    WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) >= r.total_unidades_solicitadas
      THEN 'COMPLETA'::estatus_remision
    WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) > 0
      THEN 'PARCIAL'::estatus_remision
    ELSE 'NUEVA'::estatus_remision
  END
  WHERE r.id = _remision_id;

  RETURN asignados;
END;
$$;

-- La firma va explícita: si en la base conviven dos versiones de
-- asignar_chasis_remision, el GRANT sin argumentos falla con «function name
-- is not unique» y tumba el archivo completo (el SQL editor va en una sola
-- transacción).
GRANT EXECUTE ON FUNCTION public.asignar_chasis_remision(uuid, integer, text, text) TO authenticated;
