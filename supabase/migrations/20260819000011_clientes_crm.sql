-- Ensure clientes table has activo column
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS activo BOOLEAN DEFAULT true;

-- Tabla de comentarios sobre clientes
CREATE TABLE IF NOT EXISTS public.clientes_comentarios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  usuario_id UUID NOT NULL REFERENCES auth.users(id),
  comentario TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.clientes_comentarios ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Usuarios autenticados pueden ver comentarios" ON public.clientes_comentarios FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Usuarios autenticados pueden insertar comentarios" ON public.clientes_comentarios FOR INSERT WITH CHECK (auth.uid() = usuario_id);

-- Tabla de bitácora de cambios en clientes
CREATE TABLE IF NOT EXISTS public.clientes_bitacora (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  usuario_id UUID NOT NULL REFERENCES auth.users(id),
  tipo_cambio TEXT NOT NULL, -- 'edicion', 'archivo', 'reactivacion', 'comentario'
  motivo TEXT NOT NULL,      -- motivo seleccionado o escrito
  datos_anteriores JSONB,
  datos_nuevos JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.clientes_bitacora ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Usuarios autenticados pueden ver bitácora" ON public.clientes_bitacora FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Usuarios autenticados pueden insertar en bitácora" ON public.clientes_bitacora FOR INSERT WITH CHECK (auth.uid() = usuario_id);

-- Indexes for performance
CREATE INDEX idx_clientes_comentarios_cliente_id ON public.clientes_comentarios(cliente_id);
CREATE INDEX idx_clientes_comentarios_created_at ON public.clientes_comentarios(created_at);
CREATE INDEX idx_clientes_bitacora_cliente_id ON public.clientes_bitacora(cliente_id);
CREATE INDEX idx_clientes_bitacora_created_at ON public.clientes_bitacora(created_at);
