-- Recoge en mostrador, forma de pago (efectivo / transferencia) y descuento
-- por pieza o general. Idempotente.

ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS forma_pago TEXT,
  ADD COLUMN IF NOT EXISTS descuento_pct NUMERIC(5,2) NOT NULL DEFAULT 0;

ALTER TABLE public.remision_refaccion_items
  ADD COLUMN IF NOT EXISTS descuento_pct NUMERIC(5,2) NOT NULL DEFAULT 0;

ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_tipo_envio_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_tipo_envio_check
  CHECK (tipo_envio IS NULL OR tipo_envio IN ('paqueteria', 'directo', 'recoge'));

ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_forma_pago_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_forma_pago_check
  CHECK (forma_pago IS NULL OR forma_pago IN ('efectivo', 'transferencia'));

ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_descuento_pct_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_descuento_pct_check
  CHECK (descuento_pct >= 0 AND descuento_pct <= 100);

ALTER TABLE public.remision_refaccion_items DROP CONSTRAINT IF EXISTS remision_refaccion_items_descuento_pct_check;
ALTER TABLE public.remision_refaccion_items
  ADD CONSTRAINT remision_refaccion_items_descuento_pct_check
  CHECK (descuento_pct >= 0 AND descuento_pct <= 100);

CREATE OR REPLACE FUNCTION public.crear_remision_refacciones(
  _cliente_id UUID,
  _notas TEXT,
  _nombre_vendedor TEXT,
  _items JSONB,
  _envio JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prod UUID;
  v_cant INTEGER;
  v_stock INTEGER;
  v_disp INTEGER;
  v_codigo TEXT;
  v_id UUID;
  v_folio TEXT;
  v_seq INTEGER;
  v_nombre TEXT;
  v_lineas INTEGER := 0;
  v_tipo text;
  v_pago text;
  v_forma text;
  v_dir text;
  v_desc numeric;
  v_vendedor uuid;
  v_rol text;
BEGIN
  IF NOT public.puede_capturar_refacciones() THEN
    RAISE EXCEPTION 'No tienes permiso para levantar remisiones de refacciones';
  END IF;
  IF _cliente_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = _cliente_id) THEN
    RAISE EXCEPTION 'Selecciona un cliente';
  END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'Agrega al menos una refacción';
  END IF;

  v_tipo := nullif(trim(_envio->>'tipo_envio'), '');
  v_pago := nullif(trim(_envio->>'tipo_pago'), '');
  v_forma := coalesce(nullif(trim(_envio->>'forma_pago'), ''), 'efectivo');
  v_dir := nullif(trim(_envio->>'direccion'), '');
  v_desc := coalesce((_envio->>'descuento_pct')::numeric, 0);
  IF v_tipo IS NULL OR v_tipo NOT IN ('paqueteria', 'directo', 'recoge') THEN
    RAISE EXCEPTION 'Indica si va por paquetería, entrega directa o la recoge el cliente';
  END IF;
  IF v_tipo <> 'recoge' AND (v_dir IS NULL OR char_length(v_dir) < 8) THEN
    RAISE EXCEPTION 'La dirección de entrega es obligatoria para logística';
  END IF;
  IF v_pago IS NULL OR v_pago NOT IN ('anticipado', 'contra_entrega') THEN
    RAISE EXCEPTION 'Indica si el pago es anticipado o contra entrega';
  END IF;
  IF v_forma NOT IN ('efectivo', 'transferencia') THEN
    RAISE EXCEPTION 'La forma de pago es efectivo o transferencia';
  END IF;
  IF v_desc < 0 OR v_desc > 100 THEN
    RAISE EXCEPTION 'El descuento general va de 0 a 100';
  END IF;

  v_rol := public.rol_comercial();
  BEGIN
    v_vendedor := nullif(trim(_envio->>'vendedor_id'), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_vendedor := NULL;
  END;
  IF v_rol = 'operador' OR v_vendedor IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = v_vendedor AND coalesce(p.activo, true)) THEN
    v_vendedor := auth.uid();
  END IF;

  PERFORM 1
  FROM public.almacen_refacciones_productos p
  WHERE p.id IN (
    SELECT (e.value->>'producto_id')::uuid
    FROM jsonb_array_elements(_items) AS e(value)
    WHERE nullif(e.value->>'producto_id', '') IS NOT NULL
  )
  ORDER BY p.id
  FOR UPDATE;

  FOR v_prod, v_cant IN
    SELECT (e.value->>'producto_id')::uuid,
           sum((e.value->>'cantidad')::integer)
    FROM jsonb_array_elements(_items) AS e(value)
    GROUP BY 1
  LOOP
    IF v_prod IS NULL THEN
      RAISE EXCEPTION 'Hay una partida sin producto';
    END IF;
    IF v_cant IS NULL OR v_cant < 1 THEN
      RAISE EXCEPTION 'La cantidad debe ser mayor a cero';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(_items) e
      WHERE (e.value->>'producto_id')::uuid = v_prod
        AND coalesce((e.value->>'descuento_pct')::numeric, 0) NOT BETWEEN 0 AND 100
    ) THEN
      RAISE EXCEPTION 'El descuento de la pieza va de 0 a 100';
    END IF;

    SELECT p.stock, p.codigo_nuevo
      INTO v_stock, v_codigo
    FROM public.almacen_refacciones_productos p
    WHERE p.id = v_prod
      AND p.visible_venta;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Hay una refacción que no está disponible para venta';
    END IF;
    IF coalesce(v_stock, 0) < 0 THEN
      RAISE EXCEPTION 'El inventario de % está en negativo. Corrígelo antes de vender.', v_codigo;
    END IF;

    v_disp := GREATEST(v_stock - public.stock_bloqueado_producto(v_prod), 0);
    IF v_cant > v_disp THEN
      RAISE EXCEPTION
        'No hay existencia suficiente de %: pediste % y quedan % disponibles (ya apartadas en otras remisiones).',
        v_codigo, v_cant, v_disp;
    END IF;
    v_lineas := v_lineas + 1;
  END LOOP;

  IF v_lineas = 0 THEN
    RAISE EXCEPTION 'Agrega al menos una refacción';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('remisiones_refacciones')::bigint);
  SELECT coalesce(max((regexp_match(folio, '^RF-(\d+)$'))[1]::int), 0) + 1
    INTO v_seq
  FROM public.remisiones_refacciones;
  v_folio := 'RF-' || lpad(v_seq::text, 5, '0');

  SELECT coalesce(nullif(trim(_nombre_vendedor), ''), p.nombre_completo)
    INTO v_nombre
  FROM public.profiles p
  WHERE p.id = v_vendedor;
  IF v_nombre IS NULL THEN
    v_nombre := nullif(trim(_nombre_vendedor), '');
  END IF;

  INSERT INTO public.remisiones_refacciones (
    folio, cliente_id, vendedor_id, nombre_vendedor, fecha_remision, notas,
    etapa, area_actual, abierta, created_by,
    tipo_envio, direccion_entrega, contacto_entrega, telefono_entrega,
    tipo_pago, forma_pago, descuento_pct, pagado
  ) VALUES (
    v_folio, _cliente_id, v_vendedor, v_nombre, CURRENT_DATE, nullif(trim(_notas), ''),
    'almacen', 'almacen', true, auth.uid(),
    v_tipo, v_dir,
    nullif(trim(_envio->>'contacto'), ''),
    nullif(trim(_envio->>'telefono'), ''),
    v_pago, v_forma, v_desc, false
  )
  RETURNING id INTO v_id;

  INSERT INTO public.remision_refaccion_items (
    remision_id, producto_id, codigo_nuevo, codigo_antiguo, descripcion,
    precio_unitario, descuento_pct, cantidad, cantidad_bloqueada, cantidad_surtida,
    cantidad_faltante, estatus
  )
  SELECT
    v_id,
    p.id,
    p.codigo_nuevo,
    p.codigo_antiguo,
    coalesce(nullif(p.descripcion_corta, ''), p.descripcion),
    p.precio,
    ped.descuento_pct,
    ped.cantidad,
    ped.cantidad,
    0,
    0,
    'bloqueada'
  FROM (
    SELECT (e.value->>'producto_id')::uuid AS producto_id,
           sum((e.value->>'cantidad')::integer) AS cantidad,
           max(coalesce((e.value->>'descuento_pct')::numeric, 0)) AS descuento_pct
    FROM jsonb_array_elements(_items) AS e(value)
    GROUP BY 1
  ) ped
  JOIN public.almacen_refacciones_productos p ON p.id = ped.producto_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES
    (v_id, 'almacen', 'ventas', 'captura',
     'Remisión levantada. Envío ' || v_tipo || '. Pago ' || v_forma || '. Existencia apartada.',
     auth.uid()),
    (v_id, 'almacen', 'almacen', 'enviada_almacen',
     'Pasó a Almacén para surtir o reportar faltante.',
     auth.uid());

  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;

REVOKE ALL ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB, JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION public.actualizar_envio_remision_refaccion(
  _remision_id UUID,
  _envio JSONB
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
  v_rol text;
  v_tipo text;
  v_dir text;
  v_forma text;
  v_desc numeric;
  v_item jsonb;
BEGIN
  IF NOT public.puede_capturar_refacciones() THEN
    RAISE EXCEPTION 'Sólo ventas puede actualizar el envío';
  END IF;

  SELECT * INTO v_row FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa IN ('cancelada', 'entregada') OR v_row.entregada_at IS NOT NULL THEN
    RAISE EXCEPTION 'Esta remisión ya no se puede modificar';
  END IF;

  v_rol := public.rol_comercial();
  IF NOT (v_rol IN ('global', 'supervisor') OR v_row.vendedor_id = auth.uid() OR v_row.created_by = auth.uid()) THEN
    RAISE EXCEPTION 'No puedes actualizar esta remisión';
  END IF;

  v_tipo := coalesce(nullif(trim(_envio->>'tipo_envio'), ''), v_row.tipo_envio);
  v_dir := coalesce(nullif(trim(_envio->>'direccion'), ''), v_row.direccion_entrega);
  v_forma := coalesce(nullif(trim(_envio->>'forma_pago'), ''), v_row.forma_pago, 'efectivo');
  v_desc := coalesce((_envio->>'descuento_pct')::numeric, v_row.descuento_pct, 0);
  IF v_tipo IS NULL OR v_tipo NOT IN ('paqueteria', 'directo', 'recoge') THEN
    RAISE EXCEPTION 'Indica si va por paquetería, entrega directa o la recoge el cliente';
  END IF;
  IF v_tipo <> 'recoge' AND (v_dir IS NULL OR char_length(v_dir) < 8) THEN
    RAISE EXCEPTION 'La dirección de entrega es obligatoria para logística';
  END IF;
  IF v_forma NOT IN ('efectivo', 'transferencia') THEN
    RAISE EXCEPTION 'La forma de pago es efectivo o transferencia';
  END IF;
  IF v_desc < 0 OR v_desc > 100 THEN
    RAISE EXCEPTION 'El descuento general va de 0 a 100';
  END IF;

  UPDATE public.remisiones_refacciones
  SET tipo_envio = v_tipo,
      direccion_entrega = CASE WHEN v_tipo = 'recoge' THEN nullif(trim(coalesce(v_dir, '')), '') ELSE v_dir END,
      contacto_entrega = coalesce(nullif(trim(_envio->>'contacto'), ''), contacto_entrega),
      telefono_entrega = coalesce(nullif(trim(_envio->>'telefono'), ''), telefono_entrega),
      tipo_pago = coalesce(nullif(trim(_envio->>'tipo_pago'), ''), tipo_pago),
      forma_pago = v_forma,
      descuento_pct = v_desc
  WHERE id = _remision_id;

  IF jsonb_typeof(_envio->'descuentos') = 'array' THEN
    FOR v_item IN SELECT value FROM jsonb_array_elements(_envio->'descuentos')
    LOOP
      IF coalesce((v_item->>'descuento_pct')::numeric, 0) NOT BETWEEN 0 AND 100 THEN
        RAISE EXCEPTION 'El descuento de la pieza va de 0 a 100';
      END IF;
      UPDATE public.remision_refaccion_items
      SET descuento_pct = coalesce((v_item->>'descuento_pct')::numeric, 0)
      WHERE id = (v_item->>'item_id')::uuid
        AND remision_id = _remision_id;
    END LOOP;
  END IF;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, v_row.etapa, 'ventas', 'actualizar_envio',
    'Ventas actualizó envío ' || v_tipo || ', pago ' || v_forma || ' y descuento ' || v_desc || '%.',
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.actualizar_envio_remision_refaccion(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.actualizar_envio_remision_refaccion(UUID, JSONB) TO authenticated;

NOTIFY pgrst, 'reload schema';
