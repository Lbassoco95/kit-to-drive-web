-- Re-ejecutable: el SQL editor manda el archivo completo en UNA transacción,
-- así que una sentencia que falla por «already exists» revierte todo el resto.
-- Correrlo dos veces tiene que ser inocuo.

-- Table for audit log of deleted records
CREATE TABLE IF NOT EXISTS public.bitacora_eliminaciones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tabla TEXT NOT NULL,
  registro_id UUID NOT NULL,
  eliminado_por UUID REFERENCES auth.users(id),
  nombre_usuario TEXT,
  motivo TEXT NOT NULL,
  datos_eliminados JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE bitacora_eliminaciones ENABLE ROW LEVEL SECURITY;

-- RLS policies
DROP POLICY IF EXISTS "solo admin lee bitacora" ON public.bitacora_eliminaciones;
CREATE POLICY "solo admin lee bitacora" ON public.bitacora_eliminaciones 
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "sistema escribe bitacora" ON public.bitacora_eliminaciones;
CREATE POLICY "sistema escribe bitacora" ON public.bitacora_eliminaciones 
  FOR INSERT TO authenticated WITH CHECK (true);

-- Index for performance
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_tabla ON public.bitacora_eliminaciones(tabla);
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_registro_id ON public.bitacora_eliminaciones(registro_id);
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_eliminado_por ON public.bitacora_eliminaciones(eliminado_por);
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_created_at ON public.bitacora_eliminaciones(created_at);
