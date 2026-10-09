-- Add estatus and objetivo_visita columns to crm_actividades
ALTER TABLE crm_actividades 
ADD COLUMN IF NOT EXISTS estatus text DEFAULT 'programada' CHECK (estatus IN ('programada','completada','cancelada')),
ADD COLUMN IF NOT EXISTS objetivo_visita text;
