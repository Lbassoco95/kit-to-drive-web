-- ============================================================================
-- Remisiones de refacciones
-- ----------------------------------------------------------------------------
-- Distintas de las de motocarros. Ventas las levanta con el catálogo del
-- inventario de refacciones. Al levantarlas, la cantidad queda APARTADA:
-- la existencia física no baja, pero los demás pedidos ya ven menos
-- disponible (stock − apartado).
--
-- Almacén (por ahora Martín, vía la allowlist del módulo) revisa:
--   · libera  → baja la existencia y suelta el apartado
--   · reporta faltante → la pieza sigue apartada mientras se averigua
--   · confirma que no hay → corrige la existencia y suelta ese apartado
-- Ventas puede cancelar lo que todavía no se surtió y el apartado regresa.
--
-- La etapa y el área quedan en el encabezado para ver en qué punto está:
--   almacen (área Almacén) · contingencia (área Almacén)
--   surtida (área Almacén) · cancelada (área Ventas)
--
-- Idempotente. Pensado para el SQL editor de Supabase, no para db push.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.almacen_refacciones_productos') IS NULL THEN
    _faltan := _faltan || 'tabla almacen_refacciones_productos'::text;
  END IF;
  IF to_regclass('public.almacen_refacciones_movimientos') IS NULL THEN
    _faltan := _faltan || 'tabla almacen_refacciones_movimientos'::text;
  END IF;
  IF to_regclass('public.clientes') IS NULL THEN
    _faltan := _faltan || 'tabla clientes'::text;
  END IF;
  IF to_regclass('public.profiles') IS NULL THEN
    _faltan := _faltan || 'tabla profiles'::text;
  END IF;
  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN
    _faltan := _faltan || 'funcion rol_comercial (corre 20260902000001)'::text;
  END IF;
  IF to_regprocedure('public.puede_ver_almacen_refacciones(uuid)') IS NULL THEN
    _faltan := _faltan || 'funcion puede_ver_almacen_refacciones (corre 20260922000001)'::text;
  END IF;
  IF to_regprocedure('public.set_updated_at()') IS NULL THEN
    _faltan := _faltan || 'funcion set_updated_at()'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;

-- Encabezado ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.remisiones_refacciones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  folio TEXT NOT NULL,
  cliente_id UUID NOT NULL REFERENCES public.clientes(id),
  vendedor_id UUID REFERENCES public.profiles(id),
  nombre_vendedor TEXT,
  fecha_remision DATE NOT NULL DEFAULT CURRENT_DATE,
  notas TEXT,
  etapa TEXT NOT NULL DEFAULT 'almacen'
    CHECK (etapa IN ('almacen', 'contingencia', 'surtida', 'cancelada')),
  area_actual TEXT NOT NULL DEFAULT 'almacen'
    CHECK (area_actual IN ('ventas', 'almacen')),
  abierta BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT remisiones_refacciones_folio_unico UNIQUE (folio)
);

CREATE INDEX IF NOT EXISTS idx_rem_ref_etapa
  ON public.remisiones_refacciones (etapa, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rem_ref_vendedor
  ON public.remisiones_refacciones (vendedor_id);
CREATE INDEX IF NOT EXISTS idx_rem_ref_cliente
  ON public.remisiones_refacciones (cliente_id);

-- Partidas ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.remision_refaccion_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  remision_id UUID NOT NULL REFERENCES public.remisiones_refacciones(id) ON DELETE CASCADE,
  producto_id UUID NOT NULL REFERENCES public.almacen_refacciones_productos(id),
  codigo_nuevo TEXT NOT NULL,
  codigo_antiguo TEXT,
  descripcion TEXT NOT NULL,
  precio_unitario NUMERIC(12, 2),
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  cantidad_bloqueada INTEGER NOT NULL DEFAULT 0 CHECK (cantidad_bloqueada >= 0),
  cantidad_surtida INTEGER NOT NULL DEFAULT 0 CHECK (cantidad_surtida >= 0),
  cantidad_faltante INTEGER NOT NULL DEFAULT 0 CHECK (cantidad_faltante >= 0),
  estatus TEXT NOT NULL DEFAULT 'bloqueada'
    CHECK (estatus IN ('bloqueada', 'surtida', 'faltante', 'sin_existencia', 'cancelada')),
  nota_almacen TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT rem_ref_item_reparto CHECK (cantidad_bloqueada + cantidad_surtida <= cantidad),
  CONSTRAINT rem_ref_item_faltante CHECK (cantidad_faltante <= cantidad_bloqueada)
);

CREATE INDEX IF NOT EXISTS idx_rem_ref_item_remision
  ON public.remision_refaccion_items (remision_id);
CREATE INDEX IF NOT EXISTS idx_rem_ref_item_producto_apartado
  ON public.remision_refaccion_items (producto_id)
  WHERE estatus IN ('bloqueada', 'faltante');

-- Bitácora de etapa / área --------------------------------------------------
CREATE TABLE IF NOT EXISTS public.remision_refaccion_eventos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  remision_id UUID NOT NULL REFERENCES public.remisiones_refacciones(id) ON DELETE CASCADE,
  item_id UUID REFERENCES public.remision_refaccion_items(id) ON DELETE SET NULL,
  etapa TEXT,
  area TEXT NOT NULL CHECK (area IN ('ventas', 'almacen')),
  accion TEXT NOT NULL,
  detalle TEXT,
  usuario_id UUID REFERENCES public.profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rem_ref_eventos
  ON public.remision_refaccion_eventos (remision_id, created_at);

DROP TRIGGER IF EXISTS trg_rem_ref_updated ON public.remisiones_refacciones;
CREATE TRIGGER trg_rem_ref_updated
  BEFORE UPDATE ON public.remisiones_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Apartado vigente por producto (lo ven todos, no sólo el dueño de la remisión)
CREATE OR REPLACE FUNCTION public.stock_bloqueado_producto(_producto_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(sum(i.cantidad_bloqueada), 0)::INTEGER
  FROM public.remision_refaccion_items i
  WHERE i.producto_id = _producto_id
    AND i.estatus IN ('bloqueada', 'faltante');
$$;

REVOKE ALL ON FUNCTION public.stock_bloqueado_producto(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.stock_bloqueado_producto(UUID) TO authenticated;

-- La vista de inventario ahora dice qué está apartado y qué sigue disponible.
-- No se usa CREATE OR REPLACE con una lista fija: en producción la vista ya
-- trae columnas que este repo no tenía (descripcion_original, caracteristicas,
-- foto_url) y Postgres rechaza cambiar nombres u orden (42P16). Se copian las
-- columnas que ya expone, en el mismo orden, y se agregan las dos nuevas al final.
DO $vista$
DECLARE
  _cols text;
BEGIN
  SELECT string_agg(
    CASE column_name
      WHEN 'num_compatibilidades' THEN 'coalesce(c.num_compat, 0)::integer AS num_compatibilidades'
      WHEN 'tiene_compatibilidad' THEN '(coalesce(c.num_compat, 0) > 0) AS tiene_compatibilidad'
      ELSE 'p.' || quote_ident(column_name)
    END,
    ', ' ORDER BY ordinal_position
  )
  INTO _cols
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'v_almacen_refacciones'
    AND column_name NOT IN ('stock_bloqueado', 'stock_disponible');

  IF _cols IS NULL THEN
    RAISE EXCEPTION 'No está la vista v_almacen_refacciones. Corre antes 20260922000001_almacen_refacciones.sql';
  END IF;

  EXECUTE 'DROP VIEW IF EXISTS public.v_almacen_refacciones';

  EXECUTE format($sql$
    CREATE VIEW public.v_almacen_refacciones
    WITH (security_invoker = true) AS
    SELECT %s,
      b.stock_bloqueado,
      GREATEST(p.stock - b.stock_bloqueado, 0) AS stock_disponible
    FROM public.almacen_refacciones_productos p
    CROSS JOIN LATERAL (
      SELECT public.stock_bloqueado_producto(p.id) AS stock_bloqueado
    ) b
    LEFT JOIN (
      SELECT producto_id, count(*)::INTEGER AS num_compat
      FROM public.almacen_refacciones_producto_compat
      GROUP BY producto_id
    ) c ON c.producto_id = p.id
  $sql$, _cols);
END $vista$;

GRANT SELECT ON public.v_almacen_refacciones TO authenticated;

-- Permisos ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.puede_capturar_refacciones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.rol_comercial(_user_id) IN ('operador', 'supervisor', 'global');
$$;

CREATE OR REPLACE FUNCTION public.puede_operar_almacen_refacciones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.puede_ver_almacen_refacciones(_user_id)
      OR public.rol_comercial(_user_id) = 'global';
$$;

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
BEGIN
  IF _user_id IS NULL OR _remision_id IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = _user_id AND p.activo = false) THEN
    RETURN false;
  END IF;

  SELECT r.vendedor_id INTO _vendedor
  FROM public.remisiones_refacciones r
  WHERE r.id = _remision_id;
  IF NOT FOUND THEN RETURN false; END IF;

  IF public.puede_ver_almacen_refacciones(_user_id) THEN RETURN true; END IF;

  _rol := public.rol_comercial(_user_id);
  IF _rol IN ('global', 'supervisor') THEN RETURN true; END IF;
  IF _rol = 'operador' AND _vendedor = _user_id THEN RETURN true; END IF;

  SELECT ur.area::text INTO _area
  FROM public.user_roles ur
  WHERE ur.user_id = _user_id
  LIMIT 1;
  RETURN _area IN ('direccion', 'administracion');
END;
$$;

REVOKE ALL ON FUNCTION public.puede_capturar_refacciones(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.puede_operar_almacen_refacciones(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.puede_leer_remision_refaccion(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.puede_capturar_refacciones(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_operar_almacen_refacciones(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_leer_remision_refaccion(UUID, UUID) TO authenticated;

-- Etapa + área, a partir de las partidas ------------------------------------
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
  _etapa text;
  _area text;
BEGIN
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
  ELSIF _hay_surtida THEN
    _etapa := 'surtida';
    _area := 'almacen';
    _abierta := false;
  ELSIF _hay_sin THEN
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
      abierta = coalesce(_abierta, false)
  WHERE id = _id;
END;
$$;

REVOKE ALL ON FUNCTION public.recalcular_etapa_remision_refaccion(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.recalcular_etapa_remision_refaccion(UUID) TO authenticated;

-- Alta: aparta y deja la remisión en Almacén --------------------------------
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
  WHERE p.id = auth.uid();
  IF v_nombre IS NULL THEN
    v_nombre := nullif(trim(_nombre_vendedor), '');
  END IF;

  INSERT INTO public.remisiones_refacciones (
    folio, cliente_id, vendedor_id, nombre_vendedor, fecha_remision, notas,
    etapa, area_actual, abierta, created_by
  ) VALUES (
    v_folio, _cliente_id, auth.uid(), v_nombre, CURRENT_DATE, nullif(trim(_notas), ''),
    'almacen', 'almacen', true, auth.uid()
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
     'Remisión levantada en Ventas. La existencia queda apartada para los demás pedidos.',
     auth.uid()),
    (v_id, 'almacen', 'almacen', 'enviada_almacen',
     'Pasó a Almacén para revisión. El apartado sigue vigente.',
     auth.uid());

  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;

REVOKE ALL ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_remision_refacciones(UUID, TEXT, TEXT, JSONB) TO authenticated;

-- Liberar: baja existencia ---------------------------------------------------
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
      'La existencia (%) no cubre lo que se quiere liberar (%). Reporta el faltante.',
      coalesce(v_stock, 0), _cantidad;
  END IF;

  UPDATE public.almacen_refacciones_productos
  SET stock = stock - _cantidad
  WHERE id = v_item.producto_id;

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

REVOKE ALL ON FUNCTION public.liberar_refaccion_remision(UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.liberar_refaccion_remision(UUID, INTEGER) TO authenticated;

-- Reportar faltante: el apartado sigue --------------------------------------
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

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, item_id, etapa, area, accion, detalle, usuario_id
  ) VALUES (
    v_item.remision_id, _item_id, 'contingencia', 'almacen', 'reportar_faltante',
    'Almacén reporta faltante de ' || _cantidad || ' de ' || v_item.codigo_nuevo
      || '. Sigue apartada mientras se averigua. ' || trim(_nota),
    auth.uid()
  );

  PERFORM public.recalcular_etapa_remision_refaccion(v_item.remision_id);
END;
$$;

REVOKE ALL ON FUNCTION public.reportar_faltante_refaccion(UUID, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reportar_faltante_refaccion(UUID, INTEGER, TEXT) TO authenticated;

-- Confirmar que ya no hay: suelta apartado y corrige stock -------------------
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

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, item_id, area, accion, detalle, usuario_id
  ) VALUES (
    v_item.remision_id, _item_id, 'almacen', 'confirmar_sin_existencia',
    'Almacén confirma que no hay ' || v_soltar || ' de ' || v_item.codigo_nuevo
      || '. Existencia corregida en ' || v_baja || '. ' || trim(_nota),
    auth.uid()
  );

  PERFORM public.recalcular_etapa_remision_refaccion(v_item.remision_id);
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_sin_existencia_refaccion(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirmar_sin_existencia_refaccion(UUID, TEXT) TO authenticated;

-- Ventas suelta el apartado que no se surtió ---------------------------------
CREATE OR REPLACE FUNCTION public.cancelar_linea_refaccion(_item_id UUID, _motivo TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item public.remision_refaccion_items%ROWTYPE;
  v_vendedor UUID;
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

  SELECT vendedor_id INTO v_vendedor
  FROM public.remisiones_refacciones
  WHERE id = v_item.remision_id;

  v_rol := public.rol_comercial();
  IF v_rol IN ('global', 'supervisor') THEN
    NULL;
  ELSIF v_rol = 'operador' AND v_vendedor = auth.uid() THEN
    NULL;
  ELSE
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

REVOKE ALL ON FUNCTION public.cancelar_linea_refaccion(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancelar_linea_refaccion(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancelar_remision_refacciones(_remision_id UUID, _motivo TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendedor UUID;
  v_rol text;
  v_item public.remision_refaccion_items%ROWTYPE;
  v_alguna boolean := false;
BEGIN
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo (mínimo 3 caracteres)';
  END IF;

  SELECT vendedor_id INTO v_vendedor
  FROM public.remisiones_refacciones
  WHERE id = _remision_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;

  v_rol := public.rol_comercial();
  IF NOT (v_rol IN ('global', 'supervisor') OR (v_rol = 'operador' AND v_vendedor = auth.uid())) THEN
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

REVOKE ALL ON FUNCTION public.cancelar_remision_refacciones(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancelar_remision_refacciones(UUID, TEXT) TO authenticated;

-- RLS -----------------------------------------------------------------------
ALTER TABLE public.remisiones_refacciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.remision_refaccion_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.remision_refaccion_eventos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "leer remisiones refacciones" ON public.remisiones_refacciones;
CREATE POLICY "leer remisiones refacciones"
  ON public.remisiones_refacciones
  FOR SELECT TO authenticated
  USING (public.puede_leer_remision_refaccion(id));

DROP POLICY IF EXISTS "leer partidas refacciones" ON public.remision_refaccion_items;
CREATE POLICY "leer partidas refacciones"
  ON public.remision_refaccion_items
  FOR SELECT TO authenticated
  USING (public.puede_leer_remision_refaccion(remision_id));

DROP POLICY IF EXISTS "leer eventos refacciones" ON public.remision_refaccion_eventos;
CREATE POLICY "leer eventos refacciones"
  ON public.remision_refaccion_eventos
  FOR SELECT TO authenticated
  USING (public.puede_leer_remision_refaccion(remision_id));

-- Ventas lee el catálogo visible para armar la remisión. No escribe stock.
DROP POLICY IF EXISTS "ref_prod_leer_ventas" ON public.almacen_refacciones_productos;
CREATE POLICY "ref_prod_leer_ventas"
  ON public.almacen_refacciones_productos
  FOR SELECT TO authenticated
  USING (public.rol_comercial() <> 'ninguno' AND visible_venta);

GRANT SELECT ON public.remisiones_refacciones TO authenticated;
GRANT SELECT ON public.remision_refaccion_items TO authenticated;
GRANT SELECT ON public.remision_refaccion_eventos TO authenticated;
