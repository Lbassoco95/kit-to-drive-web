-- ============================================================================
-- Folio reutilizable en remisiones canceladas
-- Baseline documental para el SQL editor de Supabase (dmhzhyeivvuliumcgsmm).
-- Fecha: 2026-08-26
--
-- ADVERTENCIA: Este proyecto no usa supabase db push / db reset / migration up.
-- Aplicar directamente en el SQL editor de Supabase.
--
-- Cambios:
--  1. Reemplaza el UNIQUE completo de folio_remision por un índice único
--     parcial que excluye remisiones CANCELADA.
--  2. Esto permite reutilizar el folio de una remisión cancelada en una nueva
--     remisión, mientras la cancelada permanece visible para consulta.
-- ============================================================================

-- 1. Eliminar la restricción única anterior (si existe) sobre folio_remision.
DO $$
DECLARE
  _constraint_name text;
BEGIN
  SELECT tc.constraint_name INTO _constraint_name
  FROM information_schema.table_constraints tc
  WHERE tc.table_schema = 'public'
    AND tc.table_name = 'remisiones'
    AND tc.constraint_type = 'UNIQUE'
    AND tc.constraint_name LIKE '%folio%';

  IF _constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.remisiones DROP CONSTRAINT IF EXISTS %I', _constraint_name);
  END IF;
END $$;

-- 2. Precaución: eliminar cualquier índice único previo sobre folio_remision.
DROP INDEX IF EXISTS idx_remisiones_folio_activas;
DROP INDEX IF EXISTS remisiones_folio_remision_idx;

-- 3. Crear índice único parcial: solo folios de remisiones no canceladas.
CREATE UNIQUE INDEX idx_remisiones_folio_activas
  ON public.remisiones (folio_remision)
  WHERE estatus <> 'CANCELADA';
