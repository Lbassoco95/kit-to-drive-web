-- ============================================================================
-- Cargar motocarro ya armado desde asignación manual
-- Baseline documental para el SQL editor de Supabase (dmhzhyeivvuliumcgsmm).
-- Fecha: 2026-08-28
--
-- ADVERTENCIA: Este proyecto no usa supabase db push / db reset / migration up.
-- Aplicar directamente en el SQL editor de Supabase.
--
-- Permite registrar un motocarro físicamente armado (chasis + motor) que no
-- existe aún en el sistema, y asignarlo directamente a una remisión. Se usa
-- cuando se encuentran unidades ya armadas que nunca se dieron de alta.
-- ============================================================================

-- ============================================================================
-- 1. Crear motocarro ya armado y asignarlo a una remisión
-- ============================================================================
CREATE OR REPLACE FUNCTION public.crear_motocarro_ya_armado(
  _ns_chasis text,
  _ns_motor text,
  _modelo text,        -- nombre comercial o código interno de fábrica
  _color text,
  _remision_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _ch text; _mo text; _col text; _modelo_input text; _modelo_interno text;
  _chasis_id uuid; _motor_id uuid; _moto_id uuid; _orden_final int;
  _remision record; _ch_existente record; _mo_existente record;
  _usados int; _vin int;
BEGIN
  IF NOT (has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin o fábrica puede crear unidades ya armadas';
  END IF;

  -- Saneo de seriales (mismo criterio que capturar_seriales_unidad)
  _ch := NULLIF(regexp_replace(upper(COALESCE(_ns_chasis,'')), '[^A-Z0-9-]', '', 'g'), '');
  _mo := NULLIF(regexp_replace(upper(COALESCE(_ns_motor,'')), '[^A-Z0-9-]', '', 'g'), '');
  _col := public.norm_color(_color);
  _modelo_input := upper(trim(COALESCE(_modelo, '')));

  IF _ch IS NULL OR _mo IS NULL THEN
    RAISE EXCEPTION 'Se requiere NS chasis y NS motor para registrar un motocarro ya armado';
  END IF;
  IF _ch !~ '^[A-Z0-9-]{4,30}$' THEN
    RAISE EXCEPTION 'NS chasis inválido: usa de 4 a 30 caracteres (letras, números o guion)';
  END IF;
  IF _mo !~ '^[A-Z0-9-]{4,30}$' THEN
    RAISE EXCEPTION 'NS motor inválido: usa de 4 a 30 caracteres (letras, números o guion)';
  END IF;
  IF _modelo_input = '' THEN
    RAISE EXCEPTION 'Se requiere el modelo del motocarro';
  END IF;
  IF _col = '' THEN
    RAISE EXCEPTION 'Se requiere el color del motocarro';
  END IF;

  -- Resolver modelo comercial a código interno de fábrica
  SELECT modelo INTO _modelo_interno
    FROM modelos_producto
   WHERE upper(COALESCE(nombre_comercial, '')) = _modelo_input
      OR upper(modelo) = _modelo_input
   ORDER BY (upper(modelo) = _modelo_input) DESC
   LIMIT 1;
  IF _modelo_interno IS NULL THEN
    RAISE EXCEPTION 'No se encontró el modelo % en el catálogo. Regístralo en Modelos de producto.', _modelo;
  END IF;

  -- Validar remisión destino
  SELECT * INTO _remision FROM remisiones WHERE id = _remision_id;
  IF _remision IS NULL THEN
    RAISE EXCEPTION 'Remisión no encontrada';
  END IF;
  IF _remision.estatus NOT IN ('NUEVA', 'PARCIAL') THEN
    RAISE EXCEPTION 'La remisión % no está disponible para asignar unidades', _remision.folio_remision;
  END IF;

  -- Los seriales no pueden repetirse en otro motocarro
  IF EXISTS (SELECT 1 FROM motocarros WHERE ns_chasis = _ch) THEN
    RAISE EXCEPTION 'El NS chasis % ya está registrado en otra unidad', _ch;
  END IF;
  IF EXISTS (SELECT 1 FROM motocarros WHERE ns_motor = _mo) THEN
    RAISE EXCEPTION 'El NS motor % ya está registrado en otra unidad', _mo;
  END IF;

  -- ── Chasis ────────────────────────────────────────────────────────────────
  SELECT * INTO _ch_existente FROM inventario_chasis WHERE numero_chasis = _ch;
  IF _ch_existente.id IS NOT NULL THEN
    IF _ch_existente.motocarro_id IS NOT NULL THEN
      RAISE EXCEPTION 'El chasis % ya es parte de otra unidad', _ch;
    END IF;
    IF public.chasis_bloqueado(_ch_existente.id) THEN
      RAISE EXCEPTION 'El chasis % está bloqueado por una incidencia; resuélvela antes de asignarlo', _ch;
    END IF;
    _chasis_id := _ch_existente.id;
  ELSE
    -- Reservar capacidad de color para el chasis nuevo, si no el trigger
    -- _verificar_capacidad_color tumba la transacción.
    SELECT count(*) INTO _usados
      FROM inventario_chasis WHERE modelo = _modelo_interno AND upper(color) = _col;
    SELECT count(*) INTO _vin
      FROM inventario_chasis
     WHERE modelo = _modelo_interno AND upper(COALESCE(color_original, color)) = _col;
    PERFORM public.ajustar_capacidad_color(
      _modelo_interno, _col,
      GREATEST(_usados + 1, _vin),
      'Carga de motocarro ya armado (sin VIN previo)'
    );

    INSERT INTO inventario_chasis (numero_chasis, modelo, color, estatus)
    VALUES (_ch, _modelo_interno, _col, 'disponible')
    RETURNING id INTO _chasis_id;
  END IF;

  -- ── Motor ─────────────────────────────────────────────────────────────────
  SELECT * INTO _mo_existente FROM inventario_motor WHERE numero_motor = _mo;
  IF _mo_existente.id IS NOT NULL THEN
    IF _mo_existente.motocarro_id IS NOT NULL THEN
      RAISE EXCEPTION 'El motor % ya es parte de otra unidad', _mo;
    END IF;
    _motor_id := _mo_existente.id;
  ELSE
    INSERT INTO inventario_motor (numero_motor, modelo, estatus)
    VALUES (_mo, _modelo_interno, 'disponible')
    RETURNING id INTO _motor_id;
  END IF;

  -- Orden de armado siguiente
  _orden_final := (SELECT COALESCE(max(orden_armado), 0) + 1 FROM motocarros);

  -- Crear el motocarro ya armado, asignado directamente a la remisión
  INSERT INTO motocarros (
    orden_armado, modelo, color, ns_chasis, ns_motor,
    contenedor_id, estatus_armado, estatus_entrega,
    remision_id, fecha_real_armado
  )
  VALUES (
    _orden_final, _modelo_interno, _col, _ch, _mo,
    _ch_existente.contenedor_id, 'ARMADO', 'PROGRAMADA',
    _remision_id, CURRENT_DATE
  )
  RETURNING id INTO _moto_id;

  -- Vincular las piezas del inventario a la unidad nueva
  UPDATE inventario_chasis
     SET motocarro_id = _moto_id, estatus = 'configurado', fecha_configuracion = now()
   WHERE id = _chasis_id;
  UPDATE inventario_motor
     SET motocarro_id = _moto_id, estatus = 'configurado', fecha_configuracion = now()
   WHERE id = _motor_id;

  -- Recalcular total del contenedor si el chasis viene de uno
  IF _ch_existente.contenedor_id IS NOT NULL THEN
    UPDATE contenedores c SET total_unidades =
      (SELECT count(*) FROM inventario_chasis ic
        WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
     WHERE c.id = _ch_existente.contenedor_id;
  END IF;

  -- Actualizar estatus de la remisión según cuántas unidades ya tiene
  UPDATE remisiones
     SET estatus = CASE
       WHEN (SELECT count(*) FROM motocarros mm WHERE mm.remision_id = _remision_id) >= total_unidades_solicitadas
         THEN 'COMPLETA'::estatus_remision
       ELSE 'PARCIAL'::estatus_remision
     END
   WHERE id = _remision_id;

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object(
    'ok', true,
    'motocarro_id', _moto_id,
    'orden_armado', _orden_final,
    'ns_chasis', _ch,
    'ns_motor', _mo,
    'modelo', _modelo_interno,
    'color', _col,
    'chasis_existente', (_ch_existente.id IS NOT NULL),
    'motor_existente', (_mo_existente.id IS NOT NULL)
  );
END; $$;

GRANT EXECUTE ON FUNCTION public.crear_motocarro_ya_armado(text, text, text, text, uuid) TO authenticated;

COMMENT ON FUNCTION public.crear_motocarro_ya_armado(text, text, text, text, uuid) IS
  'Crea un motocarro físicamente ya armado (con chasis y motor) que no estaba '
  'dado de alta en el sistema, y lo asigna a una remisión. Usar desde la asignación '
  'manual cuando se encuentren unidades armadas sin registro previo.';
