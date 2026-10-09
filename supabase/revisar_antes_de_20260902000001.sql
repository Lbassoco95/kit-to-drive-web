-- ============================================================================
-- ¿Qué le falta para poder correr 20260902000001?
--
-- SOLO LECTURA: no modifica nada. Pégalo completo en el SQL editor de Supabase
-- y corre. Devuelve una tabla; mándala tal cual.
--
-- Revisa exactamente lo mismo que el preflight de la migración, pero uno por
-- uno y sin abortar, para que se vea cuál es el que falla en vez de un mensaje
-- que el editor puede cortar.
-- ============================================================================

SELECT * FROM (
  SELECT 1 AS orden, 'tabla' AS tipo, t AS objeto,
         CASE WHEN to_regclass('public.' || t) IS NULL THEN '✗ NO existe' ELSE '✓ existe' END AS estado
    FROM unnest(ARRAY['remisiones','remision_items','user_roles','profiles']) AS t

  UNION ALL

  SELECT 2, 'columna', 'user_roles.' || c,
         CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                            WHERE table_schema='public' AND table_name='user_roles' AND column_name=c)
              THEN '✓ existe' ELSE '✗ NO existe' END
    FROM unnest(ARRAY['area','nivel','role','user_id']) AS c

  UNION ALL

  -- Contexto útil aunque el preflight no lo pida.
  SELECT 3, 'columna', 'profiles.activo',
         CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                            WHERE table_schema='public' AND table_name='profiles' AND column_name='activo')
              THEN '✓ existe' ELSE '✗ NO existe' END

  UNION ALL

  SELECT 4, 'helper', split_part(f,'(',1),
         CASE WHEN to_regprocedure('public.' || f) IS NULL THEN '✗ NO está' ELSE '✓ está' END
    FROM unnest(ARRAY[
      'es_area(uuid,public.user_area)',
      'supervisa_area(uuid,public.user_area)',
      'usuario_activo(uuid)',
      'has_role(uuid,public.app_role)'
    ]) AS f

  UNION ALL

  SELECT 5, 'ya aplicado', o,
         CASE WHEN to_regprocedure('public.rol_comercial(uuid)') IS NULL
                   AND to_regclass('public.remisiones_bitacora') IS NULL
              THEN '— todavía no' ELSE '✓ sí' END
    FROM unnest(ARRAY['20260902000001']) AS o

  UNION ALL

  SELECT 6, 'quién soy', current_user, current_setting('search_path', true)
) t
ORDER BY orden, objeto;
