-- Re-ejecutable: el SQL editor manda el archivo completo en UNA transacción,
-- así que una sentencia que falla por «already exists» revierte todo el resto.
-- Correrlo dos veces tiene que ser inocuo.

-- Parts inventory for containers
CREATE TABLE IF NOT EXISTS public.contenedor_partes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contenedor_id UUID NOT NULL REFERENCES public.contenedores(id) ON DELETE CASCADE,
  descripcion TEXT NOT NULL, -- English name from DESCRIPTIONS column
  modelo TEXT,
  cantidad_esperada INTEGER NOT NULL DEFAULT 0,
  cantidad_recibida INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.contenedor_partes ENABLE ROW LEVEL SECURITY;

-- RLS policies for contenedor_partes
DROP POLICY IF EXISTS "leer partes contenedor" ON public.contenedor_partes;
CREATE POLICY "leer partes contenedor" ON public.contenedor_partes FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "escribir partes contenedor admin/fabrica" ON public.contenedor_partes;
CREATE POLICY "escribir partes contenedor admin/fabrica" ON public.contenedor_partes FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
DROP POLICY IF EXISTS "actualizar partes contenedor admin/fabrica" ON public.contenedor_partes;
CREATE POLICY "actualizar partes contenedor admin/fabrica" ON public.contenedor_partes FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
DROP POLICY IF EXISTS "borrar partes contenedor admin" ON public.contenedor_partes;
CREATE POLICY "borrar partes contenedor admin" ON public.contenedor_partes FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- updated_at trigger
DROP TRIGGER IF EXISTS trg_contenedor_partes_updated ON public.contenedor_partes;
CREATE TRIGGER trg_contenedor_partes_updated BEFORE UPDATE ON public.contenedor_partes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Index for performance
CREATE INDEX IF NOT EXISTS idx_contenedor_partes_contenedor ON public.contenedor_partes(contenedor_id);
