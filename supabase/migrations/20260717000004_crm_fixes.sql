-- Fix missing columns in crm_oportunidades table
-- Add limitantes fields and fix tipo_venta column name

ALTER TABLE public.crm_oportunidades
  ADD COLUMN IF NOT EXISTS cantidad_estimada integer,         -- unidades de motocarros
  ADD COLUMN IF NOT EXISTS tipo_venta text DEFAULT 'motocarro'
    CHECK (tipo_venta IN ('motocarro','refaccion','servicio','otro')),
  ADD COLUMN IF NOT EXISTS limitante_descuento boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS limitante_flete boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS limitante_precio boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS limitante_notas text;             -- detalle de la limitante

-- Migrate data from tipo to tipo_venta if tipo_venta is null and tipo exists
UPDATE public.crm_oportunidades
SET tipo_venta = tipo
WHERE tipo_venta IS NULL AND tipo IS NOT NULL;

-- Add new fields to crm_actividades for enhanced tracking
ALTER TABLE public.crm_actividades
  ADD COLUMN IF NOT EXISTS resultado text,
  ADD COLUMN IF NOT EXISTS proxima_accion text,
  ADD COLUMN IF NOT EXISTS fecha_proxima date,
  ADD COLUMN IF NOT EXISTS limitante_descuento boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS limitante_flete boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS limitante_precio boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS limitante_notas text;

-- Más tipos de actividad.
--
-- Esto decía `ALTER TYPE crm_actividad_tipo ADD VALUE ...`, pero ese enum no
-- existe en esta base: `crm_actividades.tipo` es text con un CHECK
-- (20260714000002_crm_ventas.sql). El SQL editor manda el archivo completo en
-- UNA transacción, así que esas tres líneas reventaban con «type
-- crm_actividad_tipo does not exist» y se revertía TODO lo de arriba (las
-- columnas limitante_*) y TODO lo de abajo (la vista v_reporte_pipeline).
-- Se sustituye por lo que de verdad hacía falta: ampliar el CHECK.
DO $tipos$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.crm_actividades'::regclass
                AND conname  = 'crm_actividades_tipo_check') THEN
    ALTER TABLE public.crm_actividades DROP CONSTRAINT crm_actividades_tipo_check;
  END IF;
  ALTER TABLE public.crm_actividades ADD CONSTRAINT crm_actividades_tipo_check
    CHECK (tipo IN ('visita','llamada','demo','seguimiento','cotizacion','email','whatsapp','nota'));
END $tipos$;

-- Create view for pipeline reporting
CREATE OR REPLACE VIEW public.v_reporte_pipeline AS
SELECT 
  p.id as vendedor_id,
  p.nombre_completo as vendedor,
  COUNT(DISTINCT o.id) FILTER (WHERE o.etapa NOT IN ('ganado','perdido')) as oportunidades_activas,
  COALESCE(SUM(o.monto_estimado) FILTER (WHERE o.etapa NOT IN ('ganado','perdido')), 0) as valor_pipeline,
  COUNT(DISTINCT o.id) FILTER (WHERE o.etapa = 'ganado' AND DATE_TRUNC('month', o.updated_at) = DATE_TRUNC('month', CURRENT_DATE)) as ganadas_mes,
  COUNT(DISTINCT o.id) FILTER (WHERE o.etapa = 'perdido' AND DATE_TRUNC('month', o.updated_at) = DATE_TRUNC('month', CURRENT_DATE)) as perdidas_mes,
  COUNT(DISTINCT o.id) FILTER (WHERE o.fecha_estimada_cierre < CURRENT_DATE AND o.etapa NOT IN ('ganado','perdido')) as vencidas,
  COUNT(DISTINCT o.id) FILTER (WHERE o.limitante_descuento = true OR o.limitante_flete = true OR o.limitante_precio = true) as con_limitantes
FROM public.profiles p
LEFT JOIN public.crm_oportunidades o ON o.vendedor_id = p.id
WHERE p.activo = true
GROUP BY p.id, p.nombre_completo;
