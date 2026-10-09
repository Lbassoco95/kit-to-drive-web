-- Fix: agregar columnas faltantes a remisiones
-- Ejecutar en Supabase Dashboard → SQL Editor

-- Tipo de pago
ALTER TABLE public.remisiones
  ADD COLUMN IF NOT EXISTS tipo_pago text NOT NULL DEFAULT 'anticipado'
    CHECK (tipo_pago IN ('anticipado', 'contra_entrega')),
  ADD COLUMN IF NOT EXISTS pagado boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS comprobante_pago_url text;

-- Columna color_solicitado (si no existe)
ALTER TABLE public.remisiones
  ADD COLUMN IF NOT EXISTS color_solicitado text DEFAULT 'BLANCO';

-- Verificar
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'remisiones'
  AND column_name IN ('tipo_pago', 'pagado', 'comprobante_pago_url', 'color_solicitado')
ORDER BY column_name;
