-- ============================================================================
-- Folio interno para clientes dados de alta en el nuevo sistema
-- Fecha: 2026-08-27
--
-- Problema: los clientes migrados usan codigo_erp (ej. R195, J494). Cuando un
-- vendedor intenta dar de alta un cliente nuevo y escribe un codigo_erp que ya
-- existe, Postgres lanza "duplicate key value violates unique constraint
-- clientes_codigo_erp_key".
--
-- Solucion:
--  1. Agregar columna folio_interno para clientes dados de alta en el nuevo
--     sistema (formato CLI-AAAA-NNN).
--  2. Hacer codigo_erp opcional. Los clientes migrados siguen teniendo su
--     codigo_erp; los clientes nuevos se identifican por folio_interno.
--  3. Trigger que auto-asigna folio_interno al insertar un cliente cuando no
--     trae codigo_erp.
--  4. Los clientes creados previamente con el patron CLI-AAAA-NNN en
--     codigo_erp se migran a folio_interno para mantener la distincion.
-- ============================================================================

-- 1. Agregar columna de folio interno.
ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS folio_interno TEXT;

-- 2. Permitir clientes sin codigo_erp (los nuevos usaran folio_interno).
ALTER TABLE public.clientes
  ALTER COLUMN codigo_erp DROP NOT NULL;

-- 3. Indice unico parcial para folio_interno. Se aceptan multiples NULLs.
DROP INDEX IF EXISTS idx_clientes_folio_interno_unico;
CREATE UNIQUE INDEX idx_clientes_folio_interno_unico
  ON public.clientes (folio_interno)
  WHERE folio_interno IS NOT NULL;

-- 4. Migrar clientes creados en el nuevo sistema que aun tienen su folio en
--    codigo_erp. Despues de esto codigo_erp queda libre para los migrados.
UPDATE public.clientes
SET folio_interno = codigo_erp,
    codigo_erp    = NULL
WHERE codigo_erp ~ '^CLI-[0-9]{4}-[0-9]{3}$'
  AND folio_interno IS NULL;

-- 5. Secuencia para generar folios internos. Arranca despues del maximo
--    folio_interno existente con formato CLI-AAAA-NNN.
CREATE SEQUENCE IF NOT EXISTS public.clientes_folio_interno_seq
  START WITH 1 INCREMENT BY 1;

DO $$
DECLARE
  max_seq INTEGER;
BEGIN
  SELECT COALESCE(MAX(NULLIF(regexp_replace(folio_interno, '^CLI-[0-9]{4}-', ''), '')::INTEGER), 0)
    INTO max_seq
  FROM public.clientes
  WHERE folio_interno ~ '^CLI-[0-9]{4}-[0-9]{3}$';

  -- El sequence tiene MINVALUE 1; setval(0) falla y revierte toda la
  -- transacción en el SQL editor. Arrancamos en max_seq + 1 con is_called=false
  -- para que el primer nextval devuelva el siguiente número libre.
  PERFORM setval('public.clientes_folio_interno_seq', GREATEST(max_seq, 0) + 1, false);
END $$;

-- 6. Funcion para generar el siguiente folio interno.
CREATE OR REPLACE FUNCTION public.generar_folio_interno_cliente()
RETURNS TEXT AS $$
DECLARE
  anio INTEGER := EXTRACT(YEAR FROM CURRENT_DATE);
  seq  INTEGER;
BEGIN
  seq := nextval('public.clientes_folio_interno_seq');
  RETURN 'CLI-' || anio || '-' || LPAD(seq::TEXT, 3, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Trigger que asigna folio_interno a clientes nuevos sin codigo_erp.
CREATE OR REPLACE FUNCTION public.trg_clientes_folio_interno()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.codigo_erp IS NULL AND NEW.folio_interno IS NULL THEN
    NEW.folio_interno := public.generar_folio_interno_cliente();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_clientes_folio_interno ON public.clientes;
CREATE TRIGGER trg_clientes_folio_interno
  BEFORE INSERT ON public.clientes
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clientes_folio_interno();

-- 8. Asegurar permisos sobre las nuevas funciones/sequence.
GRANT USAGE ON SEQUENCE public.clientes_folio_interno_seq TO authenticated;
GRANT EXECUTE ON FUNCTION public.generar_folio_interno_cliente() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trg_clientes_folio_interno() TO authenticated;
