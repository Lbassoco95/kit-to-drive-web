-- ============================================================================
-- Capacidad por color · revisión operativa
--
-- Se pega completo en el SQL editor de Supabase. Es de SOLO LECTURA.
--
-- El color es un factor propio: lo que limita cuántos motocarros de un color
-- pueden existir no es el orden de armado, sino cuántos juegos de piezas de ESE
-- color llegaron. Este script es para contrastar esa cuenta contra lo que hay
-- físicamente en piso cuando los números no cuadren.
-- ============================================================================

-- 1. ¿Quedó aplicado KIT-4c? `con_dato` debe ser igual a `total_chasis`.
SELECT 'color_original' AS objeto,
       count(*) FILTER (WHERE color_original IS NOT NULL) AS con_dato,
       count(*)                                           AS total_chasis
  FROM public.inventario_chasis;

-- 2. Capacidad real por color, por código de fábrica.
--    juegos_llegaron = lo que declaró el VIN + piezas_extra registradas a mano.
--    juegos_libres en 0 significa que ese color está a tope: para armar uno más
--    hay que intercambiar con otro chasis (intercambiar_color_chasis) o
--    registrar piezas que llegaron fuera del VIN (ajustar_capacidad_color).
SELECT modelo, color,
       COALESCE(piezas_recibidas, 0)                  AS juegos_llegaron,
       juegos_usados,
       COALESCE(piezas_recibidas, 0) - juegos_usados  AS juegos_libres,
       piezas_extra
  FROM public.inventario_colores
 ORDER BY modelo, color;

-- 3. Lo que ve Remisiones al elegir color, por nombre comercial.
--    `disponibles_para_prometer` es el número que aparece en el desplegable.
--    `piezas_recoloreadas` son los chasis que se armaron en un color distinto
--    al que declaró el VIN.
SELECT modelo_comercial, color,
       unidades_libres,
       piezas_disponibles,
       demanda_pendiente,
       unidades_libres + piezas_disponibles - demanda_pendiente AS disponibles_para_prometer,
       capacidad_color,
       capacidad_libre,
       piezas_recoloreadas
  FROM public.v_stock_modelo_color
 ORDER BY modelo_comercial, color;
