
-- 1) Storage bucket para documentos de remisiones (PDFs)
INSERT INTO storage.buckets (id, name, public)
VALUES ('remisiones-docs', 'remisiones-docs', false)
ON CONFLICT (id) DO NOTHING;

-- Policies storage: lectura para roles operativos y vendedor dueño
CREATE POLICY "leer docs remisiones operativos"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'remisiones-docs' AND (
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'fabrica') OR
    public.has_role(auth.uid(), 'logistica') OR
    public.has_role(auth.uid(), 'ventas')
  )
);

CREATE POLICY "subir docs remisiones admin/ventas"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'remisiones-docs' AND (
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'ventas')
  )
);

CREATE POLICY "actualizar docs remisiones admin"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'remisiones-docs' AND public.has_role(auth.uid(), 'admin'));

CREATE POLICY "borrar docs remisiones admin"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'remisiones-docs' AND public.has_role(auth.uid(), 'admin'));

-- 2) Función RPC: asignar chasis automáticamente a una remisión
-- Toma N motocarros PENDIENTES sin remisión asignada (orden_armado ASC), opcional filtra por color
CREATE OR REPLACE FUNCTION public.asignar_chasis_remision(
  _remision_id uuid,
  _cantidad integer,
  _color text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  asignados integer := 0;
BEGIN
  -- Solo admin o ventas dueño de la remisión
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
      AND (_color IS NULL OR color = upper(_color))
    ORDER BY orden_armado ASC
    LIMIT _cantidad
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.motocarros m
  SET remision_id = _remision_id,
      estatus_entrega = CASE WHEN m.estatus_entrega = 'NO_APLICA' THEN 'PROGRAMADA' ELSE m.estatus_entrega END
  FROM candidatos c
  WHERE m.id = c.id;

  GET DIAGNOSTICS asignados = ROW_COUNT;

  -- Actualizar estatus de la remisión
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

GRANT EXECUTE ON FUNCTION public.asignar_chasis_remision TO authenticated;

-- 3) Trigger de bitácora automática para motocarros
CREATE OR REPLACE FUNCTION public.log_motocarros_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.estatus_armado IS DISTINCT FROM OLD.estatus_armado
       OR NEW.estatus_entrega IS DISTINCT FROM OLD.estatus_entrega
       OR NEW.remision_id IS DISTINCT FROM OLD.remision_id
       OR NEW.chasis_asignado IS DISTINCT FROM OLD.chasis_asignado THEN
      INSERT INTO public.bitacora_eventos (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_antes, datos_despues)
      VALUES (auth.uid(), 'motocarros', 'update', 'motocarro', NEW.id,
        jsonb_build_object(
          'estatus_armado', OLD.estatus_armado, 'estatus_entrega', OLD.estatus_entrega,
          'remision_id', OLD.remision_id, 'chasis_asignado', OLD.chasis_asignado
        ),
        jsonb_build_object(
          'estatus_armado', NEW.estatus_armado, 'estatus_entrega', NEW.estatus_entrega,
          'remision_id', NEW.remision_id, 'chasis_asignado', NEW.chasis_asignado
        ));
    END IF;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO public.bitacora_eventos (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_despues)
    VALUES (auth.uid(), 'motocarros', 'insert', 'motocarro', NEW.id, to_jsonb(NEW));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_motocarros ON public.motocarros;
CREATE TRIGGER trg_log_motocarros
AFTER INSERT OR UPDATE ON public.motocarros
FOR EACH ROW EXECUTE FUNCTION public.log_motocarros_changes();

-- Trigger de bitácora para remisiones
CREATE OR REPLACE FUNCTION public.log_remisiones_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.bitacora_eventos (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_despues)
    VALUES (auth.uid(), 'remisiones', 'insert', 'remision', NEW.id, to_jsonb(NEW));
  ELSIF TG_OP = 'UPDATE' AND NEW.estatus IS DISTINCT FROM OLD.estatus THEN
    INSERT INTO public.bitacora_eventos (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_antes, datos_despues)
    VALUES (auth.uid(), 'remisiones', 'update', 'remision', NEW.id,
      jsonb_build_object('estatus', OLD.estatus),
      jsonb_build_object('estatus', NEW.estatus));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_remisiones ON public.remisiones;
CREATE TRIGGER trg_log_remisiones
AFTER INSERT OR UPDATE ON public.remisiones
FOR EACH ROW EXECUTE FUNCTION public.log_remisiones_changes();

-- 4) Triggers updated_at en tablas que lo necesitan
DROP TRIGGER IF EXISTS trg_motocarros_updated ON public.motocarros;
CREATE TRIGGER trg_motocarros_updated BEFORE UPDATE ON public.motocarros
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_remisiones_updated ON public.remisiones;
CREATE TRIGGER trg_remisiones_updated BEFORE UPDATE ON public.remisiones
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_clientes_updated ON public.clientes;
CREATE TRIGGER trg_clientes_updated BEFORE UPDATE ON public.clientes
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
