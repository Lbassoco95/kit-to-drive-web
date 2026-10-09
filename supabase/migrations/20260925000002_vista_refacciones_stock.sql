-- La vista de refacciones se recreó sin stock_bloqueado / stock_disponible
-- (tiene_compatibilidad es calculada, no es columna de la tabla). Sin esas
-- dos columnas la remisión no puede ver lo apartado. Idempotente.

DO $vista$
DECLARE
  _cols text;
BEGIN
  IF to_regclass('public.v_almacen_refacciones') IS NULL THEN
    RAISE EXCEPTION 'No está la vista v_almacen_refacciones. Corre antes 20260922000001_almacen_refacciones.sql';
  END IF;
  IF to_regprocedure('public.stock_bloqueado_producto(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Falta stock_bloqueado_producto. Corre antes 20260923000001_remisiones_refacciones.sql';
  END IF;

  SELECT string_agg(
    CASE column_name
      WHEN 'num_compatibilidades' THEN 'coalesce(c.num_compat, 0)::integer AS num_compatibilidades'
      WHEN 'tiene_compatibilidad' THEN '(coalesce(c.num_compat, 0) > 0) AS tiene_compatibilidad'
      WHEN 'stock_bloqueado' THEN NULL
      WHEN 'stock_disponible' THEN NULL
      ELSE 'p.' || quote_ident(column_name)
    END,
    ', ' ORDER BY ordinal_position
  )
  INTO _cols
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'v_almacen_refacciones'
    AND column_name NOT IN ('stock_bloqueado', 'stock_disponible');

  EXECUTE 'DROP VIEW IF EXISTS public.v_almacen_refacciones';
  EXECUTE format($sql$
    CREATE VIEW public.v_almacen_refacciones
    WITH (security_invoker = true) AS
    SELECT %s,
      b.stock_bloqueado,
      GREATEST(p.stock - b.stock_bloqueado, 0) AS stock_disponible
    FROM public.almacen_refacciones_productos p
    CROSS JOIN LATERAL (
      SELECT public.stock_bloqueado_producto(p.id) AS stock_bloqueado
    ) b
    LEFT JOIN (
      SELECT producto_id, count(*)::INTEGER AS num_compat
      FROM public.almacen_refacciones_producto_compat
      GROUP BY producto_id
    ) c ON c.producto_id = p.id
  $sql$, _cols);
END $vista$;

GRANT SELECT ON public.v_almacen_refacciones TO authenticated;
NOTIFY pgrst, 'reload schema';
