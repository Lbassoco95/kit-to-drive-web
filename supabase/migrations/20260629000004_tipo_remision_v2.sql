-- Sprint 6b: actualizar tipos de remisión a los 5 correctos
-- motocarro / cabina / instalacion_cabina / activacion / flete
-- Ejecutar en Supabase Dashboard → SQL Editor

-- Primero actualizar valores existentes 'venta' → 'motocarro' (si quedó alguno)
UPDATE public.remisiones SET tipo_remision = 'motocarro' WHERE tipo_remision = 'venta';
UPDATE public.remisiones SET tipo_remision = 'motocarro' WHERE tipo_remision NOT IN ('motocarro','cabina','instalacion_cabina','activacion','flete');

-- Quitar el constraint anterior (nombre auto-generado por Postgres)
ALTER TABLE public.remisiones
  DROP CONSTRAINT IF EXISTS remisiones_tipo_remision_check;

-- Agregar constraint actualizado
ALTER TABLE public.remisiones
  ADD CONSTRAINT remisiones_tipo_remision_check
    CHECK (tipo_remision IN ('motocarro','cabina','instalacion_cabina','activacion','flete'));

-- Actualizar el default
ALTER TABLE public.remisiones
  ALTER COLUMN tipo_remision SET DEFAULT 'motocarro';

-- Verificar
SELECT constraint_name, check_clause
FROM information_schema.check_constraints
WHERE constraint_name = 'remisiones_tipo_remision_check';
