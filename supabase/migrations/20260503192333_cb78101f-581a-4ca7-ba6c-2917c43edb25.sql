
-- Campos para coordinación de entrega
ALTER TABLE public.motocarros
  ADD COLUMN IF NOT EXISTS fecha_propuesta_entrega date,
  ADD COLUMN IF NOT EXISTS propuesta_entrega_notas text,
  ADD COLUMN IF NOT EXISTS propuesta_entrega_por uuid,
  ADD COLUMN IF NOT EXISTS propuesta_entrega_at timestamptz,
  ADD COLUMN IF NOT EXISTS confirmada_fabrica_at timestamptz,
  ADD COLUMN IF NOT EXISTS confirmada_fabrica_por uuid,
  ADD COLUMN IF NOT EXISTS confirmada_logistica_at timestamptz,
  ADD COLUMN IF NOT EXISTS confirmada_logistica_por uuid;

-- RLS: motocarros - lectura para coordinador
DROP POLICY IF EXISTS "leer motocarros por rol" ON public.motocarros;
CREATE POLICY "leer motocarros por rol" ON public.motocarros
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR (remision_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM remisiones r WHERE r.id = motocarros.remision_id AND r.vendedor_id = auth.uid()))
);

-- RLS: motocarros - update por coordinador, fábrica, logística, admin, o vendedor dueño (solo propuesta)
DROP POLICY IF EXISTS "actualizar motocarros operativos" ON public.motocarros;
CREATE POLICY "actualizar motocarros operativos" ON public.motocarros
FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR (remision_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM remisiones r WHERE r.id = motocarros.remision_id AND r.vendedor_id = auth.uid()))
);

-- RLS: remisiones - lectura coordinador
DROP POLICY IF EXISTS "leer remisiones por rol" ON public.remisiones;
CREATE POLICY "leer remisiones por rol" ON public.remisiones
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR vendedor_id = auth.uid()
);

-- RLS: remisiones - insert coordinador (a nombre de cualquier vendedor)
DROP POLICY IF EXISTS "crear remisiones" ON public.remisiones;
CREATE POLICY "crear remisiones" ON public.remisiones
FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR (has_role(auth.uid(),'ventas'::app_role) AND vendedor_id = auth.uid())
);

-- RLS: remisiones - update coordinador
DROP POLICY IF EXISTS "actualizar remisiones" ON public.remisiones;
CREATE POLICY "actualizar remisiones" ON public.remisiones
FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR vendedor_id = auth.uid()
);

-- RLS: clientes - insert/update coordinador
DROP POLICY IF EXISTS "escribir clientes admin/fabrica/ventas" ON public.clientes;
CREATE POLICY "escribir clientes" ON public.clientes
FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'ventas'::app_role)
);

DROP POLICY IF EXISTS "actualizar clientes admin/fabrica" ON public.clientes;
CREATE POLICY "actualizar clientes" ON public.clientes
FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
);

-- RPC: vendedor/coordinador propone fecha de entrega
CREATE OR REPLACE FUNCTION public.proponer_fecha_entrega(
  _motocarro_id uuid,
  _fecha date,
  _notas text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    has_role(auth.uid(),'admin'::app_role)
    OR has_role(auth.uid(),'coordinador'::app_role)
    OR EXISTS (
      SELECT 1 FROM motocarros m
      JOIN remisiones r ON r.id = m.remision_id
      WHERE m.id = _motocarro_id AND r.vendedor_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'No autorizado para proponer fecha de entrega';
  END IF;

  UPDATE motocarros
  SET fecha_propuesta_entrega = _fecha,
      propuesta_entrega_notas = _notas,
      propuesta_entrega_por = auth.uid(),
      propuesta_entrega_at = now(),
      confirmada_fabrica_at = NULL, confirmada_fabrica_por = NULL,
      confirmada_logistica_at = NULL, confirmada_logistica_por = NULL
  WHERE id = _motocarro_id;
END; $$;

-- RPC: fábrica o logística confirma la fecha (al confirmar logística, pasa a fecha_estimada_entrega + PROGRAMADA)
CREATE OR REPLACE FUNCTION public.confirmar_fecha_entrega(
  _motocarro_id uuid,
  _area text  -- 'fabrica' | 'logistica'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF _area = 'fabrica' THEN
    IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
      RAISE EXCEPTION 'Solo fábrica/admin puede confirmar este lado';
    END IF;
    UPDATE motocarros SET confirmada_fabrica_at = now(), confirmada_fabrica_por = auth.uid()
    WHERE id = _motocarro_id;
  ELSIF _area = 'logistica' THEN
    IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'logistica'::app_role)) THEN
      RAISE EXCEPTION 'Solo logística/admin puede confirmar este lado';
    END IF;
    UPDATE motocarros
    SET confirmada_logistica_at = now(),
        confirmada_logistica_por = auth.uid(),
        fecha_estimada_entrega = COALESCE(fecha_propuesta_entrega, fecha_estimada_entrega),
        estatus_entrega = CASE WHEN estatus_entrega IN ('NO_APLICA','PROGRAMADA') THEN 'PROGRAMADA'::estatus_entrega ELSE estatus_entrega END
    WHERE id = _motocarro_id;
  ELSE
    RAISE EXCEPTION 'Área inválida';
  END IF;
END; $$;
