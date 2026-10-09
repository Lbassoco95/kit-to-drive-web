-- =============================================================================
-- Sprint 4: Reportes de turno + Comentarios por motocarro
-- =============================================================================

-- ─────────────────────────────────────────────
-- 1. TABLA: reportes_turno
--    Fábrica reporta diariamente avance de producción
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reportes_turno (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fecha           date NOT NULL DEFAULT current_date,
  turno           text NOT NULL CHECK (turno IN ('manana','tarde','noche')),
  unidades_armadas integer NOT NULL DEFAULT 0 CHECK (unidades_armadas >= 0),
  paros           text,          -- descripción de paros o incidencias
  observaciones   text,          -- observaciones generales del turno
  usuario_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reportes_turno_fecha ON public.reportes_turno(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_reportes_turno_usuario ON public.reportes_turno(usuario_id);

ALTER TABLE public.reportes_turno ENABLE ROW LEVEL SECURITY;

-- Fábrica y admin pueden crear
CREATE POLICY "insertar reporte turno"
ON public.reportes_turno FOR INSERT TO authenticated
WITH CHECK (
  public.has_role(auth.uid(), 'admin') OR
  public.has_role(auth.uid(), 'fabrica')
);

-- Lectura: todos los roles operativos
CREATE POLICY "leer reportes turno"
ON public.reportes_turno FOR SELECT TO authenticated
USING (
  public.has_role(auth.uid(), 'admin') OR
  public.has_role(auth.uid(), 'fabrica') OR
  public.has_role(auth.uid(), 'logistica') OR
  public.has_role(auth.uid(), 'ventas') OR
  public.has_role(auth.uid(), 'coordinador')
);

-- Solo el autor o admin puede editar (dentro del mismo día)
CREATE POLICY "actualizar reporte turno"
ON public.reportes_turno FOR UPDATE TO authenticated
USING (
  public.has_role(auth.uid(), 'admin') OR
  (usuario_id = auth.uid() AND fecha = current_date)
);

-- Solo admin puede borrar
CREATE POLICY "borrar reporte turno"
ON public.reportes_turno FOR DELETE TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Trigger updated_at
DROP TRIGGER IF EXISTS trg_reportes_turno_updated ON public.reportes_turno;
CREATE TRIGGER trg_reportes_turno_updated
BEFORE UPDATE ON public.reportes_turno
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Bitácora automática
CREATE OR REPLACE FUNCTION public.log_reporte_turno()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.bitacora_eventos
      (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_despues)
    VALUES (auth.uid(), 'reportes_turno', 'insert', 'reporte_turno', NEW.id, to_jsonb(NEW));
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO public.bitacora_eventos
      (usuario_id, modulo, accion, entidad_tipo, entidad_id, datos_antes, datos_despues)
    VALUES (auth.uid(), 'reportes_turno', 'update', 'reporte_turno', NEW.id, to_jsonb(OLD), to_jsonb(NEW));
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_log_reporte_turno ON public.reportes_turno;
CREATE TRIGGER trg_log_reporte_turno
AFTER INSERT OR UPDATE ON public.reportes_turno
FOR EACH ROW EXECUTE FUNCTION public.log_reporte_turno();


-- ─────────────────────────────────────────────
-- 2. TABLA: comentarios_motocarros
--    Cualquier rol puede comentar en un motocarro
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.comentarios_motocarros (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  motocarro_id uuid NOT NULL REFERENCES public.motocarros(id) ON DELETE CASCADE,
  usuario_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  texto        text NOT NULL CHECK (length(trim(texto)) > 0),
  foto_url     text,            -- URL de Storage si se sube foto
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comentarios_motocarro ON public.comentarios_motocarros(motocarro_id, created_at DESC);

ALTER TABLE public.comentarios_motocarros ENABLE ROW LEVEL SECURITY;

-- Cualquier autenticado que tenga acceso al motocarro puede ver sus comentarios
CREATE POLICY "leer comentarios motocarros"
ON public.comentarios_motocarros FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.motocarros m
    WHERE m.id = comentarios_motocarros.motocarro_id
    -- reusa la misma lógica: si pueden ver el motocarro, ven sus comentarios
    AND (
      public.has_role(auth.uid(), 'admin') OR
      public.has_role(auth.uid(), 'fabrica') OR
      public.has_role(auth.uid(), 'logistica') OR
      public.has_role(auth.uid(), 'coordinador') OR
      (m.remision_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.remisiones r WHERE r.id = m.remision_id AND r.vendedor_id = auth.uid()
      ))
    )
  )
);

-- Cualquier rol operativo puede insertar comentarios
CREATE POLICY "insertar comentario motocarro"
ON public.comentarios_motocarros FOR INSERT TO authenticated
WITH CHECK (
  usuario_id = auth.uid() AND (
    public.has_role(auth.uid(), 'admin') OR
    public.has_role(auth.uid(), 'fabrica') OR
    public.has_role(auth.uid(), 'logistica') OR
    public.has_role(auth.uid(), 'ventas') OR
    public.has_role(auth.uid(), 'coordinador')
  )
);

-- Solo admin puede borrar
CREATE POLICY "borrar comentario motocarro"
ON public.comentarios_motocarros FOR DELETE TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Storage bucket para fotos de comentarios
INSERT INTO storage.buckets (id, name, public)
VALUES ('comentarios-fotos', 'comentarios-fotos', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "subir foto comentario"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'comentarios-fotos');

CREATE POLICY "leer foto comentario"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'comentarios-fotos');

CREATE POLICY "borrar foto comentario admin"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'comentarios-fotos' AND public.has_role(auth.uid(), 'admin'));
