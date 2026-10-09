-- ============================================================================
-- KIT-3 · Configuración manual de unidades, líneas de producto y stock
-- Baseline documental para el SQL editor de Supabase (dmhzhyeivvuliumcgsmm)
-- Fecha: 2026-08-22
--
-- ADVERTENCIA: Igual que el resto de este repo, este script es IDEMPOTENTE
-- pero está pensado para correrse directamente en el SQL editor de Supabase.
-- NO usar `supabase db push` / `db reset` / `migration up`.
--
-- Sustituye la Parte B del prompt KIT-3 original. La importación ya no
-- parea automáticamente (ver 20260821000001 y el fix de "importación sin
-- pareo"): chasis y motores entran como piezas disponibles, y fábrica arma
-- la unidad eligiendo la pareja a mano con configurar_unidad().
-- parear_unidades_contenedor y su función interna se quedan en la base sin
-- usarse; no se borran.
-- ============================================================================


-- ============================================================================
-- BLOQUE 1 · Catálogo de líneas de producto
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.modelos_producto (
  modelo      text PRIMARY KEY,
  linea       text NOT NULL DEFAULT 'motocarro'
              CHECK (linea IN ('motocarro','mototaxi','otro')),
  descripcion text,
  activo      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.modelos_producto ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "autenticados leen modelos_producto" ON public.modelos_producto;
CREATE POLICY "autenticados leen modelos_producto" ON public.modelos_producto
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "admin escribe modelos_producto" ON public.modelos_producto;
CREATE POLICY "admin escribe modelos_producto" ON public.modelos_producto
  FOR ALL TO authenticated
  USING (has_role(auth.uid(),'admin'::app_role))
  WITH CHECK (has_role(auth.uid(),'admin'::app_role));

-- Modelos del embarque 260316DZ. El DZ-K1 es un mototaxi: no entra al flujo
-- de armado de motocarros, pero sí se puede configurar como unidad y
-- remisionar/entregar (ver BLOQUE 4 y la app).
INSERT INTO public.modelos_producto (modelo, linea, descripcion) VALUES
  ('DZ200Q1','motocarro','Motocarro 200cc'),
  ('DZ300Q7','motocarro','Motocarro 300cc'),
  ('DZ-K1','mototaxi','Mototaxi — fuera del flujo de armado de motocarros')
ON CONFLICT (modelo) DO NOTHING;

-- Modelos legacy que ya tienen motocarros creados antes de este catálogo.
-- Se clasifican como motocarro para no sacar del flujo de armado unidades
-- que ya existían.
INSERT INTO public.modelos_producto (modelo, linea, descripcion) VALUES
  ('200cc 2026','motocarro','Modelo legado — motocarro 200cc'),
  ('300cc 2026','motocarro','Modelo legado — motocarro 300cc')
ON CONFLICT (modelo) DO NOTHING;


-- ============================================================================
-- BLOQUE 2 · Normalizar datos ya cargados del embarque 260316DZ
-- ============================================================================
-- [ESTADO VERIFICADO — 2026-08-22, dmhzhyeivvuliumcgsmm]
--   chasis: 125 · motores: 125 · motocarros: 2 (legacy, sin tocar)
--   motores con espacio en el serial: 125 (100%)
--   chasis por modelo/color: DZ200Q1 31 AZUL + 31 BLANCO,
--     DZ300Q7 31 AZUL + 31 BLANCO, DZ-K1 1 ORANGE
-- No se corre el script de carga (KitDrive-Carga-Embarque-260316DZ.sql):
-- duplicaría los motores por la diferencia de espacios en el serial.

-- 2.1 · Colores en inglés que llegaron directo por SQL (sin pasar por
-- normColor/RecibirContenedor).
UPDATE public.inventario_chasis SET color = 'BLANCO'  WHERE upper(color) IN ('WHITE','BLANC');
UPDATE public.inventario_chasis SET color = 'AZUL'    WHERE upper(color) = 'BLUE';
UPDATE public.inventario_chasis SET color = 'NARANJA' WHERE upper(color) = 'ORANGE';

-- 2.2 · Seriales de motor con espacios ("DZ164FML T2M00654"). La captura
-- manual valida con ^[A-Z0-9-]{4,30}$ y un serial con espacio no se puede
-- ni teclear ni buscar. Esto corre ANTES de que fábrica configure unidades:
-- si un motor ya quedó ligado a un motocarro (motocarro_id NOT NULL),
-- cambiarle el serial aquí lo desincroniza de motocarros.ns_motor, así que
-- esos se dejan intactos y sólo se avisa.
DO $$
DECLARE _afectados int;
BEGIN
  UPDATE public.inventario_motor
     SET numero_motor = regexp_replace(upper(numero_motor), '[^A-Z0-9-]', '', 'g')
   WHERE motocarro_id IS NULL
     AND numero_motor <> regexp_replace(upper(numero_motor), '[^A-Z0-9-]', '', 'g');
  GET DIAGNOSTICS _afectados = ROW_COUNT;
  RAISE NOTICE 'Seriales de motor normalizados: %', _afectados;

  IF EXISTS (
    SELECT 1 FROM public.inventario_motor
     WHERE motocarro_id IS NOT NULL
       AND numero_motor <> regexp_replace(upper(numero_motor), '[^A-Z0-9-]', '', 'g')
  ) THEN
    RAISE WARNING 'Hay motores YA CONFIGURADOS en una unidad con el serial sin normalizar. No se tocaron para no desincronizar motocarros.ns_motor — revísalos a mano.';
  END IF;
END $$;

-- 2.3 · inventario_colores se reconstruye desde cero: más simple y confiable
-- que fusionar filas duplicadas (inglés vs español) una por una.
DELETE FROM public.inventario_colores;
INSERT INTO public.inventario_colores (modelo, color, cantidad_disponible, umbral_alerta, updated_at)
SELECT modelo, color, count(*), 3, now()
  FROM public.inventario_chasis
 WHERE motocarro_id IS NULL
 GROUP BY modelo, color;

-- 2.4 · Recontar lo que de verdad tiene ligado cada contenedor.
UPDATE public.contenedores c SET
  total_chasis  = (SELECT count(*) FROM public.inventario_chasis ic WHERE ic.contenedor_id = c.id),
  total_motores = (SELECT count(*) FROM public.inventario_motor  im WHERE im.contenedor_id = c.id);


-- ============================================================================
-- BLOQUE 3 · Sanear seriales en la importación (no sólo en la limpieza)
-- ============================================================================
-- El BLOQUE 2 limpia lo que ya está cargado, pero el problema real está en
-- la importación: si un serial entra con espacios (como los del packing
-- list de motores), se queda así para siempre. Se redefinen las RPC de
-- importación para que el serial entre ya saneado — mismo criterio que
-- NS_REGEX en la captura manual del frontend (^[A-Z0-9-]{4,30}$).

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
    _num := regexp_replace(
              upper(NULLIF(trim(COALESCE(_v->>'numero_chasis', _v->>'frame_number')),'')),
              '[^A-Z0-9-]', '', 'g');
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
    _num := regexp_replace(
              upper(NULLIF(trim(COALESCE(_m->>'numero_motor', _m->>'engine_number')),'')),
              '[^A-Z0-9-]', '', 'g');
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
-- BLOQUE 4 · Configurar unidad (chasis + motor, a mano, por fábrica)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.configurar_unidad(
  _chasis_id uuid, _motor_id uuid, _orden integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _ch record; _mo record; _orden_final int; _moto_id uuid;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede configurar unidades';
  END IF;

  SELECT * INTO _ch FROM inventario_chasis WHERE id = _chasis_id;
  IF _ch IS NULL THEN RAISE EXCEPTION 'Chasis no encontrado'; END IF;
  IF _ch.motocarro_id IS NOT NULL THEN
    RAISE EXCEPTION 'El chasis % ya está asignado a una unidad', _ch.numero_chasis;
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

  UPDATE contenedores c SET total_unidades =
    (SELECT count(*) FROM inventario_chasis ic
      WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
  WHERE c.id = _ch.contenedor_id;

  RETURN jsonb_build_object('ok', true, 'motocarro_id', _moto_id,
    'orden_armado', _orden_final, 'ns_chasis', _ch.numero_chasis,
    'ns_motor', _mo.numero_motor,
    'modelos_coinciden', (_ch.modelo = _mo.modelo));
END; $$;

GRANT EXECUTE ON FUNCTION public.configurar_unidad(uuid, uuid, integer) TO authenticated;


-- ============================================================================
-- BLOQUE 5 · Desconfigurar unidad (corregir un error de captura)
-- ============================================================================

-- [VERIFICADO EN INFORMATION_SCHEMA — 2026-08-20] bitacora_eliminaciones NO
-- existe en la base real (la migración 20260819000010 nunca se aplicó tal
-- cual). No se registra ahí la liberación; si se crea esa tabla más
-- adelante, agregar el INSERT aquí antes del DELETE.
CREATE OR REPLACE FUNCTION public.desconfigurar_unidad(_motocarro_id uuid, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _m record;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede liberar unidades';
  END IF;
  IF _motivo IS NULL OR length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Se requiere un motivo';
  END IF;

  SELECT * INTO _m FROM motocarros WHERE id = _motocarro_id;
  IF _m IS NULL THEN RAISE EXCEPTION 'Unidad no encontrada'; END IF;
  IF _m.remision_id IS NOT NULL THEN
    RAISE EXCEPTION 'La unidad ya está asignada a una remisión; no se puede liberar';
  END IF;
  IF _m.estatus_armado <> 'PENDIENTE' THEN
    RAISE EXCEPTION 'La unidad ya entró a armado; no se puede liberar';
  END IF;

  UPDATE inventario_chasis SET motocarro_id = NULL, estatus = 'disponible',
         fecha_configuracion = NULL WHERE motocarro_id = _motocarro_id;
  UPDATE inventario_motor  SET motocarro_id = NULL, estatus = 'disponible',
         fecha_configuracion = NULL WHERE motocarro_id = _motocarro_id;

  DELETE FROM motocarros WHERE id = _motocarro_id;

  UPDATE contenedores c SET total_unidades =
    (SELECT count(*) FROM inventario_chasis ic
      WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
  WHERE c.id = _m.contenedor_id;

  RETURN jsonb_build_object('ok', true, 'liberada', _m.orden_armado);
END; $$;

GRANT EXECUTE ON FUNCTION public.desconfigurar_unidad(uuid, text) TO authenticated;


-- ============================================================================
-- BLOQUE 6 · Reordenar el armado, con el cambio registrado
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.bitacora_orden_armado (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  motocarro_id   uuid NOT NULL REFERENCES public.motocarros(id) ON DELETE CASCADE,
  orden_anterior integer,
  orden_nuevo    integer NOT NULL,
  motivo         text,
  cambiado_por   uuid REFERENCES auth.users(id),
  cambiado_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.bitacora_orden_armado ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "autenticados leen bitacora_orden_armado" ON public.bitacora_orden_armado;
CREATE POLICY "autenticados leen bitacora_orden_armado" ON public.bitacora_orden_armado
  FOR SELECT TO authenticated USING (true);
-- Sin política de INSERT/UPDATE/DELETE para authenticated: sólo escribe la
-- RPC cambiar_orden_armado, que es SECURITY DEFINER.

CREATE INDEX IF NOT EXISTS idx_bitacora_orden_moto ON public.bitacora_orden_armado (motocarro_id, cambiado_at DESC);

-- orden_armado no tiene CHECK > 0 en la base real, así que el -1 temporal
-- del intercambio no truena. [VERIFICADO — 2026-08-20]
CREATE OR REPLACE FUNCTION public.cambiar_orden_armado(
  _motocarro_id uuid, _orden_nuevo integer, _motivo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _actual int; _ocupa uuid; _estatus_actual estatus_armado;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede cambiar el orden';
  END IF;
  IF _orden_nuevo IS NULL OR _orden_nuevo < 1 THEN
    RAISE EXCEPTION 'Orden inválido';
  END IF;

  SELECT orden_armado, estatus_armado INTO _actual, _estatus_actual
    FROM motocarros WHERE id = _motocarro_id;
  IF _actual IS NULL THEN RAISE EXCEPTION 'Unidad no encontrada'; END IF;
  IF _estatus_actual NOT IN ('PENDIENTE','EN_PROCESO') THEN
    RAISE EXCEPTION 'La unidad ya entró a armado; no se puede reordenar';
  END IF;
  IF _actual = _orden_nuevo THEN
    RETURN jsonb_build_object('ok', true, 'sin_cambio', true);
  END IF;

  -- Si el orden destino está ocupado, se INTERCAMBIAN y se registran los dos
  SELECT id INTO _ocupa FROM motocarros WHERE orden_armado = _orden_nuevo;

  IF _ocupa IS NOT NULL THEN
    UPDATE motocarros SET orden_armado = -1, updated_at = now() WHERE id = _motocarro_id;
    UPDATE motocarros SET orden_armado = _actual, updated_at = now() WHERE id = _ocupa;
    UPDATE motocarros SET orden_armado = _orden_nuevo, updated_at = now() WHERE id = _motocarro_id;

    INSERT INTO bitacora_orden_armado (motocarro_id, orden_anterior, orden_nuevo, motivo, cambiado_por)
    VALUES (_ocupa, _orden_nuevo, _actual, COALESCE(_motivo,'intercambio'), auth.uid());
  ELSE
    UPDATE motocarros SET orden_armado = _orden_nuevo, updated_at = now() WHERE id = _motocarro_id;
  END IF;

  INSERT INTO bitacora_orden_armado (motocarro_id, orden_anterior, orden_nuevo, motivo, cambiado_por)
  VALUES (_motocarro_id, _actual, _orden_nuevo, _motivo, auth.uid());

  RETURN jsonb_build_object('ok', true, 'orden_anterior', _actual,
    'orden_nuevo', _orden_nuevo, 'intercambio_con', _ocupa);
END; $$;

GRANT EXECUTE ON FUNCTION public.cambiar_orden_armado(uuid, integer, text) TO authenticated;


-- ============================================================================
-- BLOQUE 7 · Nomenclatura comercial (código de fábrica vs. nombre comercial)
-- ============================================================================
-- El embarque trae DZ200Q1 / DZ300Q7 (código de fábrica, lo que viene en la
-- mercancía y el packing list) y las remisiones piden "200cc 2026" /
-- "300cc 2026" (nombre comercial, lo que habla ventas). Se resuelve en el
-- catálogo — nadie cambia cómo captura ni cómo habla.
--
-- Reglas de despliegue (las aplica el frontend, este bloque sólo da los
-- datos y corrige el cruce):
--   Fábrica (Producción, Inventario, configurar unidad): código de fábrica
--     con el comercial como secundario — "DZ300Q7 · 300cc 2026".
--   Ventas y dirección (Remisiones, Entregas, Clientes, Dashboard, Stock):
--     sólo el nombre comercial.
--   Un modelo sin nombre_comercial cae de vuelta al código.
--
-- No se reescriben remisiones existentes: el mapeo vive en el catálogo y en
-- el cruce de asignar_chasis_remision, no en los datos de remision_items.

ALTER TABLE public.modelos_producto ADD COLUMN IF NOT EXISTS nombre_comercial text;

UPDATE public.modelos_producto SET nombre_comercial = CASE modelo
  WHEN 'DZ200Q1' THEN '200cc 2026'
  WHEN 'DZ300Q7' THEN '300cc 2026'
  ELSE nombre_comercial END;

-- Los legacy ya son su propio nombre comercial.
UPDATE public.modelos_producto SET nombre_comercial = modelo WHERE nombre_comercial IS NULL;

-- El cruce unidad ↔ remisión compara por nombre comercial + color, no por
-- código de fábrica: hoy hay demanda pendiente pidiendo "300cc 2026" y las
-- unidades configuradas por fábrica traen "DZ300Q7". Si el modelo no está en
-- el catálogo (o no tiene nombre_comercial), cae de vuelta al código — mismo
-- comportamiento que antes de este bloque para lo que no está clasificado.
CREATE OR REPLACE FUNCTION public.asignar_chasis_remision(
  _remision_id uuid, _cantidad integer, _color text DEFAULT NULL::text, _modelo text DEFAULT NULL::text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  asignados integer := 0;
BEGIN
  IF NOT (
    public.has_role(auth.uid(), 'admin') OR
    EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = _remision_id AND r.vendedor_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'No autorizado para asignar chasis a esta remisión';
  END IF;

  WITH candidatos AS (
    SELECT m.id
      FROM public.motocarros m
      LEFT JOIN public.modelos_producto mp ON mp.modelo = m.modelo
     WHERE m.remision_id IS NULL
       AND m.estatus_armado IN ('PENDIENTE','EN_PROCESO','ARMADO','LISTO')
       AND (_color  IS NULL OR upper(m.color)  = upper(_color))
       AND (_modelo IS NULL OR upper(COALESCE(mp.nombre_comercial, m.modelo)) = upper(_modelo))
     ORDER BY m.orden_armado ASC
     LIMIT _cantidad
     FOR UPDATE SKIP LOCKED
  )
  UPDATE public.motocarros m
  SET remision_id = _remision_id,
      estatus_entrega = CASE
        WHEN m.estatus_entrega = 'NO_APLICA' THEN 'PROGRAMADA'
        ELSE m.estatus_entrega
      END
  FROM candidatos c
  WHERE m.id = c.id;

  GET DIAGNOSTICS asignados = ROW_COUNT;

  UPDATE public.remisiones r
  SET estatus = CASE
    WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) >= r.total_unidades_solicitadas
      THEN 'COMPLETA'::estatus_remision
    WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) > 0
      THEN 'PARCIAL'::estatus_remision
    ELSE 'NUEVA'::estatus_remision
  END
  WHERE r.id = _remision_id;

  RETURN asignados;
END;
$$;

GRANT EXECUTE ON FUNCTION public.asignar_chasis_remision(uuid, integer, text, text) TO authenticated;
