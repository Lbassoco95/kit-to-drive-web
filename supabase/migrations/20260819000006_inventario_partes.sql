-- Table for parts inventory from packing lists
CREATE TABLE public.inventario_partes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contenedor_id UUID NOT NULL REFERENCES public.contenedores(id) ON DELETE CASCADE,
  modelo TEXT,
  descripcion TEXT NOT NULL, -- English name from DESCRIPTIONS column
  cantidad_esperada INTEGER NOT NULL DEFAULT 0,
  cantidad_recibida INTEGER NOT NULL DEFAULT 0,
  fecha_importacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  notas TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.inventario_partes ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "leer inventario partes" ON public.inventario_partes FOR SELECT TO authenticated USING (true);
CREATE POLICY "escribir inventario partes admin/fabrica" ON public.inventario_partes FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "actualizar inventario partes admin/fabrica" ON public.inventario_partes FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "borrar inventario partes admin" ON public.inventario_partes FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- Indexes for performance
CREATE INDEX idx_inventario_partes_contenedor ON public.inventario_partes(contenedor_id);
CREATE INDEX idx_inventario_partes_modelo ON public.inventario_partes(modelo);

-- updated_at trigger
CREATE TRIGGER trg_inventario_partes_updated BEFORE UPDATE ON public.inventario_partes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
