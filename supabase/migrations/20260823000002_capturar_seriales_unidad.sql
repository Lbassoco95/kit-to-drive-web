-- ============================================================================
-- KIT-4b · Capturar seriales ligando la pieza del inventario
--
-- El hueco: KIT-4 exige NS chasis y NS motor para cerrar el proceso, pero la
-- captura manual (Producción → Editar) escribía nada más en motocarros. Si el
-- capturista teclea un serial que SÍ está en el embarque, la pieza se queda en
-- 'disponible' y fábrica puede volver a configurarla en otra unidad —
-- inventario contado doble, que es justo lo que KIT-4 venía a arreglar.
--
-- Caso real que lo detonó (dmhzhyeivvuliumcgsmm, 2026-08-23): la unidad #1
-- (300cc 2026 AZUL, REM-002, cliente A410) está en LISTO desde el 14/07 sin
-- ninguno de los dos seriales.
--
-- Fecha: 2026-08-23
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.capturar_seriales_unidad(
  _motocarro_id uuid,
  _ns_chasis    text DEFAULT NULL,   -- NULL = no cambiar
  _ns_motor     text DEFAULT NULL)   -- NULL = no cambiar
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _m record; _ch text; _mo text;
  _ic record; _im record;
  _ch_vinculado boolean := false; _mo_vinculado boolean := false;
  _ch_detenido  boolean := false;
  _liberados text[] := '{}';
  _otra int;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede capturar seriales';
  END IF;

  SELECT * INTO _m FROM motocarros WHERE id = _motocarro_id;
  IF _m IS NULL THEN RAISE EXCEPTION 'Unidad no encontrada'; END IF;

  -- Mismo saneo que la importación: mayúsculas, sin espacios ni signos.
  _ch := NULLIF(regexp_replace(upper(COALESCE(_ns_chasis,'')), '[^A-Z0-9-]', '', 'g'), '');
  _mo := NULLIF(regexp_replace(upper(COALESCE(_ns_motor ,'')), '[^A-Z0-9-]', '', 'g'), '');

  IF _ch IS NULL AND _mo IS NULL THEN
    RAISE EXCEPTION 'No se recibió ningún serial que capturar';
  END IF;
  IF _ch IS NOT NULL AND _ch !~ '^[A-Z0-9-]{4,30}$' THEN
    RAISE EXCEPTION 'NS chasis inválido: usa de 4 a 30 caracteres (letras, números o guion)';
  END IF;
  IF _mo IS NOT NULL AND _mo !~ '^[A-Z0-9-]{4,30}$' THEN
    RAISE EXCEPTION 'NS motor inválido: usa de 4 a 30 caracteres (letras, números o guion)';
  END IF;

  -- Un serial no puede estar en dos unidades: el UNIQUE de motocarros lo
  -- impide, pero el mensaje crudo de Postgres no dice en cuál está.
  IF _ch IS NOT NULL THEN
    SELECT orden_armado INTO _otra FROM motocarros WHERE ns_chasis = _ch AND id <> _motocarro_id;
    IF _otra IS NOT NULL THEN
      RAISE EXCEPTION 'El NS chasis % ya está capturado en la unidad #%', _ch, _otra;
    END IF;
  END IF;
  IF _mo IS NOT NULL THEN
    SELECT orden_armado INTO _otra FROM motocarros WHERE ns_motor = _mo AND id <> _motocarro_id;
    IF _otra IS NOT NULL THEN
      RAISE EXCEPTION 'El NS motor % ya está capturado en la unidad #%', _mo, _otra;
    END IF;
  END IF;

  -- ── Chasis ────────────────────────────────────────────────────────────────
  IF _ch IS NOT NULL THEN
    SELECT * INTO _ic FROM inventario_chasis WHERE numero_chasis = _ch;

    IF _ic.id IS NOT NULL AND _ic.motocarro_id IS NOT NULL AND _ic.motocarro_id <> _motocarro_id THEN
      RAISE EXCEPTION 'El chasis % ya es parte de otra unidad (#%): libérala antes de capturarlo aquí',
        _ch, (SELECT orden_armado FROM motocarros WHERE id = _ic.motocarro_id);
    END IF;

    -- Corregir un serial mal capturado: la pieza vieja vuelve al pool.
    IF _m.ns_chasis IS NOT NULL AND _m.ns_chasis <> _ch THEN
      UPDATE inventario_chasis SET motocarro_id = NULL, fecha_configuracion = NULL
       WHERE motocarro_id = _motocarro_id AND numero_chasis <> _ch;
      IF FOUND THEN _liberados := array_append(_liberados, _m.ns_chasis); END IF;
    END IF;
  END IF;

  -- ── Motor ─────────────────────────────────────────────────────────────────
  IF _mo IS NOT NULL THEN
    SELECT * INTO _im FROM inventario_motor WHERE numero_motor = _mo;

    IF _im.id IS NOT NULL AND _im.motocarro_id IS NOT NULL AND _im.motocarro_id <> _motocarro_id THEN
      RAISE EXCEPTION 'El motor % ya es parte de otra unidad (#%): libérala antes de capturarlo aquí',
        _mo, (SELECT orden_armado FROM motocarros WHERE id = _im.motocarro_id);
    END IF;

    IF _m.ns_motor IS NOT NULL AND _m.ns_motor <> _mo THEN
      UPDATE inventario_motor SET motocarro_id = NULL, estatus = 'disponible', fecha_configuracion = NULL
       WHERE motocarro_id = _motocarro_id AND numero_motor <> _mo;
      IF FOUND THEN _liberados := array_append(_liberados, _m.ns_motor); END IF;
    END IF;
  END IF;

  UPDATE motocarros
     SET ns_chasis = COALESCE(_ch, ns_chasis),
         ns_motor  = COALESCE(_mo, ns_motor),
         updated_at = now()
   WHERE id = _motocarro_id;

  -- Ligar las piezas que sí existen en inventario. Si el serial es de un
  -- embarque viejo (no está en inventario_chasis/motor), no hay nada que
  -- ligar: la unidad queda con su serial y ya.
  IF _ch IS NOT NULL AND _ic.id IS NOT NULL THEN
    UPDATE inventario_chasis
       SET motocarro_id = _motocarro_id,
           fecha_configuracion = COALESCE(fecha_configuracion, now())
     WHERE id = _ic.id;
    -- El estatus lo decide la incidencia, si hay: un chasis en garantía no
    -- vuelve a 'configurado' nada más porque se capturó su serial.
    PERFORM public._sincronizar_estatus_chasis(_ic.id);
    _ch_vinculado := true;
    _ch_detenido  := public.chasis_bloqueado(_ic.id);
  END IF;

  IF _mo IS NOT NULL AND _im.id IS NOT NULL THEN
    UPDATE inventario_motor
       SET motocarro_id = _motocarro_id, estatus = 'configurado',
           fecha_configuracion = COALESCE(fecha_configuracion, now())
     WHERE id = _im.id;
    _mo_vinculado := true;
  END IF;

  -- Cuadrar el contenedor de las piezas ligadas y los conteos por color.
  UPDATE contenedores c SET total_unidades =
    (SELECT count(*) FROM inventario_chasis ic
      WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
   WHERE c.id IN (_ic.contenedor_id, _m.contenedor_id) AND c.id IS NOT NULL;

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object(
    'ok', true,
    'orden_armado', _m.orden_armado,
    'ns_chasis', COALESCE(_ch, _m.ns_chasis),
    'ns_motor',  COALESCE(_mo, _m.ns_motor),
    'chasis_vinculado', _ch_vinculado,
    'motor_vinculado',  _mo_vinculado,
    'chasis_detenido',  _ch_detenido,
    'piezas_liberadas', to_jsonb(_liberados),
    'cierra_proceso', (COALESCE(_ch, _m.ns_chasis) IS NOT NULL
                   AND COALESCE(_mo, _m.ns_motor)  IS NOT NULL));
END; $$;

GRANT EXECUTE ON FUNCTION public.capturar_seriales_unidad(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.capturar_seriales_unidad(uuid, text, text) IS
  'Captura NS chasis / NS motor de una unidad y liga la pieza del inventario '
  'cuando el serial existe, para que no se quede contada como disponible. '
  'Úsala en lugar de un UPDATE directo a motocarros.';
