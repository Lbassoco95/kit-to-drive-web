-- ============================================================================
-- KIT-4c · El color se puede cambiar en fábrica, pero no se puede inventar
--
-- Lo que pasa en piso: el VIN dice que el chasis es BLANCO, y al armarlo
-- fábrica le monta otro color. El cambio en sí no es problema — el problema es
-- que del embarque sólo vinieron N juegos de piezas de cada color, así que
-- sólo N unidades de ese color pueden existir. Si se cambian 5 blancos a azul
-- sin más, el sistema promete 36 azules cuando llegaron 31 juegos azules.
--
-- Modelo:
--   · inventario_chasis.color_original = lo que declaró el VIN (no se toca).
--   · inventario_chasis.color          = el color efectivo, con el que se arma.
--   · inventario_colores.piezas_recibidas = capacidad: juegos de ese color que
--     llegaron. Se siembra con el conteo del VIN y se ajusta a mano cuando
--     llegan piezas extra (`ajustar_capacidad_color`), porque el packing list
--     de partes no trae color.
--   · Regla: los chasis con color efectivo X nunca pueden pasar de la
--     capacidad de X. Cambiar un BLANCO a AZUL exige que haya un juego azul
--     libre — o sea, que antes alguien haya movido un AZUL a otro color, o que
--     se hayan registrado piezas azules extra.
--
-- Fecha: 2026-08-23
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 · Antes de tocar nada: ¿están los cimientos?
-- ============================================================================
-- El SQL editor manda el archivo completo en UNA transacción: si algo revienta
-- a media página, se revierte TODO y no queda ni la primera columna. Cuando eso
-- pasa por una dependencia que falta, el error que sale es de la línea que la
-- usó —a 400 líneas de aquí— y no dice qué script hay que correr antes.
-- Este bloque revisa los cimientos primero y, si falta alguno, dice cuál es y
-- qué archivo lo trae.

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.inventario_chasis') IS NULL THEN
    _faltan := _faltan || 'tabla inventario_chasis (20260819000004_inventario_chasis.sql)'::text;
  END IF;
  IF to_regclass('public.inventario_colores') IS NULL THEN
    _faltan := _faltan || 'tabla inventario_colores (20260819000007_inventario_colores.sql)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = to_regclass('public.inventario_colores')
                    AND contype = 'u'
                    AND pg_get_constraintdef(oid) = 'UNIQUE (modelo, color)') THEN
    _faltan := _faltan || 'UNIQUE (modelo,color) en inventario_colores (20260819000007_inventario_colores.sql)'::text;
  END IF;
  IF to_regclass('public.modelos_producto') IS NULL
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema='public' AND table_name='modelos_producto'
                       AND column_name='nombre_comercial') THEN
    _faltan := _faltan || 'modelos_producto.nombre_comercial (KIT-3 · 20260822000001_configuracion_manual_unidades.sql)'::text;
  END IF;
  IF to_regprocedure('public.configurar_unidad(uuid,uuid,integer)') IS NULL
     AND to_regprocedure('public.configurar_unidad(uuid,uuid,integer,text)') IS NULL THEN
    _faltan := _faltan || 'configurar_unidad() (KIT-3 · 20260822000001_configuracion_manual_unidades.sql)'::text;
  END IF;
  IF to_regclass('public.incidencias_chasis') IS NULL
     OR to_regprocedure('public.chasis_bloqueado(uuid)') IS NULL THEN
    _faltan := _faltan || 'incidencias_chasis / chasis_bloqueado() (KIT-4 · 20260823000001_incidencias_chasis_colores_cierre.sql)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='inventario_colores'
                    AND column_name='piezas_total') THEN
    _faltan := _faltan || 'inventario_colores.piezas_total y compañía (KIT-4 · 20260823000001_incidencias_chasis_colores_cierre.sql)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='remision_items'
                    AND column_name='tipo_servicio') THEN
    _faltan := _faltan || 'remision_items.tipo_servicio (20260629000005_remision_items_tipo_servicio.sql)'::text;
  END IF;

  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION E'KIT-4c no se puede aplicar: falta lo que va antes.\n  · %\nCorre primero esos archivos (en orden de nombre) y vuelve a intentar. No se modificó nada.',
      array_to_string(_faltan, E'\n  · ');
  END IF;

  RAISE NOTICE 'KIT-4c · cimientos completos, aplicando.';
END $preflight$;


-- ============================================================================
-- BLOQUE 1 · Color declarado vs. color efectivo
-- ============================================================================

ALTER TABLE public.inventario_chasis
  ADD COLUMN IF NOT EXISTS color_original text;

-- Se siembra con el color actual: hoy nadie ha cambiado colores todavía, así
-- que lo que hay en `color` es exactamente lo que declaró el VIN.
UPDATE public.inventario_chasis SET color_original = color WHERE color_original IS NULL;

COMMENT ON COLUMN public.inventario_chasis.color_original IS
  'Color que declaró el VIN / packing list. No se modifica: es la referencia '
  'de cuántos juegos de cada color llegaron.';
COMMENT ON COLUMN public.inventario_chasis.color IS
  'Color efectivo: el que se le montó al armar. Se cambia con '
  'cambiar_color_chasis(), que valida que haya juego libre de ese color.';

CREATE INDEX IF NOT EXISTS idx_inventario_chasis_color_original
  ON public.inventario_chasis (modelo, color_original);

-- Toda pieza que entre (importación de VINs incluida) queda con su color de
-- origen registrado. Sin esto, un embarque nuevo entraría sin referencia de
-- cuántos juegos de cada color llegaron.
CREATE OR REPLACE FUNCTION public._fijar_color_original() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public' AS $$
BEGIN
  IF NEW.color_original IS NULL OR trim(NEW.color_original) = '' THEN
    NEW.color_original := public.norm_color(NEW.color);
  ELSE
    NEW.color_original := public.norm_color(NEW.color_original);
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_chasis_color_original ON public.inventario_chasis;
CREATE TRIGGER trg_chasis_color_original
  BEFORE INSERT ON public.inventario_chasis
  FOR EACH ROW EXECUTE FUNCTION public._fijar_color_original();


-- ============================================================================
-- BLOQUE 2 · Capacidad por color
-- ============================================================================

ALTER TABLE public.inventario_colores
  ADD COLUMN IF NOT EXISTS piezas_recibidas integer,
  ADD COLUMN IF NOT EXISTS piezas_extra     integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS juegos_usados    integer NOT NULL DEFAULT 0;

-- La capacidad NO se guarda como un número suelto: se deriva de lo que dijo el
-- VIN (cada chasis llega con su juego de color) más los ajustes manuales. Así
-- una importación futura sube la capacidad sola, sin que nadie tenga que
-- acordarse de resembrarla.
COMMENT ON COLUMN public.inventario_colores.piezas_recibidas IS
  'Capacidad (derivada, no editar a mano): juegos de ese color que declaró el '
  'VIN + piezas_extra. La recalcula recalcular_inventario_colores().';
COMMENT ON COLUMN public.inventario_colores.piezas_extra IS
  'Ajuste manual de capacidad: juegos que llegaron fuera del VIN (o mermas, en '
  'negativo). Se mueve sólo con ajustar_capacidad_color(), que deja bitácora.';
COMMENT ON COLUMN public.inventario_colores.juegos_usados IS
  'Chasis que hoy traen ese color efectivo. No puede pasar de piezas_recibidas.';

-- Bitácora de movimientos de color y de ajustes de capacidad.
CREATE TABLE IF NOT EXISTS public.bitacora_color (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo           text NOT NULL CHECK (tipo IN ('cambio_chasis','ajuste_capacidad')),
  chasis_id      uuid REFERENCES public.inventario_chasis(id) ON DELETE SET NULL,
  ns_chasis      text,
  motocarro_id   uuid REFERENCES public.motocarros(id) ON DELETE SET NULL,
  modelo         text,
  color_anterior text,
  color_nuevo    text,
  cantidad_antes integer,
  cantidad_nueva integer,
  motivo         text NOT NULL,
  actor          uuid REFERENCES auth.users(id),
  creado_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bitacora_color_chasis ON public.bitacora_color (chasis_id, creado_at DESC);
CREATE INDEX IF NOT EXISTS idx_bitacora_color_tipo   ON public.bitacora_color (tipo, creado_at DESC);

ALTER TABLE public.bitacora_color ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "autenticados leen bitacora_color" ON public.bitacora_color;
CREATE POLICY "autenticados leen bitacora_color" ON public.bitacora_color
  FOR SELECT TO authenticated USING (true);
-- Sólo escriben las RPC (SECURITY DEFINER).



-- ============================================================================
-- BLOQUE 2b · La capacidad no se puede exceder, venga de donde venga
-- ============================================================================
-- cambiar_color_chasis y configurar_unidad ya validan, pero RLS permite que un
-- admin haga un UPDATE directo a inventario_chasis.color. Esta verificación
-- corre después de cualquier movimiento de piezas y tumba la transacción si
-- algún color quedó con más chasis que juegos disponibles.

CREATE OR REPLACE FUNCTION public._verificar_capacidad_color() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _mal record;
BEGIN
  WITH usados AS (
    SELECT modelo, upper(color) AS color, count(*) AS n
      FROM inventario_chasis GROUP BY 1, 2
  ), vin AS (
    SELECT modelo, upper(COALESCE(color_original, color)) AS color, count(*) AS n
      FROM inventario_chasis GROUP BY 1, 2
  )
  SELECT u.modelo, u.color, u.n AS usados,
         COALESCE(v.n,0) + COALESCE(icol.piezas_extra,0) AS capacidad
    INTO _mal
    FROM usados u
    LEFT JOIN vin v ON v.modelo = u.modelo AND v.color = u.color
    LEFT JOIN inventario_colores icol ON icol.modelo = u.modelo AND icol.color = u.color
   WHERE u.n > COALESCE(v.n,0) + COALESCE(icol.piezas_extra,0)
   ORDER BY u.modelo, u.color
   LIMIT 1;

  IF _mal.modelo IS NOT NULL THEN
    RAISE EXCEPTION 'Quedarían % chasis % en % y sólo hay % juegos de ese color. Usa intercambiar_color_chasis o registra las piezas extra con ajustar_capacidad_color',
      _mal.usados, _mal.color, _mal.modelo, _mal.capacidad;
  END IF;

  RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_verificar_capacidad_color ON public.inventario_chasis;
CREATE TRIGGER trg_verificar_capacidad_color
  AFTER INSERT OR UPDATE OR DELETE ON public.inventario_chasis
  FOR EACH STATEMENT EXECUTE FUNCTION public._verificar_capacidad_color();

-- ============================================================================
-- BLOQUE 3 · Normalizar el color (mismo criterio que el frontend)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.norm_color(_color text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT CASE upper(trim(COALESCE(_color,'')))
    WHEN 'WHITE'  THEN 'BLANCO'
    WHEN 'BLANC'  THEN 'BLANCO'
    WHEN 'BLUE'   THEN 'AZUL'
    WHEN 'RED'    THEN 'ROJO'
    WHEN 'BLACK'  THEN 'NEGRO'
    WHEN 'GREEN'  THEN 'VERDE'
    WHEN 'ORANGE' THEN 'NARANJA'
    WHEN 'SILVER' THEN 'PLATA'
    WHEN 'GRAY'   THEN 'GRIS'
    WHEN 'GREY'   THEN 'GRIS'
    WHEN 'YELLOW' THEN 'AMARILLO'
    ELSE upper(trim(COALESCE(_color,'')))
  END;
$$;

GRANT EXECUTE ON FUNCTION public.norm_color(text) TO authenticated;


-- ============================================================================
-- BLOQUE 4 · Capacidad libre de un color
-- ============================================================================

CREATE OR REPLACE FUNCTION public.capacidad_color_libre(_modelo text, _color text)
RETURNS integer LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _vin int; _extra int; _usados int; _col text;
BEGIN
  _col := public.norm_color(_color);

  -- Capacidad en vivo: juegos que declaró el VIN + ajustes manuales. No se lee
  -- de inventario_colores para no depender de que el recálculo ya haya corrido.
  SELECT count(*) INTO _vin
    FROM inventario_chasis
   WHERE modelo = _modelo AND upper(COALESCE(color_original, color)) = _col;

  SELECT COALESCE(piezas_extra, 0) INTO _extra
    FROM inventario_colores WHERE modelo = _modelo AND color = _col;

  SELECT count(*) INTO _usados
    FROM inventario_chasis
   WHERE modelo = _modelo AND upper(color) = _col;

  RETURN _vin + COALESCE(_extra, 0) - _usados;
END; $$;

GRANT EXECUTE ON FUNCTION public.capacidad_color_libre(text,text) TO authenticated;


-- ============================================================================
-- BLOQUE 5 · Cambiar el color de un chasis
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cambiar_color_chasis(
  _chasis_id uuid, _color_nuevo text, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _ch record; _m record; _col text; _libre int; _cap int; _usados int;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede cambiar el color de un chasis';
  END IF;
  IF _motivo IS NULL OR length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Se requiere un motivo (mínimo 5 caracteres)';
  END IF;

  _col := public.norm_color(_color_nuevo);
  IF _col IS NULL OR _col !~ '^[A-ZÁÉÍÓÚÑ ]{3,20}$' THEN
    RAISE EXCEPTION 'Color inválido: %', _color_nuevo;
  END IF;

  SELECT * INTO _ch FROM inventario_chasis WHERE id = _chasis_id;
  IF _ch IS NULL THEN RAISE EXCEPTION 'Chasis no encontrado'; END IF;

  IF upper(_ch.color) = _col THEN
    RETURN jsonb_build_object('ok', true, 'sin_cambio', true, 'color', _col);
  END IF;

  -- Si ya está comprometido con un cliente, el color es parte del pedido:
  -- cambiarlo aquí dejaría la remisión pidiendo una cosa y la unidad siendo otra.
  IF _ch.motocarro_id IS NOT NULL THEN
    SELECT * INTO _m FROM motocarros WHERE id = _ch.motocarro_id;
    IF _m.remision_id IS NOT NULL THEN
      RAISE EXCEPTION 'La unidad #% ya está asignada a una remisión: el color es parte del pedido. Libera la unidad o corrige la remisión antes de cambiarlo',
        _m.orden_armado;
    END IF;
    IF _m.estatus_entrega = 'ENTREGADA' THEN
      RAISE EXCEPTION 'La unidad #% ya fue entregada; no se le cambia el color', _m.orden_armado;
    END IF;
  END IF;

  -- La regla del embarque: no hay más unidades de un color que juegos de ese color.
  _libre := public.capacidad_color_libre(_ch.modelo, _col);
  IF _libre <= 0 THEN
    SELECT count(*) INTO _usados
      FROM inventario_chasis WHERE modelo = _ch.modelo AND upper(color) = _col;
    _cap := _usados + _libre;   -- capacidad real = usados + libres
    RAISE EXCEPTION 'No hay juegos % libres para %: hay % juegos y ya están ocupados %. Intercambia el color con otro chasis (intercambiar_color_chasis) o registra las piezas extra (ajustar_capacidad_color)',
      _col, _ch.modelo, _cap, _usados;
  END IF;

  UPDATE inventario_chasis SET color = _col WHERE id = _chasis_id;

  -- La unidad ya armada (sin remisión) se mueve con su chasis.
  IF _ch.motocarro_id IS NOT NULL THEN
    UPDATE motocarros SET color = _col, updated_at = now() WHERE id = _ch.motocarro_id;
  END IF;

  INSERT INTO bitacora_color (tipo, chasis_id, ns_chasis, motocarro_id, modelo,
                              color_anterior, color_nuevo, motivo, actor)
  VALUES ('cambio_chasis', _chasis_id, _ch.numero_chasis, _ch.motocarro_id, _ch.modelo,
          upper(_ch.color), _col, trim(_motivo), auth.uid());

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true,
    'ns_chasis', _ch.numero_chasis,
    'color_anterior', upper(_ch.color), 'color_nuevo', _col,
    'color_vin', upper(COALESCE(_ch.color_original, _ch.color)),
    'motocarro_id', _ch.motocarro_id,
    'capacidad_libre_restante', public.capacidad_color_libre(_ch.modelo, _col));
END; $$;

GRANT EXECUTE ON FUNCTION public.cambiar_color_chasis(uuid, text, text) TO authenticated;


-- ============================================================================
-- BLOQUE 6 · Ajustar la capacidad (piezas extra, correcciones)
-- ============================================================================
-- El packing list de partes no trae color, así que cuando llegan juegos de un
-- color aparte del VIN, alguien tiene que registrarlo — con motivo, para que
-- se pueda auditar por qué de pronto hay más azules de los que dijo el VIN.

CREATE OR REPLACE FUNCTION public.ajustar_capacidad_color(
  _modelo text, _color text, _piezas_recibidas integer, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _col text; _antes int; _usados int; _vin int;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede ajustar la capacidad de color';
  END IF;
  IF _motivo IS NULL OR length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Se requiere un motivo (mínimo 5 caracteres)';
  END IF;
  IF _piezas_recibidas IS NULL OR _piezas_recibidas < 0 THEN
    RAISE EXCEPTION 'La cantidad de piezas no puede ser negativa';
  END IF;

  _col := public.norm_color(_color);

  SELECT count(*) INTO _usados
    FROM inventario_chasis WHERE modelo = _modelo AND upper(color) = _col;
  IF _piezas_recibidas < _usados THEN
    RAISE EXCEPTION 'No puedes dejar la capacidad en % : ya hay % chasis armados con % en %',
      _piezas_recibidas, _usados, _col, _modelo;
  END IF;

  -- Se guarda el DELTA contra lo que dijo el VIN, no el absoluto: así una
  -- importación posterior suma su capacidad sin borrar este ajuste.
  SELECT count(*) INTO _vin
    FROM inventario_chasis
   WHERE modelo = _modelo AND upper(COALESCE(color_original, color)) = _col;

  SELECT COALESCE(piezas_recibidas, 0) INTO _antes
    FROM inventario_colores WHERE modelo = _modelo AND color = _col;
  _antes := COALESCE(_antes, 0);

  INSERT INTO inventario_colores (modelo, color, piezas_extra, piezas_recibidas, umbral_alerta, updated_at)
  VALUES (_modelo, _col, _piezas_recibidas - _vin, _piezas_recibidas, 3, now())
  ON CONFLICT (modelo, color) DO UPDATE
    SET piezas_extra = _piezas_recibidas - _vin,
        piezas_recibidas = _piezas_recibidas,
        updated_at = now();

  INSERT INTO bitacora_color (tipo, modelo, color_nuevo, cantidad_antes, cantidad_nueva, motivo, actor)
  VALUES ('ajuste_capacidad', _modelo, _col, _antes, _piezas_recibidas, trim(_motivo), auth.uid());

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'modelo', _modelo, 'color', _col,
    'antes', COALESCE(_antes,0), 'ahora', _piezas_recibidas,
    'capacidad_libre', public.capacidad_color_libre(_modelo, _col));
END; $$;

GRANT EXECUTE ON FUNCTION public.ajustar_capacidad_color(text, text, integer, text) TO authenticated;


-- ============================================================================
-- BLOQUE 7 · El recálculo también lleva la capacidad
-- ============================================================================
-- Igual que KIT-4, pero agregando juegos_usados. piezas_recibidas NO se toca:
-- es configuración (como umbral_alerta), no un conteo derivado.

CREATE OR REPLACE FUNCTION public.recalcular_inventario_colores()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _filas int;
BEGIN
  WITH ch AS (
    SELECT ic.modelo, upper(ic.color) AS color,
           count(*)                                                                     AS piezas_total,
           count(*) FILTER (WHERE ic.motocarro_id IS NULL AND ic.estatus = 'disponible') AS disponibles,
           count(*) FILTER (WHERE ic.estatus = 'en_revision')                            AS en_revision,
           count(*) FILTER (WHERE ic.estatus = 'garantia')                               AS garantia,
           count(*) FILTER (WHERE ic.estatus = 'no_util')                                AS no_util,
           count(*) FILTER (WHERE ic.motocarro_id IS NOT NULL)                           AS configuradas
      FROM inventario_chasis ic
     GROUP BY ic.modelo, upper(ic.color)
  ), un AS (
    -- "Libre" = vendible hoy: con los dos seriales y sin una incidencia que
    -- detenga su chasis.
    SELECT m.modelo, upper(m.color) AS color,
           count(*) FILTER (WHERE m.remision_id IS NULL
                              AND m.estatus_entrega <> 'ENTREGADA'
                              AND m.ns_chasis IS NOT NULL AND m.ns_motor IS NOT NULL
                              AND COALESCE(ic.estatus, 'disponible')
                                  NOT IN ('en_revision','garantia','no_util'))        AS libres,
           count(*) FILTER (WHERE m.remision_id IS NOT NULL
                              AND m.estatus_entrega <> 'ENTREGADA')                   AS comprometidas,
           count(*) FILTER (WHERE m.estatus_entrega = 'ENTREGADA')                    AS entregadas
      FROM motocarros m
      LEFT JOIN inventario_chasis ic ON ic.numero_chasis = m.ns_chasis
     GROUP BY m.modelo, upper(m.color)
  ), vin AS (
    -- Cuántos juegos de cada color llegaron según el VIN: es la capacidad base.
    SELECT ic.modelo, upper(COALESCE(ic.color_original, ic.color)) AS color, count(*) AS juegos
      FROM inventario_chasis ic
     GROUP BY 1, 2
  ), llaves AS (
    SELECT modelo, color FROM ch
    UNION
    SELECT modelo, color FROM un
    UNION
    SELECT modelo, color FROM vin
  ), calc AS (
    SELECT k.modelo, k.color,
           COALESCE(ch.piezas_total,0)   AS piezas_total,
           COALESCE(ch.disponibles,0)    AS disponibles,
           COALESCE(ch.en_revision,0)    AS en_revision,
           COALESCE(ch.garantia,0)       AS garantia,
           COALESCE(ch.no_util,0)        AS no_util,
           COALESCE(ch.configuradas,0)   AS configuradas,
           COALESCE(un.libres,0)         AS libres,
           COALESCE(un.comprometidas,0)  AS comprometidas,
           COALESCE(un.entregadas,0)     AS entregadas,
           COALESCE(vin.juegos,0)        AS juegos_vin,
           mp.nombre_comercial
      FROM llaves k
      LEFT JOIN ch  ON ch.modelo  = k.modelo AND ch.color  = k.color
      LEFT JOIN un  ON un.modelo  = k.modelo AND un.color  = k.color
      LEFT JOIN vin ON vin.modelo = k.modelo AND vin.color = k.color
      LEFT JOIN modelos_producto mp ON mp.modelo = k.modelo
  )
  INSERT INTO inventario_colores AS ic (
    modelo, color, nombre_comercial, cantidad_disponible, piezas_total,
    piezas_en_revision, piezas_garantia, piezas_no_util, unidades_configuradas,
    unidades_libres, unidades_comprometidas, unidades_entregadas,
    juegos_usados, piezas_recibidas, umbral_alerta, updated_at, recalculado_at)
  SELECT modelo, color, COALESCE(nombre_comercial, modelo), disponibles, piezas_total,
         en_revision, garantia, no_util, configuradas,
         libres, comprometidas, entregadas,
         -- Cada chasis con ese color efectivo ocupa un juego de piezas.
         piezas_total,
         -- Capacidad = juegos que declaró el VIN (los ajustes manuales se suman
         -- en el DO UPDATE, que sí puede leer piezas_extra de la fila que ya existe).
         juegos_vin,
         3, now(), now()
    FROM calc
  ON CONFLICT (modelo, color) DO UPDATE SET
    nombre_comercial       = EXCLUDED.nombre_comercial,
    cantidad_disponible    = EXCLUDED.cantidad_disponible,
    piezas_total           = EXCLUDED.piezas_total,
    piezas_en_revision     = EXCLUDED.piezas_en_revision,
    piezas_garantia        = EXCLUDED.piezas_garantia,
    piezas_no_util         = EXCLUDED.piezas_no_util,
    unidades_configuradas  = EXCLUDED.unidades_configuradas,
    unidades_libres        = EXCLUDED.unidades_libres,
    unidades_comprometidas = EXCLUDED.unidades_comprometidas,
    unidades_entregadas    = EXCLUDED.unidades_entregadas,
    juegos_usados          = EXCLUDED.juegos_usados,
    piezas_recibidas       = EXCLUDED.piezas_recibidas + COALESCE(ic.piezas_extra, 0),
    updated_at             = now(),
    recalculado_at         = now();

  GET DIAGNOSTICS _filas = ROW_COUNT;

  -- Combinaciones que ya no tienen nada: quedan en cero, no se borran, y
  -- conservan su capacidad (los juegos de ese color siguen existiendo).
  UPDATE inventario_colores SET
    cantidad_disponible = 0, piezas_total = 0, piezas_en_revision = 0,
    piezas_garantia = 0, piezas_no_util = 0, unidades_configuradas = 0,
    unidades_libres = 0, unidades_comprometidas = 0, unidades_entregadas = 0,
    juegos_usados = 0, piezas_recibidas = GREATEST(COALESCE(piezas_extra,0), 0),
    updated_at = now(), recalculado_at = now()
  WHERE NOT EXISTS (SELECT 1 FROM inventario_chasis ic
                     WHERE ic.modelo = inventario_colores.modelo
                       AND upper(ic.color) = inventario_colores.color)
    AND NOT EXISTS (SELECT 1 FROM motocarros m
                     WHERE m.modelo = inventario_colores.modelo
                       AND upper(m.color) = inventario_colores.color)
    AND (cantidad_disponible <> 0 OR piezas_total <> 0 OR unidades_libres <> 0
         OR unidades_comprometidas <> 0 OR unidades_entregadas <> 0 OR juegos_usados <> 0);

  RETURN jsonb_build_object('ok', true, 'combinaciones', _filas);
END; $$;

GRANT EXECUTE ON FUNCTION public.recalcular_inventario_colores() TO authenticated;


-- ============================================================================
-- BLOQUE 8 · La vista muestra la capacidad del color
-- ============================================================================

DROP VIEW IF EXISTS public.v_stock_modelo_color;
CREATE VIEW public.v_stock_modelo_color AS
WITH ch AS (
  SELECT upper(COALESCE(mp.nombre_comercial, ic.modelo)) AS modelo,
         upper(ic.color) AS color,
         count(*) FILTER (WHERE ic.motocarro_id IS NULL AND ic.estatus = 'disponible') AS piezas_disponibles,
         count(*) FILTER (WHERE ic.estatus = 'en_revision')                            AS piezas_en_revision,
         count(*) FILTER (WHERE ic.estatus = 'garantia')                               AS piezas_garantia,
         count(*) FILTER (WHERE ic.estatus = 'no_util')                                AS piezas_no_util,
         count(*) FILTER (WHERE upper(COALESCE(ic.color_original, ic.color)) <> upper(ic.color))
                                                                                       AS piezas_recoloreadas
    FROM inventario_chasis ic
    LEFT JOIN modelos_producto mp ON mp.modelo = ic.modelo
   GROUP BY 1, 2
), un AS (
  SELECT upper(COALESCE(mp.nombre_comercial, m.modelo)) AS modelo,
         upper(m.color) AS color,
         count(*) FILTER (WHERE m.remision_id IS NULL AND m.estatus_entrega <> 'ENTREGADA'
                            AND m.ns_chasis IS NOT NULL AND m.ns_motor IS NOT NULL
                            AND COALESCE(ic.estatus,'disponible')
                                NOT IN ('en_revision','garantia','no_util'))        AS unidades_libres,
         count(*) FILTER (WHERE m.remision_id IS NULL
                            AND (m.ns_chasis IS NULL OR m.ns_motor IS NULL))        AS unidades_sin_serial,
         count(*) FILTER (WHERE m.remision_id IS NULL AND m.estatus_entrega <> 'ENTREGADA'
                            AND COALESCE(ic.estatus,'disponible')
                                IN ('en_revision','garantia','no_util'))            AS unidades_detenidas,
         count(*) FILTER (WHERE m.remision_id IS NOT NULL
                            AND m.estatus_entrega <> 'ENTREGADA')                   AS unidades_comprometidas,
         count(*) FILTER (WHERE m.estatus_entrega = 'ENTREGADA')                    AS unidades_entregadas
    FROM motocarros m
    LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
    LEFT JOIN inventario_chasis ic ON ic.numero_chasis = m.ns_chasis
   GROUP BY 1, 2
), cap AS (
  -- Capacidad: juegos de piezas de ese color. Se suma por nombre comercial
  -- porque un mismo color puede venir en varios códigos de fábrica.
  SELECT upper(COALESCE(mp.nombre_comercial, icol.modelo)) AS modelo,
         upper(icol.color) AS color,
         sum(COALESCE(icol.piezas_recibidas, 0))::int AS capacidad_color,
         sum(COALESCE(icol.juegos_usados, 0))::int    AS juegos_usados
    FROM inventario_colores icol
    LEFT JOIN modelos_producto mp ON mp.modelo = icol.modelo
   GROUP BY 1, 2
), pedido AS (
  SELECT upper(COALESCE(NULLIF(trim(ri.modelo),''), 'SIN MODELO')) AS modelo,
         upper(COALESCE(NULLIF(trim(ri.color),''), 'SIN COLOR'))   AS color,
         sum(GREATEST(ri.cantidad, 0)) AS solicitadas
    FROM remision_items ri
    JOIN remisiones r ON r.id = ri.remision_id
   WHERE ri.tipo_servicio = 'motocarro'
     AND r.estatus IN ('NUEVA','PARCIAL')
   GROUP BY 1, 2
), asignado AS (
  SELECT upper(COALESCE(mp.nombre_comercial, m.modelo)) AS modelo,
         upper(m.color) AS color,
         count(*) AS asignadas
    FROM motocarros m
    JOIN remisiones r ON r.id = m.remision_id
    LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
   WHERE r.estatus IN ('NUEVA','PARCIAL')
   GROUP BY 1, 2
), llaves AS (
  SELECT modelo, color FROM ch
  UNION SELECT modelo, color FROM un
  UNION SELECT modelo, color FROM cap
  UNION SELECT modelo, color FROM pedido
)
SELECT k.modelo                                     AS modelo_comercial,
       k.color,
       COALESCE(ch.piezas_disponibles, 0)           AS piezas_disponibles,
       COALESCE(ch.piezas_en_revision, 0)           AS piezas_en_revision,
       COALESCE(ch.piezas_garantia, 0)              AS piezas_garantia,
       COALESCE(ch.piezas_no_util, 0)               AS piezas_no_util,
       COALESCE(ch.piezas_recoloreadas, 0)          AS piezas_recoloreadas,
       COALESCE(un.unidades_libres, 0)              AS unidades_libres,
       COALESCE(un.unidades_sin_serial, 0)          AS unidades_sin_serial,
       COALESCE(un.unidades_detenidas, 0)           AS unidades_detenidas,
       COALESCE(un.unidades_comprometidas, 0)       AS unidades_comprometidas,
       COALESCE(un.unidades_entregadas, 0)          AS unidades_entregadas,
       -- Cuántos juegos de ese color llegaron, cuántos están ocupados y
       -- cuántos quedan para repintar/reasignar otro chasis a este color.
       COALESCE(cap.capacidad_color, 0)             AS capacidad_color,
       COALESCE(cap.juegos_usados, 0)               AS juegos_usados,
       COALESCE(cap.capacidad_color, 0) - COALESCE(cap.juegos_usados, 0) AS capacidad_libre,
       COALESCE(p.solicitadas, 0)                   AS solicitadas,
       COALESCE(a.asignadas, 0)                     AS asignadas,
       GREATEST(COALESCE(p.solicitadas,0) - COALESCE(a.asignadas,0), 0) AS demanda_pendiente,
       COALESCE(un.unidades_libres,0)
         - GREATEST(COALESCE(p.solicitadas,0) - COALESCE(a.asignadas,0), 0) AS holgura_con_serial,
       COALESCE(un.unidades_libres,0) + COALESCE(ch.piezas_disponibles,0)
         - GREATEST(COALESCE(p.solicitadas,0) - COALESCE(a.asignadas,0), 0) AS holgura_con_piezas
  FROM llaves k
  LEFT JOIN ch      ON ch.modelo = k.modelo AND ch.color = k.color
  LEFT JOIN un      ON un.modelo = k.modelo AND un.color = k.color
  LEFT JOIN cap     ON cap.modelo = k.modelo AND cap.color = k.color
  LEFT JOIN pedido  p ON p.modelo = k.modelo AND p.color = k.color
  LEFT JOIN asignado a ON a.modelo = k.modelo AND a.color = k.color;

REVOKE ALL ON public.v_stock_modelo_color FROM anon;
GRANT SELECT ON public.v_stock_modelo_color TO authenticated;

COMMENT ON VIEW public.v_stock_modelo_color IS
  'Por modelo comercial y color: piezas sanas, piezas detenidas por incidencia, '
  'unidades libres/comprometidas, demanda pendiente y la capacidad de color '
  '(juegos que llegaron vs. ocupados) que limita cuántas unidades de ese color '
  'pueden existir.';


-- ============================================================================
-- BLOQUE 9 · Configurar unidad eligiendo el color
-- ============================================================================
-- Fábrica arma y decide el color en ese momento. Se agrega un 4º parámetro
-- opcional: si viene distinto al del chasis, se cambia por cambiar_color_chasis
-- (que valida la capacidad) antes de crear la unidad.

DROP FUNCTION IF EXISTS public.configurar_unidad(uuid, uuid, integer);

CREATE OR REPLACE FUNCTION public.configurar_unidad(
  _chasis_id uuid, _motor_id uuid, _orden integer DEFAULT NULL, _color text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _ch record; _mo record; _orden_final int; _moto_id uuid; _inc record;
  _col text; _color_cambiado boolean := false;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede configurar unidades';
  END IF;

  SELECT * INTO _ch FROM inventario_chasis WHERE id = _chasis_id;
  IF _ch IS NULL THEN RAISE EXCEPTION 'Chasis no encontrado'; END IF;
  IF _ch.motocarro_id IS NOT NULL THEN
    RAISE EXCEPTION 'El chasis % ya está asignado a una unidad', _ch.numero_chasis;
  END IF;

  IF public.chasis_bloqueado(_chasis_id) THEN
    SELECT folio, estatus, parte_afectada INTO _inc
      FROM incidencias_chasis
     WHERE chasis_id = _chasis_id
       AND (estatus IN ('no_util','garantia')
            OR (estatus IN ('abierta','en_revision') AND retiene_chasis))
     ORDER BY reportado_at DESC LIMIT 1;
    RAISE EXCEPTION 'El chasis % está detenido por la incidencia % (%)%: resuélvela antes de configurarlo',
      _ch.numero_chasis, _inc.folio, _inc.estatus, COALESCE(' — ' || _inc.parte_afectada, '');
  END IF;

  -- Color con el que se arma. Si es otro, tiene que haber juego libre de ese
  -- color: no se puede armar un azul si ya se usaron todos los juegos azules.
  _col := public.norm_color(_color);
  IF _col IS NOT NULL AND _col <> '' AND _col <> upper(_ch.color) THEN
    PERFORM public.cambiar_color_chasis(_chasis_id, _col,
      'Color asignado al armar la unidad (VIN decía ' || upper(COALESCE(_ch.color_original, _ch.color)) || ')');
    SELECT * INTO _ch FROM inventario_chasis WHERE id = _chasis_id;  -- releer el color nuevo
    _color_cambiado := true;
  END IF;

  SELECT * INTO _mo FROM inventario_motor WHERE id = _motor_id;
  IF _mo IS NULL THEN RAISE EXCEPTION 'Motor no encontrado'; END IF;
  IF _mo.motocarro_id IS NOT NULL THEN
    RAISE EXCEPTION 'El motor % ya está asignado a una unidad', _mo.numero_motor;
  END IF;

  _orden_final := COALESCE(_orden, (SELECT COALESCE(max(orden_armado),0)+1 FROM motocarros));
  IF EXISTS (SELECT 1 FROM motocarros WHERE orden_armado = _orden_final) THEN
    RAISE EXCEPTION 'El orden de armado % ya está ocupado', _orden_final;
  END IF;

  INSERT INTO motocarros (orden_armado, modelo, color, ns_chasis, ns_motor,
                          contenedor_id, estatus_armado, estatus_entrega)
  VALUES (_orden_final, _ch.modelo, _ch.color, _ch.numero_chasis, _mo.numero_motor,
          _ch.contenedor_id, 'PENDIENTE', 'NO_APLICA')
  RETURNING id INTO _moto_id;

  UPDATE inventario_chasis SET motocarro_id = _moto_id, estatus = 'configurado',
         fecha_configuracion = now() WHERE id = _chasis_id;
  UPDATE inventario_motor  SET motocarro_id = _moto_id, estatus = 'configurado',
         fecha_configuracion = now() WHERE id = _motor_id;

  -- El historial de la pieza viaja con la unidad (adaptaciones incluidas).
  UPDATE incidencias_chasis SET motocarro_id = _moto_id WHERE chasis_id = _chasis_id;
  UPDATE bitacora_color SET motocarro_id = _moto_id
   WHERE chasis_id = _chasis_id AND motocarro_id IS NULL;

  UPDATE contenedores c SET total_unidades =
    (SELECT count(*) FROM inventario_chasis ic
      WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
  WHERE c.id = _ch.contenedor_id;

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'motocarro_id', _moto_id,
    'orden_armado', _orden_final, 'ns_chasis', _ch.numero_chasis,
    'ns_motor', _mo.numero_motor, 'color', _ch.color,
    'color_cambiado', _color_cambiado,
    'color_vin', upper(COALESCE(_ch.color_original, _ch.color)),
    'modelos_coinciden', (_ch.modelo = _mo.modelo),
    'incidencias_arrastradas', (SELECT count(*) FROM incidencias_chasis WHERE chasis_id = _chasis_id));
END; $$;

GRANT EXECUTE ON FUNCTION public.configurar_unidad(uuid, uuid, integer, text) TO authenticated;



-- ============================================================================
-- BLOQUE 9b · Intercambiar el color de dos chasis
-- ============================================================================
-- La operación de piso más común, y la única que un solo cambio no puede
-- hacer: si del embarque vinieron 31 juegos de cada color, todos los colores
-- están a tope y cambiar UNO solo siempre rompería la capacidad. Lo que de
-- verdad pasa es un intercambio: el juego azul se le monta al chasis que venía
-- blanco, y el juego blanco se queda para el chasis que venía azul. Neutro en
-- capacidad por definición, así que no necesita piezas extra.

CREATE OR REPLACE FUNCTION public.intercambiar_color_chasis(
  _chasis_a uuid, _chasis_b uuid, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _a record; _b record; _ma record; _mb record; _col_a text; _col_b text;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede intercambiar colores';
  END IF;
  IF _motivo IS NULL OR length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Se requiere un motivo (mínimo 5 caracteres)';
  END IF;
  IF _chasis_a = _chasis_b THEN
    RAISE EXCEPTION 'Son el mismo chasis';
  END IF;

  SELECT * INTO _a FROM inventario_chasis WHERE id = _chasis_a;
  SELECT * INTO _b FROM inventario_chasis WHERE id = _chasis_b;
  IF _a IS NULL OR _b IS NULL THEN RAISE EXCEPTION 'Chasis no encontrado'; END IF;

  IF upper(_a.color) = upper(_b.color) THEN
    RAISE EXCEPTION 'Los dos chasis ya son % — no hay nada que intercambiar', upper(_a.color);
  END IF;

  -- Los juegos de piezas son por modelo: una cabina de 200cc no va en un 300cc.
  IF _a.modelo <> _b.modelo THEN
    RAISE EXCEPTION 'No se puede intercambiar entre modelos distintos (% y %): los juegos de piezas no son compatibles',
      _a.modelo, _b.modelo;
  END IF;

  -- Ninguno puede estar ya comprometido con un cliente.
  IF _a.motocarro_id IS NOT NULL THEN
    SELECT * INTO _ma FROM motocarros WHERE id = _a.motocarro_id;
    IF _ma.remision_id IS NOT NULL OR _ma.estatus_entrega = 'ENTREGADA' THEN
      RAISE EXCEPTION 'La unidad #% (chasis %) ya está comprometida con un cliente', _ma.orden_armado, _a.numero_chasis;
    END IF;
  END IF;
  IF _b.motocarro_id IS NOT NULL THEN
    SELECT * INTO _mb FROM motocarros WHERE id = _b.motocarro_id;
    IF _mb.remision_id IS NOT NULL OR _mb.estatus_entrega = 'ENTREGADA' THEN
      RAISE EXCEPTION 'La unidad #% (chasis %) ya está comprometida con un cliente', _mb.orden_armado, _b.numero_chasis;
    END IF;
  END IF;

  _col_a := upper(_a.color);
  _col_b := upper(_b.color);

  -- Los dos colores se mueven en UNA sola sentencia: hacerlo en dos dejaría un
  -- instante con los dos chasis del mismo color, y la verificación de capacidad
  -- (que corre por sentencia) tumbaría el intercambio con razón.
  UPDATE inventario_chasis
     SET color = CASE WHEN id = _chasis_a THEN _col_b ELSE _col_a END
   WHERE id IN (_chasis_a, _chasis_b);

  UPDATE motocarros
     SET color = CASE WHEN id = _a.motocarro_id THEN _col_b ELSE _col_a END,
         updated_at = now()
   WHERE id IN (_a.motocarro_id, _b.motocarro_id);

  INSERT INTO bitacora_color (tipo, chasis_id, ns_chasis, motocarro_id, modelo,
                              color_anterior, color_nuevo, motivo, actor)
  VALUES ('cambio_chasis', _chasis_a, _a.numero_chasis, _a.motocarro_id, _a.modelo,
          _col_a, _col_b, trim(_motivo) || ' (intercambio con ' || _b.numero_chasis || ')', auth.uid()),
         ('cambio_chasis', _chasis_b, _b.numero_chasis, _b.motocarro_id, _b.modelo,
          _col_b, _col_a, trim(_motivo) || ' (intercambio con ' || _a.numero_chasis || ')', auth.uid());

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true,
    'chasis_a', jsonb_build_object('ns', _a.numero_chasis, 'antes', _col_a, 'ahora', _col_b),
    'chasis_b', jsonb_build_object('ns', _b.numero_chasis, 'antes', _col_b, 'ahora', _col_a));
END; $$;

GRANT EXECUTE ON FUNCTION public.intercambiar_color_chasis(uuid, uuid, text) TO authenticated;

-- ============================================================================
-- BLOQUE 10 · Cierre
-- ============================================================================

SELECT public.recalcular_inventario_colores();

DO $$
DECLARE _r record;
BEGIN
  RAISE NOTICE 'KIT-4c · capacidad de color por modelo:';
  FOR _r IN
    SELECT modelo, color, COALESCE(piezas_recibidas,0) AS cap, juegos_usados
      FROM inventario_colores ORDER BY modelo, color
  LOOP
    RAISE NOTICE '  % · % → llegaron %, usados % (libres %)',
      _r.modelo, _r.color, _r.cap, _r.juegos_usados, _r.cap - _r.juegos_usados;
  END LOOP;
END $$;


-- ============================================================================
-- BLOQUE 11 · Comprobación: o quedó todo, o no quedó nada
-- ============================================================================
-- Un COMMIT sin errores no basta como prueba de que el módulo quedó: la última
-- vez el script no llegó a correrse y nadie se enteró hasta que Producción →
-- Configurar unidad dejó de listar chasis. Esto revisa objeto por objeto y
-- tumba la transacción si falta alguno, para que el resultado del SQL editor
-- sea inequívoco.

DO $postflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='inventario_chasis'
                    AND column_name='color_original') THEN
    _faltan := _faltan || 'inventario_chasis.color_original'::text;
  -- El conteo va anidado: si la columna no existe, preguntarle por sus NULLs
  -- reventaría con «column does not exist» y taparía la lista de faltantes.
  ELSIF EXISTS (SELECT 1 FROM public.inventario_chasis WHERE color_original IS NULL) THEN
    _faltan := _faltan || 'hay chasis con color_original en NULL (no se sembró)'::text;
  END IF;
  IF to_regclass('public.bitacora_color') IS NULL THEN
    _faltan := _faltan || 'tabla bitacora_color'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='inventario_colores'
                    AND column_name='piezas_recibidas') THEN
    _faltan := _faltan || 'inventario_colores.piezas_recibidas / piezas_extra / juegos_usados'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='v_stock_modelo_color'
                    AND column_name='capacidad_color') THEN
    _faltan := _faltan || 'v_stock_modelo_color.capacidad_color'::text;
  END IF;
  IF to_regprocedure('public.norm_color(text)') IS NULL THEN
    _faltan := _faltan || 'norm_color(text)'::text; END IF;
  IF to_regprocedure('public.capacidad_color_libre(text,text)') IS NULL THEN
    _faltan := _faltan || 'capacidad_color_libre(text,text)'::text; END IF;
  IF to_regprocedure('public.cambiar_color_chasis(uuid,text,text)') IS NULL THEN
    _faltan := _faltan || 'cambiar_color_chasis(uuid,text,text)'::text; END IF;
  IF to_regprocedure('public.intercambiar_color_chasis(uuid,uuid,text)') IS NULL THEN
    _faltan := _faltan || 'intercambiar_color_chasis(uuid,uuid,text)'::text; END IF;
  IF to_regprocedure('public.ajustar_capacidad_color(text,text,integer,text)') IS NULL THEN
    _faltan := _faltan || 'ajustar_capacidad_color(text,text,integer,text)'::text; END IF;
  IF to_regprocedure('public.configurar_unidad(uuid,uuid,integer,text)') IS NULL THEN
    _faltan := _faltan || 'configurar_unidad(uuid,uuid,integer,text) — el 4º parámetro _color'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = to_regclass('public.inventario_chasis')
                    AND tgname = 'trg_chasis_color_original') THEN
    _faltan := _faltan || 'trigger trg_chasis_color_original'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = to_regclass('public.inventario_chasis')
                    AND tgname = 'trg_verificar_capacidad_color') THEN
    _faltan := _faltan || 'trigger trg_verificar_capacidad_color'::text; END IF;

  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION E'KIT-4c quedó incompleto, se revierte:\n  · %',
      array_to_string(_faltan, E'\n  · ');
  END IF;

  RAISE NOTICE 'KIT-4c · aplicado completo. Producción → Configurar unidad ya puede leer color_original.';
END $postflight$;
