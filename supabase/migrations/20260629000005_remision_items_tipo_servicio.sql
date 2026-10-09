-- Sprint 6c: tipo_servicio por línea de remisión
-- Una remisión puede tener múltiples servicios (motocarro, cabina, activación, flete, etc.)
-- Ejecutar en Supabase Dashboard → SQL Editor

-- 1. Agregar tipo_servicio a cada línea
ALTER TABLE public.remision_items
  ADD COLUMN IF NOT EXISTS tipo_servicio text NOT NULL DEFAULT 'motocarro'
    CHECK (tipo_servicio IN ('motocarro','cabina','instalacion_cabina','activacion','flete'));

-- 2. Hacer modelo y color opcionales (no aplican para servicios como activación/flete)
ALTER TABLE public.remision_items
  ALTER COLUMN modelo DROP NOT NULL;

ALTER TABLE public.remision_items
  ALTER COLUMN color DROP NOT NULL;

-- 3. Limpiar modelo/color en líneas de servicio que no lo necesitan
UPDATE public.remision_items
  SET modelo = NULL, color = NULL
  WHERE tipo_servicio IN ('instalacion_cabina','activacion','flete');

-- 4. Quitar tipo_remision del header (ya no se necesita — el tipo está en cada línea)
--    Lo dejamos por si se quiere usar como resumen, pero sin constraint restrictivo
ALTER TABLE public.remisiones
  DROP CONSTRAINT IF EXISTS remisiones_tipo_remision_check;

-- Verificar
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'remision_items'
ORDER BY ordinal_position;
