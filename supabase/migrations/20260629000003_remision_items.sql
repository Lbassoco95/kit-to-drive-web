-- Sprint 6: Líneas de remisión por unidad (modelo/color/cantidad/con_caja)
-- + nombre_vendedor en remisiones + tipo_remision
-- + con_caja en motocarros
-- Ejecutar en Supabase Dashboard → SQL Editor

-- ─────────────────────────────────────────────
-- 1. Líneas de remisión
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.remision_items (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  remision_id uuid NOT NULL REFERENCES public.remisiones(id) ON DELETE CASCADE,
  modelo     text NOT NULL,
  color      text NOT NULL DEFAULT 'BLANCO',
  cantidad   integer NOT NULL DEFAULT 1 CHECK (cantidad > 0),
  con_caja   boolean NOT NULL DEFAULT false,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.remision_items ENABLE ROW LEVEL SECURITY;

-- Cualquiera con acceso operativo puede leer
CREATE POLICY "remision_items_select"
  ON public.remision_items FOR SELECT
  USING (true);

-- Solo ventas, coordinador y admin pueden insertar
CREATE POLICY "remision_items_insert"
  ON public.remision_items FOR INSERT
  WITH CHECK (
    has_role(auth.uid(), 'admin') OR
    has_role(auth.uid(), 'ventas') OR
    has_role(auth.uid(), 'coordinador')
  );

-- Solo admin puede eliminar
CREATE POLICY "remision_items_delete"
  ON public.remision_items FOR DELETE
  USING (has_role(auth.uid(), 'admin'));

-- ─────────────────────────────────────────────
-- 2. Columnas adicionales en remisiones
-- ─────────────────────────────────────────────

-- Nombre libre del vendedor (para control sin depender del FK)
ALTER TABLE public.remisiones
  ADD COLUMN IF NOT EXISTS nombre_vendedor text;

-- Tipo de remisión: cabina (unidad) / activación / flete
ALTER TABLE public.remisiones
  ADD COLUMN IF NOT EXISTS tipo_remision text NOT NULL DEFAULT 'cabina'
    CHECK (tipo_remision IN ('cabina', 'activacion', 'flete'));

-- ─────────────────────────────────────────────
-- 3. Campo con_caja en motocarros
-- ─────────────────────────────────────────────
ALTER TABLE public.motocarros
  ADD COLUMN IF NOT EXISTS con_caja boolean NOT NULL DEFAULT false;

-- ─────────────────────────────────────────────
-- Verificar
-- ─────────────────────────────────────────────
SELECT 'remision_items' AS tabla, count(*) FROM public.remision_items
UNION ALL
SELECT 'remisiones_cols', count(*) FROM information_schema.columns
  WHERE table_name = 'remisiones' AND column_name IN ('nombre_vendedor', 'tipo_remision');
