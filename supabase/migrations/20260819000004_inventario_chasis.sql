-- Table for chassis inventory from VIN files
CREATE TABLE public.inventario_chasis (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero_chasis TEXT NOT NULL UNIQUE,
  contenedor_id UUID REFERENCES public.contenedores(id) ON DELETE CASCADE,
  modelo TEXT NOT NULL,
  color TEXT NOT NULL,
  estatus TEXT NOT NULL DEFAULT 'disponible', -- 'disponible', 'configurado', 'asignado'
  motocarro_id UUID REFERENCES public.motocarros(id) ON DELETE SET NULL,
  fecha_importacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_configuracion TIMESTAMPTZ,
  notas TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.inventario_chasis ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "leer inventario chasis" ON public.inventario_chasis FOR SELECT TO authenticated USING (true);
CREATE POLICY "escribir inventario chasis admin/fabrica" ON public.inventario_chasis FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "actualizar inventario chasis admin/fabrica" ON public.inventario_chasis FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "borrar inventario chasis admin" ON public.inventario_chasis FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- Indexes for performance
CREATE INDEX idx_inventario_chasis_contenedor ON public.inventario_chasis(contenedor_id);
CREATE INDEX idx_inventario_chasis_estatus ON public.inventario_chasis(estatus);
CREATE INDEX idx_inventario_chasis_modelo_color ON public.inventario_chasis(modelo, color);

-- updated_at trigger
CREATE TRIGGER trg_inventario_chasis_updated BEFORE UPDATE ON public.inventario_chasis FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
