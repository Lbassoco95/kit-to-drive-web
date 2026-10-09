-- ============================================================================
-- Área Compras — paso 1/2: ampliar los enums
-- Fecha: 2026-09-22
--
-- Postgres exige COMMIT del ADD VALUE antes de usar el valor nuevo en
-- funciones o políticas. Por eso este archivo SOLO agrega los labels;
-- el siguiente (`20260922000004_area_compras.sql`) cablea rol_legacy,
-- helpers y RLS de proveedores.
--
-- Corre ESTE primero en el SQL editor, confirma que terminó OK, y luego
-- el 000003. NO pegues los dos en la misma transacción.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

ALTER TYPE public.user_area ADD VALUE IF NOT EXISTS 'compras';
ALTER TYPE public.app_role  ADD VALUE IF NOT EXISTS 'compras';

DO $postflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
      JOIN pg_type ty ON ty.oid = e.enumtypid
      JOIN pg_namespace n ON n.oid = ty.typnamespace
     WHERE n.nspname = 'public' AND ty.typname = 'user_area' AND e.enumlabel = 'compras'
  ) THEN
    RAISE EXCEPTION 'No quedó el valor compras en user_area.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
      JOIN pg_type ty ON ty.oid = e.enumtypid
      JOIN pg_namespace n ON n.oid = ty.typnamespace
     WHERE n.nspname = 'public' AND ty.typname = 'app_role' AND e.enumlabel = 'compras'
  ) THEN
    RAISE EXCEPTION 'No quedó el valor compras en app_role.';
  END IF;
END $postflight$;
