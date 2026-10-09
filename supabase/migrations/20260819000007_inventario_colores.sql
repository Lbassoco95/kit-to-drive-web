-- Table for color inventory with alert thresholds
CREATE TABLE public.inventario_colores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  modelo TEXT NOT NULL,
  color TEXT NOT NULL,
  cantidad_disponible INTEGER NOT NULL DEFAULT 0,
  umbral_alerta INTEGER NOT NULL DEFAULT 5, -- Alert when available <= this threshold
  ultima_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(modelo, color)
);
ALTER TABLE public.inventario_colores ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "leer inventario colores" ON public.inventario_colores FOR SELECT TO authenticated USING (true);
CREATE POLICY "escribir inventario colores admin/fabrica" ON public.inventario_colores FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "actualizar inventario colores admin/fabrica" ON public.inventario_colores FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "borrar inventario colores admin" ON public.inventario_colores FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- Indexes for performance
CREATE INDEX idx_inventario_colores_modelo_color ON public.inventario_colores(modelo, color);

-- updated_at trigger
CREATE TRIGGER trg_inventario_colores_updated BEFORE UPDATE ON public.inventario_colores FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Function to increment color inventory (used during VIN import)
CREATE OR REPLACE FUNCTION public.incrementar_inventario_color(_modelo TEXT, _color TEXT, _cantidad INTEGER DEFAULT 1)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO inventario_colores (modelo, color, cantidad_disponible, ultima_actualizacion)
  VALUES (_modelo, upper(_color), _cantidad, now())
  ON CONFLICT (modelo, color) 
  DO UPDATE SET 
    cantidad_disponible = inventario_colores.cantidad_disponible + _cantidad,
    ultima_actualizacion = now(),
    updated_at = now();
END;
$$;

-- Function to decrement color inventory (used during remision confirmation)
CREATE OR REPLACE FUNCTION public.decrementar_inventario_color(_modelo TEXT, _color TEXT, _cantidad INTEGER DEFAULT 1)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE inventario_colores 
  SET 
    cantidad_disponible = GREATEST(0, cantidad_disponible - _cantidad),
    ultima_actualizacion = now(),
    updated_at = now()
  WHERE modelo = _modelo AND color = upper(_color);
END;
$$;
