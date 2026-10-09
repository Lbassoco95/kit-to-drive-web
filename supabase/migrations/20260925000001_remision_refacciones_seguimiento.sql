-- ============================================================================
-- Seguimiento de remisiones de refacciones
-- ----------------------------------------------------------------------------
-- Ventas deja listo el envío (paquetería o entrega directa, con dirección).
-- Almacén surte o reporta faltante: el aviso le llega a Ventas, a quien la
-- levantó, al vendedor asignado y a quien la registró. Logística la mueve
-- hasta entregada. Finanzas marca si está pagada. El historial queda por
-- cliente. Ningún inventario (refacciones ni motocarros) puede quedar
-- negativo.
--
-- Idempotente. Pensado para el SQL editor de Supabase, no para db push.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.remisiones_refacciones') IS NULL THEN
    _faltan := _faltan || 'tabla remisiones_refacciones (corre 20260923000001)'::text;
  END IF;
  IF to_regclass('public.avisos') IS NULL THEN
    _faltan := _faltan || 'tabla avisos (corre 20260903000001)'::text;
  END IF;
  IF to_regclass('public.almacen_refacciones_productos') IS NULL THEN
    _faltan := _faltan || 'tabla almacen_refacciones_productos'::text;
  END IF;
  IF to_regclass('public.inventario_colores') IS NULL THEN
    _faltan := _faltan || 'tabla inventario_colores'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;

-- Datos de envío, pago y entrega --------------------------------------------
ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS tipo_envio TEXT,
  ADD COLUMN IF NOT EXISTS direccion_entrega TEXT,
  ADD COLUMN IF NOT EXISTS contacto_entrega TEXT,
  ADD COLUMN IF NOT EXISTS telefono_entrega TEXT,
  ADD COLUMN IF NOT EXISTS paqueteria TEXT,
  ADD COLUMN IF NOT EXISTS guia_envio TEXT,
  ADD COLUMN IF NOT EXISTS tipo_pago TEXT,
  ADD COLUMN IF NOT EXISTS pagado BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pagado_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS pagado_por UUID REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS nota_pago TEXT,
  ADD COLUMN IF NOT EXISTS lista_logistica_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS entregada_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS entregada_por UUID REFERENCES public.profiles(id);

ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_etapa_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_etapa_check
  CHECK (etapa IN ('almacen', 'contingencia', 'surtida', 'logistica', 'entregada', 'cancelada'));

ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_area_actual_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_area_actual_check
  CHECK (area_actual IN ('ventas', 'almacen', 'logistica'));

ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_tipo_envio_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_tipo_envio_check
  CHECK (tipo_envio IS NULL OR tipo_envio IN ('paqueteria', 'directo'));

ALTER TABLE public.remisiones_refacciones DROP CONSTRAINT IF EXISTS remisiones_refacciones_tipo_pago_check;
ALTER TABLE public.remisiones_refacciones
  ADD CONSTRAINT remisiones_refacciones_tipo_pago_check
  CHECK (tipo_pago IS NULL OR tipo_pago IN ('anticipado', 'contra_entrega'));

ALTER TABLE public.remision_refaccion_eventos DROP CONSTRAINT IF EXISTS remision_refaccion_eventos_area_check;
ALTER TABLE public.remision_refaccion_eventos
  ADD CONSTRAINT remision_refaccion_eventos_area_check
  CHECK (area IN ('ventas', 'almacen', 'logistica', 'finanzas'));

-- Lo que ya estaba surtido pasa a logística: almacén terminó, falta el envío.
UPDATE public.remisiones_refacciones
SET etapa = 'logistica',
    area_actual = 'logistica',
    lista_logistica_at = coalesce(lista_logistica_at, updated_at, now())
WHERE etapa = 'surtida'
  AND entregada_at IS NULL;

-- Avisos personales (el de área sigue en area_destino) ----------------------
ALTER TABLE public.avisos
  ADD COLUMN IF NOT EXISTS destinatario_id UUID REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS remision_refaccion_id UUID REFERENCES public.remisiones_refacciones(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_avisos_destinatario
  ON public.avisos (destinatario_id, created_at DESC)
  WHERE destinatario_id IS NOT NULL AND visto_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_avisos_remision_refaccion
  ON public.avisos (remision_refaccion_id);

DROP POLICY IF EXISTS "leer avisos de mi area" ON public.avisos;
CREATE POLICY "leer avisos de mi area" ON public.avisos
  FOR SELECT TO authenticated
  USING (
    public.recibe_avisos_de(area_destino)
    OR creado_por = auth.uid()
    OR destinatario_id = auth.uid()
  );

-- Lectura: logística, finanzas, quien la registró y el vendedor -------------
CREATE OR REPLACE FUNCTION public.puede_leer_remision_refaccion(
  _remision_id UUID,
  _user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _rol text;
  _area text;
  _vendedor uuid;
  _creador uuid;
BEGIN
  IF _user_id IS NULL OR _remision_id IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.activo = false) THEN
    RETURN false;
  END IF;

  SELECT r.vendedor_id, r.created_by INTO _vendedor, _creador
  FROM public.remisiones_refacciones r
  WHERE r.id = _remision_id;
  IF NOT FOUND THEN RETURN false; END IF;

  IF public.puede_ver_almacen_refacciones(_user_id) THEN RETURN true; END IF;
  IF _vendedor = _user_id OR _creador = _user_id THEN RETURN true; END IF;

  _rol := public.rol_comercial(_user_id);
  IF _rol IN ('global', 'supervisor') THEN RETURN true; END IF;

  SELECT ur.area::text INTO _area
  FROM public.user_roles ur
  WHERE ur.user_id = _user_id
  LIMIT 1;
  RETURN _area IN ('direccion', 'administracion', 'almacen_logistica', 'comercial');
END;
$$;

-- Etapa: almacén termina y el pedido sigue a logística, luego a entregada ---
CREATE OR REPLACE FUNCTION public.recalcular_etapa_remision_refaccion(_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _abierta boolean;
  _hay_faltante boolean;
  _hay_surtida boolean;
  _hay_sin boolean;
  _entregada timestamptz;
  _etapa text;
  _area text;
BEGIN
  SELECT entregada_at INTO _entregada
  FROM public.remisiones_refacciones
  WHERE id = _id;

  SELECT
    bool_or(estatus IN ('bloqueada', 'faltante')),
    bool_or(estatus = 'faltante'),
    bool_or(cantidad_surtida > 0),
    bool_or(estatus = 'sin_existencia')
  INTO _abierta, _hay_faltante, _hay_surtida, _hay_sin
  FROM public.remision_refaccion_items
  WHERE remision_id = _id;

  IF NOT FOUND OR _abierta IS NULL THEN
    _etapa := 'cancelada';
    _area := 'ventas';
    _abierta := false;
  ELSIF _abierta AND _hay_faltante THEN
    _etapa := 'contingencia';
    _area := 'almacen';
  ELSIF _abierta THEN
    _etapa := 'almacen';
    _area := 'almacen';
  ELSIF coalesce(_hay_surtida, false) AND _entregada IS NOT NULL THEN
    _etapa := 'entregada';
    _area := 'logistica';
    _abierta := false;
  ELSIF coalesce(_hay_surtida, false) THEN
    _etapa := 'logistica';
    _area := 'logistica';
    _abierta := false;
  ELSIF coalesce(_hay_sin, false) THEN
    _etapa := 'contingencia';
    _area := 'almacen';
    _abierta := false;
  ELSE
    _etapa := 'cancelada';
    _area := 'ventas';
    _abierta := false;
  END IF;

  UPDATE public.remisiones_refacciones
  SET etapa = _etapa,
      area_actual = _area,
      abierta = coalesce(_abierta, false),
      lista_logistica_at = CASE
        WHEN _etapa IN ('logistica', 'entregada') THEN coalesce(lista_logistica_at, now())
        ELSE lista_logistica_at
      END
  WHERE id = _id;
END;
$$;

-- Aviso de faltante: área de ventas y las personas del pedido ---------------
CREATE OR REPLACE FUNCTION public.avisar_faltante_refaccion(
  _remision_id UUID,
  _item_id UUID,
  _detalle TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_folio text;
  v_vendedor uuid;
  v_creador uuid;
  v_nombre text;
  v_codigo text;
  v_persona uuid;
BEGIN
  SELECT r.folio, r.vendedor_id, r.created_by, v_item.codigo_nuevo
    INTO v_folio, v_vendedor, v_creador, v_codigo
  FROM public.remisiones_refacciones r
  JOIN public.remision_refaccion_items v_item ON v_item.remision_id = r.id
  WHERE r.id = _remision_id
    AND v_item.id = _item_id;

  SELECT nombre_completo INTO v_nombre FROM public.profiles WHERE id = auth.uid();

  INSERT INTO public.avisos (
    area_destino, tipo, titulo, cuerpo, folio_remision, datos,
    creado_por, nombre_creador, remision_refaccion_id
  ) VALUES (
    'comercial',
    'faltante_refaccion',
    'Faltante en ' || coalesce(v_folio, 'remisión de refacciones'),
    _detalle,
    v_folio,
    jsonb_build_object(
      'remision_refaccion_id', _remision_id,
      'item_id', _item_id,
      'codigo', v_codigo,
      'ruta', '/remisiones-refacciones'
    ),
    auth.uid(),
    v_nombre,
    _remision_id
  );

  FOREACH v_persona IN ARRAY ARRAY[v_vendedor, v_creador]
  LOOP
    CONTINUE WHEN v_persona IS NULL;
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.avisos a
      WHERE a.remision_refaccion_id = _remision_id
        AND a.destinatario_id = v_persona
        AND a.tipo = 'faltante_refaccion'
        AND a.visto_at IS NULL
        AND a.created_at > now() - interval '1 minute'
    );
    INSERT INTO public.avisos (
      area_destino, tipo, titulo, cuerpo, folio_remision, datos,
      creado_por, nombre_creador, destinatario_id, remision_refaccion_id
    ) VALUES (
      'comercial',
      'faltante_refaccion',
      'Faltante en ' || coalesce(v_folio, 'remisión de refacciones'),
      _detalle || ' Actualiza la remisión: suelta la partida o corrige el pedido.',
      v_folio,
      jsonb_build_object(
        'remision_refaccion_id', _remision_id,
        'item_id', _item_id,
        'codigo', v_codigo,
        'para', v_persona,
        'ruta', '/remisiones-refacciones'
      ),
      auth.uid(),
      v_nombre,
      v_persona,
      _remision_id
    );
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.avisar_faltante_refaccion(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.avisar_faltante_refaccion(UUID, UUID, TEXT) TO authenticated;

-- Alta con envío. La firma anterior se reemplaza. ---------------------------
DROP FUNCTION IF EXISTS public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB);

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
  v_dir text;
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
  v_dir := nullif(trim(_envio->>'direccion'), '');
  IF v_tipo IS NULL OR v_tipo NOT IN ('paqueteria', 'directo') THEN
    RAISE EXCEPTION 'Indica si se envía por paquetería o se entrega directo';
  END IF;
  IF v_dir IS NULL OR char_length(v_dir) < 8 THEN
    RAISE EXCEPTION 'La dirección de entrega es obligatoria para logística';
  END IF;
  IF v_pago IS NULL OR v_pago NOT IN ('anticipado', 'contra_entrega') THEN
    RAISE EXCEPTION 'Indica si el pago es anticipado o contra entrega';
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
    tipo_envio, direccion_entrega, contacto_entrega, telefono_entrega, tipo_pago, pagado
  ) VALUES (
    v_folio, _cliente_id, v_vendedor, v_nombre, CURRENT_DATE, nullif(trim(_notas), ''),
    'almacen', 'almacen', true, auth.uid(),
    v_tipo, v_dir,
    nullif(trim(_envio->>'contacto'), ''),
    nullif(trim(_envio->>'telefono'), ''),
    v_pago, false
  )
  RETURNING id INTO v_id;

  INSERT INTO public.remision_refaccion_items (
    remision_id, producto_id, codigo_nuevo, codigo_antiguo, descripcion,
    precio_unitario, cantidad, cantidad_bloqueada, cantidad_surtida,
    cantidad_faltante, estatus
  )
  SELECT
    v_id,
    p.id,
    p.codigo_nuevo,
    p.codigo_antiguo,
    coalesce(nullif(p.descripcion_corta, ''), p.descripcion),
    p.precio,
    ped.cantidad,
    ped.cantidad,
    0,
    0,
    'bloqueada'
  FROM (
    SELECT (e.value->>'producto_id')::uuid AS producto_id,
           sum((e.value->>'cantidad')::integer) AS cantidad
    FROM jsonb_array_elements(_items) AS e(value)
    GROUP BY 1
  ) ped
  JOIN public.almacen_refacciones_productos p ON p.id = ped.producto_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES
    (v_id, 'almacen', 'ventas', 'captura',
     'Remisión levantada. Envío ' || v_tipo || ' a: ' || v_dir || '. Existencia apartada.',
     auth.uid()),
    (v_id, 'almacen', 'almacen', 'enviada_almacen',
     'Pasó a Almacén para surtir o reportar faltante. Logística ya tiene la dirección.',
     auth.uid());

  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;

REVOKE ALL ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB, JSONB) TO authenticated;

-- La pantalla anterior llamaba con 4 argumentos. Mientras no se recarga,
-- el error dice qué falta en vez de «function does not exist».
CREATE OR REPLACE FUNCTION public.crear_remision_refacciones(
  _cliente_id UUID,
  _notas TEXT,
  _nombre_vendedor TEXT,
  _items JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'Recarga la página: la remisión de refacciones ahora pide envío, dirección y forma de pago.';
END;
$$;

REVOKE ALL ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB) TO authenticated;

-- Ventas corrige el envío mientras no esté entregada ------------------------
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
  IF v_tipo IS NULL OR v_tipo NOT IN ('paqueteria', 'directo') THEN
    RAISE EXCEPTION 'Indica si se envía por paquetería o se entrega directo';
  END IF;
  IF v_dir IS NULL OR char_length(v_dir) < 8 THEN
    RAISE EXCEPTION 'La dirección de entrega es obligatoria para logística';
  END IF;

  UPDATE public.remisiones_refacciones
  SET tipo_envio = v_tipo,
      direccion_entrega = v_dir,
      contacto_entrega = coalesce(nullif(trim(_envio->>'contacto'), ''), contacto_entrega),
      telefono_entrega = coalesce(nullif(trim(_envio->>'telefono'), ''), telefono_entrega),
      tipo_pago = coalesce(nullif(trim(_envio->>'tipo_pago'), ''), tipo_pago)
  WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, v_row.etapa, 'ventas', 'actualizar_envio',
    'Ventas actualizó el envío: ' || v_tipo || ' · ' || v_dir,
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.actualizar_envio_remision_refaccion(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.actualizar_envio_remision_refaccion(UUID, JSONB) TO authenticated;

-- Reportar faltante: avisa a ventas y a las personas del pedido -------------
CREATE OR REPLACE FUNCTION public.reportar_faltante_refaccion(
  _item_id UUID,
  _cantidad INTEGER,
  _nota TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item public.remision_refaccion_items%ROWTYPE;
  v_detalle text;
BEGIN
  IF NOT public.puede_operar_almacen_refacciones() THEN
    RAISE EXCEPTION 'Sólo almacén puede reportar un faltante';
  END IF;
  IF nullif(trim(_nota), '') IS NULL OR char_length(trim(_nota)) < 3 THEN
    RAISE EXCEPTION 'Describe qué pasó con la pieza (mínimo 3 caracteres)';
  END IF;

  SELECT * INTO v_item
  FROM public.remision_refaccion_items
  WHERE id = _item_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la partida';
  END IF;
  IF v_item.estatus NOT IN ('bloqueada', 'faltante') THEN
    RAISE EXCEPTION 'Esta partida ya no está en revisión';
  END IF;
  IF _cantidad IS NULL OR _cantidad < 1 OR _cantidad > v_item.cantidad_bloqueada THEN
    RAISE EXCEPTION 'La cantidad faltante no es válida';
  END IF;

  UPDATE public.remision_refaccion_items
  SET cantidad_faltante = _cantidad,
      estatus = 'faltante',
      nota_almacen = trim(_nota)
  WHERE id = _item_id;

  v_detalle := 'Almacén reporta faltante de ' || _cantidad || ' de ' || v_item.codigo_nuevo
    || ' (' || v_item.descripcion || '). Sigue apartada. ' || trim(_nota);

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, item_id, etapa, area, accion, detalle, usuario_id
  ) VALUES (
    v_item.remision_id, _item_id, 'contingencia', 'almacen', 'reportar_faltante',
    v_detalle, auth.uid()
  );

  PERFORM public.avisar_faltante_refaccion(v_item.remision_id, _item_id, v_detalle);
  PERFORM public.recalcular_etapa_remision_refaccion(v_item.remision_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.confirmar_sin_existencia_refaccion(_item_id UUID, _nota TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item public.remision_refaccion_items%ROWTYPE;
  v_stock INTEGER;
  v_soltar INTEGER;
  v_baja INTEGER;
  v_bloqueada INTEGER;
  v_estatus TEXT;
  v_detalle text;
BEGIN
  IF NOT public.puede_operar_almacen_refacciones() THEN
    RAISE EXCEPTION 'Sólo almacén puede confirmar que no hay existencia';
  END IF;
  IF nullif(trim(_nota), '') IS NULL OR char_length(trim(_nota)) < 3 THEN
    RAISE EXCEPTION 'Describe por qué ya no hay existencia (mínimo 3 caracteres)';
  END IF;

  SELECT * INTO v_item
  FROM public.remision_refaccion_items
  WHERE id = _item_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la partida';
  END IF;
  IF v_item.estatus NOT IN ('bloqueada', 'faltante') THEN
    RAISE EXCEPTION 'Esta partida ya no está en revisión';
  END IF;

  v_soltar := LEAST(
    CASE WHEN v_item.cantidad_faltante > 0 THEN v_item.cantidad_faltante ELSE v_item.cantidad_bloqueada END,
    v_item.cantidad_bloqueada
  );
  IF v_soltar < 1 THEN
    RAISE EXCEPTION 'No hay piezas apartadas que confirmar';
  END IF;

  SELECT stock INTO v_stock
  FROM public.almacen_refacciones_productos
  WHERE id = v_item.producto_id
  FOR UPDATE;

  v_baja := LEAST(v_soltar, GREATEST(coalesce(v_stock, 0), 0));
  IF v_baja > 0 THEN
    IF coalesce(v_stock, 0) - v_baja < 0 THEN
      RAISE EXCEPTION 'El inventario de refacciones no puede quedar en negativo';
    END IF;
    UPDATE public.almacen_refacciones_productos
    SET stock = stock - v_baja
    WHERE id = v_item.producto_id;

    INSERT INTO public.almacen_refacciones_movimientos (
      producto_id, tipo, cantidad, precio_unitario, cliente_id, notas, created_by
    )
    SELECT v_item.producto_id, 'ajuste', -v_baja, v_item.precio_unitario, r.cliente_id,
           'Ajuste por faltante de remisión ' || r.folio || '. ' || trim(_nota),
           auth.uid()
    FROM public.remisiones_refacciones r
    WHERE r.id = v_item.remision_id;
  END IF;

  v_bloqueada := v_item.cantidad_bloqueada - v_soltar;
  v_estatus := CASE
    WHEN v_bloqueada = 0 AND v_item.cantidad_surtida > 0 THEN 'surtida'
    WHEN v_bloqueada = 0 THEN 'sin_existencia'
    ELSE 'bloqueada'
  END;

  UPDATE public.remision_refaccion_items
  SET cantidad_bloqueada = v_bloqueada,
      cantidad_faltante = 0,
      estatus = v_estatus,
      nota_almacen = trim(_nota)
  WHERE id = _item_id;

  v_detalle := 'Almacén confirma que no hay ' || v_soltar || ' de ' || v_item.codigo_nuevo
    || '. Existencia corregida en ' || v_baja || '. ' || trim(_nota);

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, item_id, area, accion, detalle, usuario_id
  ) VALUES (
    v_item.remision_id, _item_id, 'almacen', 'confirmar_sin_existencia',
    v_detalle, auth.uid()
  );

  PERFORM public.avisar_faltante_refaccion(v_item.remision_id, _item_id, v_detalle);
  PERFORM public.recalcular_etapa_remision_refaccion(v_item.remision_id);
END;
$$;

-- Liberar no puede dejar el stock debajo de cero ----------------------------
CREATE OR REPLACE FUNCTION public.liberar_refaccion_remision(_item_id UUID, _cantidad INTEGER)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item public.remision_refaccion_items%ROWTYPE;
  v_stock INTEGER;
  v_folio TEXT;
  v_bloqueada INTEGER;
  v_faltante INTEGER;
  v_estatus TEXT;
BEGIN
  IF NOT public.puede_operar_almacen_refacciones() THEN
    RAISE EXCEPTION 'Sólo almacén puede liberar una remisión de refacciones';
  END IF;

  SELECT * INTO v_item
  FROM public.remision_refaccion_items
  WHERE id = _item_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la partida';
  END IF;
  IF v_item.estatus NOT IN ('bloqueada', 'faltante') THEN
    RAISE EXCEPTION 'Esta partida ya no tiene piezas apartadas';
  END IF;
  IF _cantidad IS NULL OR _cantidad < 1 OR _cantidad > v_item.cantidad_bloqueada THEN
    RAISE EXCEPTION 'La cantidad a liberar no es válida';
  END IF;

  SELECT stock INTO v_stock
  FROM public.almacen_refacciones_productos
  WHERE id = v_item.producto_id
  FOR UPDATE;

  IF coalesce(v_stock, 0) < _cantidad THEN
    RAISE EXCEPTION
      'La existencia (%) no cubre lo que se quiere liberar (%). Reporta el faltante. El inventario no puede quedar en negativo.',
      coalesce(v_stock, 0), _cantidad;
  END IF;

  UPDATE public.almacen_refacciones_productos
  SET stock = stock - _cantidad
  WHERE id = v_item.producto_id
    AND stock >= _cantidad;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El inventario de refacciones no puede quedar en negativo';
  END IF;

  v_bloqueada := v_item.cantidad_bloqueada - _cantidad;
  v_faltante := GREATEST(0, v_item.cantidad_faltante - _cantidad);
  v_estatus := CASE
    WHEN v_bloqueada = 0 THEN 'surtida'
    WHEN v_faltante > 0 THEN 'faltante'
    ELSE 'bloqueada'
  END;

  UPDATE public.remision_refaccion_items
  SET cantidad_bloqueada = v_bloqueada,
      cantidad_surtida = cantidad_surtida + _cantidad,
      cantidad_faltante = v_faltante,
      estatus = v_estatus
  WHERE id = _item_id;

  SELECT folio INTO v_folio FROM public.remisiones_refacciones WHERE id = v_item.remision_id;

  INSERT INTO public.almacen_refacciones_movimientos (
    producto_id, tipo, cantidad, precio_unitario, cliente_id, notas, created_by
  )
  SELECT v_item.producto_id, 'venta', -_cantidad, v_item.precio_unitario, r.cliente_id,
         'Salida por remisión ' || r.folio, auth.uid()
  FROM public.remisiones_refacciones r
  WHERE r.id = v_item.remision_id;

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, item_id, area, accion, detalle, usuario_id
  ) VALUES (
    v_item.remision_id, _item_id, 'almacen', 'liberar',
    'Almacén liberó ' || _cantidad || ' de ' || v_item.codigo_nuevo || ' (' || coalesce(v_folio, '') || '). La existencia bajó.',
    auth.uid()
  );

  PERFORM public.recalcular_etapa_remision_refaccion(v_item.remision_id);
END;
$$;

-- Logística registra la guía y marca entregada ------------------------------
CREATE OR REPLACE FUNCTION public.puede_operar_logistica_refacciones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    LEFT JOIN public.profiles p ON p.id = ur.user_id
    WHERE ur.user_id = _user_id
      AND coalesce(p.activo, true)
      AND (
        ur.area::text IN ('almacen_logistica', 'direccion')
        OR ur.role::text = 'admin'
        OR public.rol_comercial(_user_id) = 'global'
      )
  );
$$;

REVOKE ALL ON FUNCTION public.puede_operar_logistica_refacciones(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.puede_operar_logistica_refacciones(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.registrar_guia_remision_refaccion(
  _remision_id UUID,
  _paqueteria TEXT,
  _guia TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
BEGIN
  IF NOT public.puede_operar_logistica_refacciones() THEN
    RAISE EXCEPTION 'Sólo logística puede registrar el envío';
  END IF;
  SELECT * INTO v_row FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa <> 'logistica' THEN
    RAISE EXCEPTION 'Logística recibe la remisión cuando almacén ya surtió';
  END IF;

  UPDATE public.remisiones_refacciones
  SET paqueteria = nullif(trim(_paqueteria), ''),
      guia_envio = nullif(trim(_guia), '')
  WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, 'logistica', 'logistica', 'registrar_guia',
    'Logística registró el envío'
      || coalesce(' con ' || nullif(trim(_paqueteria), ''), '')
      || coalesce('. Guía ' || nullif(trim(_guia), ''), '.'),
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_guia_remision_refaccion(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_guia_remision_refaccion(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.entregar_remision_refaccion(_remision_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
BEGIN
  IF NOT public.puede_operar_logistica_refacciones() THEN
    RAISE EXCEPTION 'Sólo logística puede marcar la remisión como entregada';
  END IF;
  SELECT * INTO v_row FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa <> 'logistica' THEN
    RAISE EXCEPTION 'Sólo se entrega una remisión que logística ya tiene en curso';
  END IF;
  IF v_row.tipo_envio = 'paqueteria' AND nullif(trim(coalesce(v_row.guia_envio, '')), '') IS NULL THEN
    RAISE EXCEPTION 'En paquetería hace falta la guía antes de marcarla entregada';
  END IF;

  UPDATE public.remisiones_refacciones
  SET entregada_at = now(),
      entregada_por = auth.uid(),
      etapa = 'entregada',
      area_actual = 'logistica',
      abierta = false
  WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, 'entregada', 'logistica', 'entregar',
    'Logística marcó la remisión como entregada.',
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.entregar_remision_refaccion(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.entregar_remision_refaccion(UUID) TO authenticated;

-- Finanzas marca el pago ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.puede_marcar_pago_refacciones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    LEFT JOIN public.profiles p ON p.id = ur.user_id
    WHERE ur.user_id = _user_id
      AND coalesce(p.activo, true)
      AND (
        ur.area::text IN ('administracion', 'direccion')
        OR ur.role::text IN ('admin', 'finanzas', 'admin_financiero')
        OR public.rol_comercial(_user_id) = 'global'
      )
  );
$$;

REVOKE ALL ON FUNCTION public.puede_marcar_pago_refacciones(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.puede_marcar_pago_refacciones(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.marcar_pago_remision_refaccion(
  _remision_id UUID,
  _pagado BOOLEAN,
  _nota TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
BEGIN
  IF NOT public.puede_marcar_pago_refacciones() THEN
    RAISE EXCEPTION 'Sólo finanzas puede marcar el pago';
  END IF;
  IF coalesce(_pagado, false) AND (nullif(trim(_nota), '') IS NULL OR char_length(trim(_nota)) < 3) THEN
    RAISE EXCEPTION 'Anota cómo se verificó el pago (mínimo 3 caracteres)';
  END IF;

  SELECT * INTO v_row FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa = 'cancelada' THEN
    RAISE EXCEPTION 'Una remisión cancelada no se marca como pagada';
  END IF;

  UPDATE public.remisiones_refacciones
  SET pagado = coalesce(_pagado, false),
      pagado_at = CASE WHEN coalesce(_pagado, false) THEN now() ELSE NULL END,
      pagado_por = CASE WHEN coalesce(_pagado, false) THEN auth.uid() ELSE NULL END,
      nota_pago = nullif(trim(_nota), '')
  WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle, usuario_id)
  VALUES (
    _remision_id, v_row.etapa, 'finanzas',
    CASE WHEN coalesce(_pagado, false) THEN 'marcar_pagado' ELSE 'marcar_no_pagado' END,
    CASE WHEN coalesce(_pagado, false)
      THEN 'Finanzas verificó el pago. ' || coalesce(trim(_nota), '')
      ELSE 'Finanzas dejó la remisión como no pagada. ' || coalesce(trim(_nota), '')
    END,
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.marcar_pago_remision_refaccion(UUID, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marcar_pago_remision_refaccion(UUID, BOOLEAN, TEXT) TO authenticated;

-- Quien la registró también puede soltar el apartado --------------------
CREATE OR REPLACE FUNCTION public.cancelar_linea_refaccion(_item_id UUID, _motivo TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item public.remision_refaccion_items%ROWTYPE;
  v_vendedor UUID;
  v_creador UUID;
  v_rol text;
  v_estatus TEXT;
BEGIN
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo (mínimo 3 caracteres)';
  END IF;

  SELECT * INTO v_item
  FROM public.remision_refaccion_items
  WHERE id = _item_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la partida';
  END IF;
  IF v_item.cantidad_bloqueada <= 0 THEN
    RAISE EXCEPTION 'Esta partida ya no tiene piezas apartadas';
  END IF;

  SELECT vendedor_id, created_by INTO v_vendedor, v_creador
  FROM public.remisiones_refacciones
  WHERE id = v_item.remision_id;

  v_rol := public.rol_comercial();
  IF NOT (
    v_rol IN ('global', 'supervisor')
    OR (v_rol = 'operador' AND (v_vendedor = auth.uid() OR v_creador = auth.uid()))
  ) THEN
    RAISE EXCEPTION 'No puedes cancelar esta partida';
  END IF;

  v_estatus := CASE WHEN v_item.cantidad_surtida > 0 THEN 'surtida' ELSE 'cancelada' END;

  UPDATE public.remision_refaccion_items
  SET cantidad_bloqueada = 0,
      cantidad_faltante = 0,
      estatus = v_estatus
  WHERE id = _item_id;

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, item_id, area, accion, detalle, usuario_id
  ) VALUES (
    v_item.remision_id, _item_id, 'ventas', 'cancelar_linea',
    'Ventas soltó el apartado de ' || v_item.codigo_nuevo || '. ' || trim(_motivo),
    auth.uid()
  );

  PERFORM public.recalcular_etapa_remision_refaccion(v_item.remision_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancelar_remision_refacciones(_remision_id UUID, _motivo TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendedor UUID;
  v_creador UUID;
  v_rol text;
  v_item public.remision_refaccion_items%ROWTYPE;
  v_alguna boolean := false;
BEGIN
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo (mínimo 3 caracteres)';
  END IF;

  SELECT vendedor_id, created_by INTO v_vendedor, v_creador
  FROM public.remisiones_refacciones
  WHERE id = _remision_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;

  v_rol := public.rol_comercial();
  IF NOT (
    v_rol IN ('global', 'supervisor')
    OR (v_rol = 'operador' AND (v_vendedor = auth.uid() OR v_creador = auth.uid()))
  ) THEN
    RAISE EXCEPTION 'No puedes cancelar esta remisión';
  END IF;

  FOR v_item IN
    SELECT * FROM public.remision_refaccion_items
    WHERE remision_id = _remision_id
      AND cantidad_bloqueada > 0
    FOR UPDATE
  LOOP
    v_alguna := true;
    UPDATE public.remision_refaccion_items
    SET cantidad_bloqueada = 0,
        cantidad_faltante = 0,
        estatus = CASE WHEN cantidad_surtida > 0 THEN 'surtida' ELSE 'cancelada' END
    WHERE id = v_item.id;
  END LOOP;

  IF NOT v_alguna THEN
    RAISE EXCEPTION 'Ya no hay piezas apartadas en esta remisión';
  END IF;

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, area, accion, detalle, usuario_id
  ) VALUES (
    _remision_id, 'ventas', 'cancelar_remision',
    'Ventas canceló el apartado pendiente. ' || trim(_motivo),
    auth.uid()
  );

  PERFORM public.recalcular_etapa_remision_refaccion(_remision_id);
END;
$$;

-- Inventarios: cero es el piso, en refacciones y en motocarros --------------
UPDATE public.almacen_refacciones_productos
SET stock = 0
WHERE stock < 0;

DO $chk_ref$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'almacen_refacciones_productos_stock_no_negativo'
  ) THEN
    ALTER TABLE public.almacen_refacciones_productos
      ADD CONSTRAINT almacen_refacciones_productos_stock_no_negativo
      CHECK (stock >= 0);
  END IF;
END $chk_ref$;

UPDATE public.inventario_colores
SET cantidad_disponible = 0
WHERE cantidad_disponible < 0;

DO $chk_color$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'inventario_colores_disponible_no_negativo'
  ) THEN
    ALTER TABLE public.inventario_colores
      ADD CONSTRAINT inventario_colores_disponible_no_negativo
      CHECK (cantidad_disponible >= 0);
  END IF;
END $chk_color$;

CREATE OR REPLACE FUNCTION public.impedir_inventario_negativo()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_disp integer;
  v_modelo text;
  v_color text;
BEGIN
  -- No leer NEW.cantidad_disponible en refacciones: esa tabla no tiene la columna
  -- y Postgres falla aunque el IF no entre (record "new" has no field).
  IF TG_TABLE_NAME = 'almacen_refacciones_productos' THEN
    IF NEW.stock < 0 THEN
      RAISE EXCEPTION 'El inventario de refacciones no puede quedar en negativo (quedaría %)', NEW.stock;
    END IF;
  ELSIF TG_TABLE_NAME = 'inventario_colores' THEN
    v_disp := (to_jsonb(NEW)->>'cantidad_disponible')::integer;
    v_modelo := to_jsonb(NEW)->>'modelo';
    v_color := to_jsonb(NEW)->>'color';
    IF coalesce(v_disp, 0) < 0 THEN
      RAISE EXCEPTION 'El inventario de motocarros no puede quedar en negativo (quedaría % de % %)',
        v_disp, v_modelo, v_color;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_stock_refacciones_no_negativo ON public.almacen_refacciones_productos;
CREATE TRIGGER trg_stock_refacciones_no_negativo
  BEFORE INSERT OR UPDATE OF stock ON public.almacen_refacciones_productos
  FOR EACH ROW EXECUTE FUNCTION public.impedir_inventario_negativo();

DROP TRIGGER IF EXISTS trg_colores_no_negativo ON public.inventario_colores;
CREATE TRIGGER trg_colores_no_negativo
  BEFORE INSERT OR UPDATE OF cantidad_disponible ON public.inventario_colores
  FOR EACH ROW EXECUTE FUNCTION public.impedir_inventario_negativo();
