-- ============================================================================
-- ¿Por qué la pantalla de Clientes sale vacía, y qué le falta a 20260827000001?
--
-- SOLO LECTURA: no modifica nada. Pégalo completo en el SQL editor de Supabase
-- y corre. Devuelve una tabla; mándala tal cual.
--
-- El síntoma en producción fue «los clientes no se ven»: la lista pedía
-- `clientes.folio_interno` y la base no la tenía, así que PostgREST contestaba
-- 42703 y la pantalla se quedaba con la lista vacía.
--
-- La causa de que la columna no existiera es el renglón 5 del script: hacía
--     PERFORM setval('public.clientes_folio_interno_seq', max_seq);
-- y `max_seq` sale 0 cuando ningún cliente trae todavía un folio CLI-AAAA-NNN.
-- `setval(seq, 0)` NO es válido —la secuencia arranca en 1— y en el SQL editor
-- TODO el archivo va en una transacción: el error tiraba el script completo,
-- sin dejar rastro. Ya está corregido en el archivo (usa el tercer argumento
-- `is_called`), así que ahora se puede correr tal cual.
--
-- Renglón «se puede correr»: dice si el archivo corregido va a pasar.
-- ============================================================================

SELECT * FROM (
  SELECT 1 AS orden, 'tabla' AS tipo, 'clientes' AS objeto,
         CASE WHEN to_regclass('public.clientes') IS NULL
              THEN '✗ NO existe ←— la base no tiene ni la tabla'
              ELSE '✓ existe' END AS estado

  UNION ALL

  -- El objeto del incidente. Si sale '✗', la lista de Clientes está vacía por
  -- esto y hay que correr supabase/migrations/20260827000001.
  SELECT 2, 'columna', 'clientes.' || c,
         CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                            WHERE table_schema='public' AND table_name='clientes' AND column_name=c)
              THEN '✓ existe' ELSE '✗ NO existe ←— corre 20260827000001' END
    FROM unnest(ARRAY['folio_interno','codigo_erp','activo','nombre_comercial']) AS c

  UNION ALL

  -- Paso 2 del script: los clientes nuevos se identifican por folio_interno,
  -- así que codigo_erp tiene que poder quedar en NULL.
  SELECT 3, 'codigo_erp opcional', 'clientes.codigo_erp',
         CASE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
                                WHERE table_schema='public' AND table_name='clientes'
                                  AND column_name='codigo_erp')
              THEN '— no aplica'
              WHEN (SELECT is_nullable FROM information_schema.columns
                     WHERE table_schema='public' AND table_name='clientes'
                       AND column_name='codigo_erp') = 'YES'
              THEN '✓ acepta NULL'
              ELSE '✗ sigue NOT NULL ←— el alta de cliente nuevo va a fallar' END

  UNION ALL

  SELECT 4, 'índice', 'idx_clientes_folio_interno_unico',
         CASE WHEN EXISTS (SELECT 1 FROM pg_indexes
                            WHERE schemaname='public'
                              AND indexname='idx_clientes_folio_interno_unico')
              THEN '✓ está' ELSE '✗ NO está' END

  UNION ALL

  SELECT 5, 'secuencia', 'clientes_folio_interno_seq',
         CASE WHEN to_regclass('public.clientes_folio_interno_seq') IS NULL
              THEN '✗ NO está ←— el script se quedó a medias o no corrió'
              ELSE '✓ está' END

  UNION ALL

  SELECT 6, 'función', split_part(f,'(',1),
         CASE WHEN to_regprocedure('public.' || f) IS NULL THEN '✗ NO está' ELSE '✓ está' END
    FROM unnest(ARRAY['generar_folio_interno_cliente()','trg_clientes_folio_interno()']) AS f

  UNION ALL

  SELECT 7, 'trigger', 'clientes.trg_clientes_folio_interno',
         CASE WHEN EXISTS (SELECT 1 FROM pg_trigger t
                             JOIN pg_class c ON c.oid = t.tgrelid
                             JOIN pg_namespace n ON n.oid = c.relnamespace
                            WHERE n.nspname='public' AND c.relname='clientes'
                              AND t.tgname='trg_clientes_folio_interno'
                              AND NOT t.tgisinternal)
              THEN '✓ está' ELSE '✗ NO está ←— los clientes nuevos no reciben folio' END

  UNION ALL

  -- Cuántos clientes hay de verdad. Si aquí sale un número y la pantalla dice
  -- «Sin resultados», el problema es de lectura, no de datos: nada se perdió.
  SELECT 8, 'datos', 'clientes en la tabla',
         CASE WHEN to_regclass('public.clientes') IS NULL THEN '— no aplica'
              ELSE (SELECT count(*)::text FROM public.clientes) END

  UNION ALL

  SELECT 9, 'datos', 'con folio CLI-AAAA-NNN en codigo_erp',
         CASE WHEN to_regclass('public.clientes') IS NULL THEN '— no aplica'
              ELSE (SELECT count(*)::text FROM public.clientes
                     WHERE codigo_erp ~ '^CLI-[0-9]{4}-[0-9]{3}$') END

  UNION ALL

  -- Éste es el renglón que explica el rollback: con 0 clientes con folio, la
  -- versión vieja del script moría aquí y se revertía completa.
  SELECT 10, 'se puede correr', '20260827000001 (archivo corregido)',
         CASE WHEN to_regclass('public.clientes') IS NULL
              THEN '✗ falta la tabla clientes'
              ELSE '✓ sí — el setval ya usa is_called y aguanta max_seq = 0' END

  UNION ALL

  SELECT 11, 'ya aplicado', '20260827000001',
         CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                            WHERE table_schema='public' AND table_name='clientes'
                              AND column_name='folio_interno')
                   AND to_regprocedure('public.generar_folio_interno_cliente()') IS NOT NULL
              THEN '✓ sí' ELSE '— todavía no' END

  UNION ALL

  SELECT 12, 'quién soy', current_user, current_setting('search_path', true)
) t
ORDER BY orden, objeto;
