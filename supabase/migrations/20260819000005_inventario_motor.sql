-- Table for motor inventory
CREATE TABLE public.inventario_motor (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero_motor TEXT NOT NULL UNIQUE,
  contenedor_id UUID REFERENCES public.contenedores(id) ON DELETE CASCADE,
  modelo TEXT NOT NULL,
  estatus TEXT NOT NULL DEFAULT 'disponible', -- 'disponible', 'configurado', 'asignado'
  motocarro_id UUID REFERENCES public.motocarros(id) ON DELETE SET NULL,
  fecha_importacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_configuracion TIMESTAMPTZ,
  notas TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.inventario_motor ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "leer inventario motor" ON public.inventario_motor FOR SELECT TO authenticated USING (true);
CREATE POLICY "escribir inventario motor admin/fabrica" ON public.inventario_motor FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "actualizar inventario motor admin/fabrica" ON public.inventario_motor FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "borrar inventario motor admin" ON public.inventario_motor FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- Indexes for performance
CREATE INDEX idx_inventario_motor_contenedor ON public.inventario_motor(contenedor_id);
CREATE INDEX idx_inventario_motor_estatus ON public.inventario_motor(estatus);
CREATE INDEX idx_inventario_motor_modelo ON public.inventario_motor(modelo);

-- updated_at trigger
CREATE TRIGGER trg_inventario_motor_updated BEFORE UPDATE ON public.inventario_motor FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
