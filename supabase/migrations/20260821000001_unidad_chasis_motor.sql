-- ============================================================================
-- KIT-1 · Unidad = chasis + motor (1:1)
-- Baseline del esquema real de producción (dmhzhyeivvuliumcgsmm)
-- Fecha: 2026-08-21
--
-- ADVERTENCIA: Este script es IDEMPOTENTE pero está pensado para correrse
-- directamente en el SQL editor de Supabase. NO usar `supabase db push`:
-- este proyecto nunca aplicó migraciones por CLI, y el CLI intentaría crear
-- objetos que ya existen.
-- ============================================================================


-- ============================================================================
-- BLOQUE 2 · Esquema: llevar el inventario al modelo correcto
-- ============================================================================

-- 2.1 · contenedor_id pasa de TEXT a uuid con FK real.
-- Las tablas están vacías; el CASE es defensivo por si alguien importa algo
-- entre que lees esto y lo corres (un folio no casteable queda en NULL, no truena).
-- El cast va condicionado a que la columna siga siendo texto: si ya se corrió
-- este script, contenedor_id es uuid y el `~*` truena con «operator does not
-- exist: uuid ~* unknown», que en el SQL editor revierte todo el archivo.
DO $conv$
DECLARE _t text;
BEGIN
  FOREACH _t IN ARRAY ARRAY['inventario_chasis','inventario_motor'] LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name = _t
                  AND column_name='contenedor_id' AND data_type <> 'uuid') THEN
      EXECUTE format(
        'ALTER TABLE public.%I ALTER COLUMN contenedor_id TYPE uuid USING '
        '(CASE WHEN contenedor_id ~* ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'' '
        'THEN contenedor_id::uuid END)', _t);
    END IF;
  END LOOP;
END $conv$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inventario_chasis_contenedor_fk') THEN
    ALTER TABLE public.inventario_chasis
      ADD CONSTRAINT inventario_chasis_contenedor_fk
      FOREIGN KEY (contenedor_id) REFERENCES public.contenedores(id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inventario_motor_contenedor_fk') THEN
    ALTER TABLE public.inventario_motor
      ADD CONSTRAINT inventario_motor_contenedor_fk
      FOREIGN KEY (contenedor_id) REFERENCES public.contenedores(id) ON DELETE CASCADE;
  END IF;
END $$;

-- 2.2 · Columnas que la app necesita y no existen
ALTER TABLE public.inventario_chasis
  ADD COLUMN IF NOT EXISTS motocarro_id        uuid REFERENCES public.motocarros(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS fecha_importacion   timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS fecha_configuracion timestamptz,
  ADD COLUMN IF NOT EXISTS notas               text,
  ADD COLUMN IF NOT EXISTS updated_at          timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.inventario_motor
  ADD COLUMN IF NOT EXISTS motocarro_id        uuid REFERENCES public.motocarros(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS fecha_importacion   timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS fecha_configuracion timestamptz,
  ADD COLUMN IF NOT EXISTS notas               text,
  ADD COLUMN IF NOT EXISTS updated_at          timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.contenedores
  ADD COLUMN IF NOT EXISTS total_chasis  integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_motores integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS estatus_carga text    NOT NULL DEFAULT 'completa';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contenedores_estatus_carga_chk') THEN
    ALTER TABLE public.contenedores
      ADD CONSTRAINT contenedores_estatus_carga_chk
      CHECK (estatus_carga IN ('completa','incompleta'));
  END IF;
END $$;

COMMENT ON COLUMN public.contenedores.total_unidades IS
  'Unidades (chasis + motor pareados). NO es chasis + motores.';

-- 2.3 · El 1:1 a nivel de base. Sólo estos dos índices son nuevos:
-- motocarros_ns_chasis_key y motocarros_ns_motor_key YA EXISTEN como UNIQUE
-- totales, así que no se recrean (el repo creaba versiones parciales redundantes).
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventario_chasis_motocarro
  ON public.inventario_chasis (motocarro_id) WHERE motocarro_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventario_motor_motocarro
  ON public.inventario_motor (motocarro_id) WHERE motocarro_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_inventario_chasis_contenedor ON public.inventario_chasis (contenedor_id);
CREATE INDEX IF NOT EXISTS idx_inventario_motor_contenedor  ON public.inventario_motor  (contenedor_id);

-- 2.4 · Triggers de updated_at (set_updated_at ya existe en la base)
DROP TRIGGER IF EXISTS trg_inventario_chasis_updated ON public.inventario_chasis;
CREATE TRIGGER trg_inventario_chasis_updated BEFORE UPDATE ON public.inventario_chasis
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_inventario_motor_updated ON public.inventario_motor;
CREATE TRIGGER trg_inventario_motor_updated BEFORE UPDATE ON public.inventario_motor
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ============================================================================
-- BLOQUE 3 · Limpiar el contenedor fantasma
-- ============================================================================

DELETE FROM public.contenedores
WHERE (folio_contenedor IS NULL OR trim(folio_contenedor) = '')
  AND NOT EXISTS (SELECT 1 FROM motocarros m WHERE m.contenedor_id = contenedores.id)
  AND NOT EXISTS (SELECT 1 FROM inventario_chasis ic WHERE ic.contenedor_id = contenedores.id)
  AND NOT EXISTS (SELECT 1 FROM inventario_motor im WHERE im.contenedor_id = contenedores.id);

-- Impedir que vuelva a entrar un folio vacío
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contenedores_folio_no_vacio_chk') THEN
    ALTER TABLE public.contenedores
      ADD CONSTRAINT contenedores_folio_no_vacio_chk
      CHECK (folio_contenedor IS NOT NULL AND length(trim(folio_contenedor)) > 0);
  END IF;
END $$;

-- Cuadrar los contenedores buenos con lo que de verdad tienen ligado
UPDATE public.contenedores c SET
  total_chasis   = COALESCE((SELECT count(*) FROM inventario_chasis ic WHERE ic.contenedor_id = c.id),0),
  total_motores  = COALESCE((SELECT count(*) FROM inventario_motor  im WHERE im.contenedor_id = c.id),0),
  total_unidades = COALESCE((SELECT count(*) FROM motocarros m WHERE m.contenedor_id = c.id),0);


-- ============================================================================
-- BLOQUE 4 · Contador de colores
-- ============================================================================

CREATE OR REPLACE FUNCTION public.incrementar_inventario_color(
  _modelo text, _color text, _cantidad integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO inventario_colores (modelo, color, cantidad_disponible, umbral_alerta, updated_at)
  VALUES (_modelo, upper(_color), _cantidad, 3, now())
  ON CONFLICT (modelo, color) DO UPDATE
    SET cantidad_disponible = inventario_colores.cantidad_disponible + _cantidad,
        updated_at = now();
END; $$;

CREATE OR REPLACE FUNCTION public.decrementar_inventario_color(
  _modelo text, _color text, _cantidad integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE inventario_colores
     SET cantidad_disponible = GREATEST(0, cantidad_disponible - _cantidad),
         updated_at = now()
   WHERE modelo = _modelo AND color = upper(_color);
END; $$;

GRANT EXECUTE ON FUNCTION public.incrementar_inventario_color(text,text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decrementar_inventario_color(text,text,integer) TO authenticated;


-- ============================================================================
-- BLOQUE 5 · Importación de chasis
-- ============================================================================

DROP FUNCTION IF EXISTS public.importar_vins_inventario(uuid, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.importar_vins_inventario(
  _contenedor_id uuid, _folio_contenedor text, _modelo text, _vins jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _v jsonb; _num text; _col text; _mod text; _es_nuevo boolean; _new_id uuid;
  _insertados int := 0; _actualizados int := 0; _invalidos int := 0;
  _ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede importar VINs';
  END IF;
  IF _contenedor_id IS NULL THEN RAISE EXCEPTION 'ID de contenedor requerido'; END IF;
  IF NOT EXISTS (SELECT 1 FROM contenedores WHERE id = _contenedor_id) THEN
    RAISE EXCEPTION 'Contenedor no encontrado';
  END IF;

  IF _folio_contenedor IS NOT NULL AND length(trim(_folio_contenedor)) > 0 THEN
    UPDATE contenedores SET folio_contenedor = trim(_folio_contenedor) WHERE id = _contenedor_id;
  END IF;

  FOR _v IN SELECT * FROM jsonb_array_elements(_vins) LOOP
    _num := upper(NULLIF(trim(COALESCE(_v->>'numero_chasis', _v->>'frame_number')),''));
    _col := upper(COALESCE(NULLIF(trim(_v->>'color'),''), 'SIN COLOR'));
    _mod := COALESCE(NULLIF(trim(COALESCE(_v->>'modelo', _v->>'model_no')),''), _modelo, '200cc 2025');

    IF _num IS NULL OR length(_num) < 4 THEN
      _invalidos := _invalidos + 1;
      CONTINUE;
    END IF;

    INSERT INTO inventario_chasis (numero_chasis, contenedor_id, modelo, color, estatus)
    VALUES (_num, _contenedor_id, _mod, _col, 'disponible')
    ON CONFLICT (numero_chasis) DO UPDATE
      SET contenedor_id = _contenedor_id, modelo = _mod, color = _col
    RETURNING id, (xmax = 0) INTO _new_id, _es_nuevo;

    _ids := array_append(_ids, _new_id);

    IF _es_nuevo THEN
      _insertados := _insertados + 1;
      PERFORM public.incrementar_inventario_color(_mod, _col, 1);
    ELSE
      _actualizados := _actualizados + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'contenedor_id', _contenedor_id,
    'insertados', _insertados, 'actualizados', _actualizados,
    'invalidos', _invalidos, 'chasis_ids', _ids);
END; $$;

GRANT EXECUTE ON FUNCTION public.importar_vins_inventario(uuid, text, text, jsonb) TO authenticated;


-- ============================================================================
-- BLOQUE 6 · Importación de motores
-- ============================================================================

DROP FUNCTION IF EXISTS public.importar_motores_inventario(text, jsonb);
DROP FUNCTION IF EXISTS public.importar_motores_inventario(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.importar_motores_inventario(
  _contenedor_id uuid, _modelo text, _motores jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _m jsonb; _num text; _mod text; _es_nuevo boolean;
  _insertados int := 0; _actualizados int := 0; _invalidos int := 0;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede importar motores';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM contenedores WHERE id = _contenedor_id) THEN
    RAISE EXCEPTION 'Contenedor no encontrado';
  END IF;

  FOR _m IN SELECT * FROM jsonb_array_elements(_motores) LOOP
    _num := upper(NULLIF(trim(COALESCE(_m->>'numero_motor', _m->>'engine_number')),''));
    _mod := COALESCE(NULLIF(trim(COALESCE(_m->>'modelo', _m->>'model_no')),''), _modelo, '200cc 2025');

    IF _num IS NULL OR length(_num) < 4 THEN
      _invalidos := _invalidos + 1;
      CONTINUE;
    END IF;

    INSERT INTO inventario_motor (numero_motor, contenedor_id, modelo, estatus)
    VALUES (_num, _contenedor_id, _mod, 'disponible')
    ON CONFLICT (numero_motor) DO UPDATE
      SET contenedor_id = _contenedor_id, modelo = _mod
    RETURNING (xmax = 0) INTO _es_nuevo;

    IF _es_nuevo THEN _insertados := _insertados + 1;
    ELSE _actualizados := _actualizados + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'insertados', _insertados,
    'actualizados', _actualizados, 'invalidos', _invalidos);
END; $$;

GRANT EXECUTE ON FUNCTION public.importar_motores_inventario(uuid, text, jsonb) TO authenticated;


-- ============================================================================
-- BLOQUE 7 · El pareo 1:1
-- ============================================================================

CREATE OR REPLACE FUNCTION public._parear_unidades_contenedor_internal(_contenedor_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _n_chasis int; _n_motores int; _unidades int; _pareadas int := 0;
  _r record; _moto_id uuid; _orden int;
  _sin_motor text[] := '{}'; _sin_chasis text[] := '{}';
BEGIN
  SELECT count(*) INTO _n_chasis  FROM inventario_chasis WHERE contenedor_id = _contenedor_id;
  SELECT count(*) INTO _n_motores FROM inventario_motor  WHERE contenedor_id = _contenedor_id;

  SELECT COALESCE(max(orden_armado),0) INTO _orden FROM motocarros;

  FOR _r IN
    WITH ch AS (
      SELECT id, numero_chasis, modelo, color,
             row_number() OVER (ORDER BY created_at, numero_chasis) AS rn
        FROM inventario_chasis
       WHERE contenedor_id = _contenedor_id AND motocarro_id IS NULL
    ), mo AS (
      SELECT id, numero_motor,
             row_number() OVER (ORDER BY created_at, numero_motor) AS rn
        FROM inventario_motor
       WHERE contenedor_id = _contenedor_id AND motocarro_id IS NULL
    )
    SELECT ch.id AS chasis_id, ch.numero_chasis, ch.modelo, ch.color,
           mo.id AS motor_id, mo.numero_motor
      FROM ch JOIN mo ON mo.rn = ch.rn
     ORDER BY ch.rn
  LOOP
    _orden := _orden + 1;

    INSERT INTO motocarros (orden_armado, modelo, color, ns_chasis, ns_motor,
                            contenedor_id, estatus_armado, estatus_entrega)
    VALUES (_orden, _r.modelo, _r.color, _r.numero_chasis, _r.numero_motor,
            _contenedor_id, 'PENDIENTE', 'NO_APLICA')
    ON CONFLICT (ns_chasis) DO UPDATE
      SET ns_motor = EXCLUDED.ns_motor,
          contenedor_id = EXCLUDED.contenedor_id,
          updated_at = now()
    RETURNING id INTO _moto_id;

    UPDATE inventario_chasis SET motocarro_id = _moto_id, estatus = 'configurado',
           fecha_configuracion = now() WHERE id = _r.chasis_id;
    UPDATE inventario_motor  SET motocarro_id = _moto_id, estatus = 'configurado',
           fecha_configuracion = now() WHERE id = _r.motor_id;

    _pareadas := _pareadas + 1;
  END LOOP;

  SELECT count(*) INTO _unidades FROM inventario_chasis
   WHERE contenedor_id = _contenedor_id AND motocarro_id IS NOT NULL;

  SELECT COALESCE(array_agg(numero_chasis), '{}') INTO _sin_motor
    FROM inventario_chasis WHERE contenedor_id = _contenedor_id AND motocarro_id IS NULL;
  SELECT COALESCE(array_agg(numero_motor), '{}') INTO _sin_chasis
    FROM inventario_motor  WHERE contenedor_id = _contenedor_id AND motocarro_id IS NULL;

  UPDATE contenedores SET
    total_chasis   = _n_chasis,
    total_motores  = _n_motores,
    total_unidades = _unidades,
    estatus_carga  = CASE WHEN array_length(_sin_motor,1) IS NULL
                           AND array_length(_sin_chasis,1) IS NULL
                          THEN 'completa' ELSE 'incompleta' END
  WHERE id = _contenedor_id;

  RETURN jsonb_build_object('ok', true,
    'unidades', _unidades, 'unidades_nuevas', _pareadas,
    'chasis_recibidos', _n_chasis, 'motores_recibidos', _n_motores,
    'chasis_sin_motor', _sin_motor, 'motores_sin_chasis', _sin_chasis,
    'completa', (array_length(_sin_motor,1) IS NULL AND array_length(_sin_chasis,1) IS NULL));
END; $$;

-- La interna NO se expone: es SECURITY DEFINER sin chequeo de rol.
REVOKE ALL ON FUNCTION public._parear_unidades_contenedor_internal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._parear_unidades_contenedor_internal(uuid) FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.parear_unidades_contenedor(_contenedor_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede parear unidades';
  END IF;
  RETURN public._parear_unidades_contenedor_internal(_contenedor_id);
END; $$;

GRANT EXECUTE ON FUNCTION public.parear_unidades_contenedor(uuid) TO authenticated;
