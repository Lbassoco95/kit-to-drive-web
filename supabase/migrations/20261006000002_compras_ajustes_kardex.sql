-- ============================================================================
-- Compras de refacciones, recepción, ajustes retroactivos, kárdex y
-- compatibilidades — 2026-10-06
-- ----------------------------------------------------------------------------
-- Requiere 20261006000001_compras_inventario_base.sql.
--
-- Reglas que se cumplen aquí, en la base, para que ningún camino las brinque:
--   · Candado en ceros: ninguna existencia queda negativa, ni hoy ni en una
--     fecha pasada cuando el ajuste es retroactivo.
--   · Candado de pertenencia: sólo se suma o resta en el almacén donde el
--     artículo está dado de alta (su línea).
--   · La compra no confirmada no toca existencias. La confirmada no se edita:
--     se corrige con ajustes o con otra compra.
--   · La recepción física se registra aparte y su diferencia es un AJUSTE con
--     motivo «Incidencia de recepción de contenedor»; nunca modifica la compra.
--   · El ajuste captura la cantidad CONTADA a una fecha; el sistema calcula la
--     diferencia contra el saldo a esa fecha y la inserta con esa fecha.
--
-- Nombres: `compras` y `compra_lineas` ya existen en producción para
-- motocarros (rama documento-recepcion-inventario); aquí todo lleva el
-- sufijo `_refacciones` para no tocarlas.
--
-- Idempotente. Pensado para el SQL editor de Supabase, no para db push.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regclass('public.inventario_almacenes') IS NULL
     OR to_regprocedure('public.puede_compras_inventario(uuid)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Corre antes 20261006000001_compras_inventario_base.sql';
  END IF;
  IF to_regclass('public.proveedores') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta la tabla proveedores (20260823000004).';
  END IF;
END $preflight$;

-- ── 0. Lectura del catálogo para Compras, Almacén físico y Finanzas ────────
-- Hasta hoy sólo la allowlist leía estas tablas. Se agrega lectura (no
-- escritura) para quien opera el módulo nuevo.
DROP POLICY IF EXISTS ref_prod_leer_compras ON public.almacen_refacciones_productos;
CREATE POLICY ref_prod_leer_compras ON public.almacen_refacciones_productos
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS ref_mov_leer_compras ON public.almacen_refacciones_movimientos;
CREATE POLICY ref_mov_leer_compras ON public.almacen_refacciones_movimientos
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS ref_unidades_leer_compras ON public.almacen_refacciones_unidades;
CREATE POLICY ref_unidades_leer_compras ON public.almacen_refacciones_unidades
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS ref_compat_leer_compras ON public.almacen_refacciones_producto_compat;
CREATE POLICY ref_compat_leer_compras ON public.almacen_refacciones_producto_compat
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS ref_codigos_leer_compras ON public.almacen_refacciones_codigos;
CREATE POLICY ref_codigos_leer_compras ON public.almacen_refacciones_codigos
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));

-- ── 1. Folios por serie (los de prueba llevan su propia numeración) ────────
CREATE TABLE IF NOT EXISTS public.compras_folios (
  serie     text NOT NULL,
  es_prueba boolean NOT NULL,
  ultimo    integer NOT NULL DEFAULT 0,
  PRIMARY KEY (serie, es_prueba)
);
ALTER TABLE public.compras_folios ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public._siguiente_folio_compras(_serie text, _es_prueba boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v integer;
BEGIN
  INSERT INTO public.compras_folios (serie, es_prueba, ultimo) VALUES (_serie, coalesce(_es_prueba, false), 1)
  ON CONFLICT (serie, es_prueba) DO UPDATE SET ultimo = public.compras_folios.ultimo + 1
  RETURNING ultimo INTO v;
  RETURN CASE WHEN coalesce(_es_prueba, false) THEN 'P-' ELSE '' END || _serie || '-' || lpad(v::text, 5, '0');
END;
$$;
REVOKE ALL ON FUNCTION public._siguiente_folio_compras(text, boolean) FROM PUBLIC, anon, authenticated;

-- ── 2. Saldos a una fecha ──────────────────────────────────────────────────
-- La existencia de hoy (`stock`) manda. Lo que no explican los movimientos
-- registrados es el «saldo inicial sin documento» (cargas de lista de precios
-- anteriores al kárdex) y se coloca antes de cualquier fecha.
CREATE OR REPLACE FUNCTION public.saldo_inicial_sin_documento(_producto uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (p.stock - coalesce((SELECT sum(m.cantidad) FROM public.almacen_refacciones_movimientos m
                               WHERE m.producto_id = p.id), 0))::integer
    FROM public.almacen_refacciones_productos p WHERE p.id = _producto
$$;

CREATE OR REPLACE FUNCTION public.saldo_refaccion_a_fecha(_producto uuid, _fecha date)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (public.saldo_inicial_sin_documento(_producto)
          + coalesce((SELECT sum(m.cantidad) FROM public.almacen_refacciones_movimientos m
                       WHERE m.producto_id = _producto AND m.fecha_efectiva <= _fecha), 0))::integer
$$;

-- El saldo más bajo desde `_fecha` en adelante (cierre de cada día con
-- movimientos, más el propio día). Un ajuste retroactivo de `delta` es válido
-- si este mínimo + delta no baja de cero.
CREATE OR REPLACE FUNCTION public.saldo_minimo_desde(_producto uuid, _fecha date)
RETURNS TABLE (saldo_minimo integer, fecha_minimo date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH ini AS (SELECT public.saldo_inicial_sin_documento(_producto) AS s0),
  dias AS (
    SELECT m.fecha_efectiva AS d, sum(m.cantidad) AS q
      FROM public.almacen_refacciones_movimientos m
     WHERE m.producto_id = _producto
     GROUP BY m.fecha_efectiva
  ),
  corrido AS (
    SELECT d, (SELECT s0 FROM ini) + sum(q) OVER (ORDER BY d) AS s FROM dias
  ),
  candidatos AS (
    SELECT _fecha AS d, public.saldo_refaccion_a_fecha(_producto, _fecha) AS s
    UNION ALL
    SELECT d, s FROM corrido WHERE d > _fecha
  )
  SELECT s::integer, d FROM candidatos ORDER BY s ASC, d ASC LIMIT 1
$$;

REVOKE ALL ON FUNCTION public.saldo_inicial_sin_documento(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.saldo_refaccion_a_fecha(uuid, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.saldo_minimo_desde(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.saldo_inicial_sin_documento(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.saldo_refaccion_a_fecha(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.saldo_minimo_desde(uuid, date) TO authenticated;

-- ── 3. El único camino nuevo para mover existencias ────────────────────────
CREATE OR REPLACE FUNCTION public._mover_inventario_refaccion(
  _producto uuid,
  _almacen text,
  _delta integer,
  _fecha date,
  _tipo text,            -- venta | entrada | ajuste | salida (los del CHECK existente)
  _documento_tipo text,  -- compra | remision | ajuste | recepcion | devolucion | inicial | cancelacion
  _documento_id uuid,
  _folio text,
  _motivo text,
  _notas text,
  _cliente uuid DEFAULT NULL,
  _precio numeric DEFAULT NULL,
  _es_prueba boolean DEFAULT false
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_alm public.inventario_almacenes%ROWTYPE;
  v_min integer;
  v_fmin date;
  v_id uuid;
  v_fecha date := coalesce(_fecha, (now() AT TIME ZONE 'America/Mexico_City')::date);
BEGIN
  IF _delta IS NULL OR _delta = 0 THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = _producto FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe el artículo';
  END IF;

  SELECT * INTO v_alm FROM public.inventario_almacenes WHERE clave = _almacen;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El almacén % no existe', _almacen;
  END IF;

  -- Candado de pertenencia.
  IF v_prod.linea_catalogo IS DISTINCT FROM _almacen THEN
    RAISE EXCEPTION 'Candado de pertenencia: % no está dado de alta en % (está en %). No se suma ni se resta donde el artículo no existe.',
      v_prod.codigo_nuevo, v_alm.nombre,
      coalesce((SELECT nombre FROM public.inventario_almacenes WHERE clave = v_prod.linea_catalogo), v_prod.linea_catalogo);
  END IF;

  -- Prueba y real no se mezclan.
  IF v_prod.es_prueba <> coalesce(_es_prueba, false) THEN
    RAISE EXCEPTION 'No se mezclan datos de prueba con reales: % es un artículo %.',
      v_prod.codigo_nuevo, CASE WHEN v_prod.es_prueba THEN 'de prueba' ELSE 'real' END;
  END IF;

  IF v_fecha > (now() AT TIME ZONE 'America/Mexico_City')::date THEN
    RAISE EXCEPTION 'La fecha % es futura', to_char(v_fecha, 'DD/MM/YYYY');
  END IF;

  -- Candado en ceros, hoy.
  IF v_prod.stock + _delta < 0 THEN
    RAISE EXCEPTION 'Candado en ceros: % en % tiene % y la operación lo dejaría en %.',
      v_prod.codigo_nuevo, v_alm.nombre, v_prod.stock, v_prod.stock + _delta;
  END IF;

  -- Candado en ceros, en cualquier fecha posterior a la del movimiento.
  IF _delta < 0 THEN
    SELECT saldo_minimo, fecha_minimo INTO v_min, v_fmin FROM public.saldo_minimo_desde(_producto, v_fecha);
    IF v_min + _delta < 0 THEN
      RAISE EXCEPTION 'Candado en ceros: con fecha % el saldo de % en % quedaría en % el día % (ese día había %).',
        to_char(v_fecha, 'DD/MM/YYYY'), v_prod.codigo_nuevo, v_alm.nombre, v_min + _delta,
        to_char(v_fmin, 'DD/MM/YYYY'), v_min;
    END IF;
  END IF;

  UPDATE public.almacen_refacciones_productos SET stock = stock + _delta WHERE id = _producto;

  INSERT INTO public.almacen_refacciones_movimientos (
    producto_id, tipo, cantidad, precio_unitario, cliente_id, notas, created_by,
    fecha_efectiva, almacen, documento_tipo, documento_id, documento_folio, motivo_clave, es_prueba
  ) VALUES (
    _producto, _tipo, _delta, _precio, _cliente, _notas, auth.uid(),
    v_fecha, _almacen, _documento_tipo, _documento_id, _folio, _motivo, v_prod.es_prueba
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._mover_inventario_refaccion(uuid, text, integer, date, text, text, uuid, text, text, text, uuid, numeric, boolean) FROM PUBLIC, anon, authenticated;

-- ── 4. Alta y edición de artículos (sólo Compras) ──────────────────────────
CREATE OR REPLACE FUNCTION public.alta_articulo_refaccion(_datos jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_codigo text := upper(nullif(trim(_datos->>'codigo_nuevo'), ''));
  v_antiguo text := nullif(trim(_datos->>'codigo_antiguo'), '');
  v_linea text := coalesce(nullif(trim(_datos->>'linea_catalogo'), ''), 'linea_dorada');
  v_prueba boolean := public.es_usuario_prueba(auth.uid()) OR coalesce((_datos->>'es_prueba')::boolean, false);
  v_id uuid;
  v_unidad text := coalesce(nullif(trim(_datos->>'unidad_venta'), ''), 'pieza');
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador da de alta artículos';
  END IF;
  IF v_codigo IS NULL THEN RAISE EXCEPTION 'Escribe el código del artículo'; END IF;
  IF nullif(trim(_datos->>'descripcion'), '') IS NULL THEN RAISE EXCEPTION 'Escribe la descripción'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.inventario_almacenes WHERE clave = v_linea AND activo) THEN
    RAISE EXCEPTION 'La línea % no existe o está inactiva', v_linea;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.inventario_unidades_venta WHERE clave = v_unidad) THEN
    RAISE EXCEPTION 'La unidad de venta % no está en el catálogo', v_unidad;
  END IF;
  IF EXISTS (SELECT 1 FROM public.almacen_refacciones_codigos WHERE upper(codigo) = v_codigo)
     OR EXISTS (SELECT 1 FROM public.almacen_refacciones_productos WHERE upper(codigo_nuevo) = v_codigo) THEN
    RAISE EXCEPTION 'El código % ya existe en el catálogo', v_codigo;
  END IF;
  IF v_antiguo IS NOT NULL AND EXISTS (SELECT 1 FROM public.almacen_refacciones_codigos WHERE upper(codigo) = upper(v_antiguo)) THEN
    RAISE EXCEPTION 'El código antiguo % ya pertenece a otro artículo', v_antiguo;
  END IF;

  INSERT INTO public.almacen_refacciones_productos (
    codigo_nuevo, codigo_antiguo, clave_completa, linea_catalogo, marca, categoria,
    descripcion, descripcion_corta, precio, stock, visible_venta, fuente_archivo,
    unidad_venta, piezas_por_unidad_venta, piezas_caja_cerrada, es_prueba
  ) VALUES (
    v_codigo, v_antiguo, v_codigo, v_linea,
    nullif(trim(_datos->>'marca'), ''), nullif(trim(_datos->>'categoria'), ''),
    trim(_datos->>'descripcion'), nullif(trim(_datos->>'descripcion_corta'), ''),
    nullif(_datos->>'precio', '')::numeric, 0,
    coalesce((_datos->>'visible_venta')::boolean, true), 'alta Compras',
    v_unidad, greatest(coalesce(nullif(_datos->>'piezas_por_unidad_venta', '')::integer, 1), 1),
    nullif(_datos->>'piezas_caja_cerrada', '')::integer, v_prueba
  ) RETURNING id INTO v_id;

  INSERT INTO public.almacen_refacciones_codigos (producto_id, codigo, tipo) VALUES (v_id, v_codigo, 'nuevo');
  IF v_antiguo IS NOT NULL THEN
    INSERT INTO public.almacen_refacciones_codigos (producto_id, codigo, tipo) VALUES (v_id, v_antiguo, 'antiguo');
  END IF;

  PERFORM public.registrar_bitacora_compras('inventario', 'alta_articulo', 'almacen_refacciones_productos', v_id, v_codigo, _datos, v_prueba);
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.alta_articulo_refaccion(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.alta_articulo_refaccion(jsonb) TO authenticated;

-- Edita datos maestros. No toca existencia; la línea sólo cambia si el
-- artículo está en cero (lo impide trg_candado_linea_refaccion).
CREATE OR REPLACE FUNCTION public.actualizar_articulo_refaccion(_id uuid, _datos jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_antes jsonb;
  v_prod public.almacen_refacciones_productos%ROWTYPE;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador edita artículos';
  END IF;
  SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el artículo'; END IF;
  PERFORM public.exigir_dato_prueba(v_prod.es_prueba, 'el artículo ' || v_prod.codigo_nuevo);
  IF _datos ? 'unidad_venta' AND NOT EXISTS (SELECT 1 FROM public.inventario_unidades_venta WHERE clave = _datos->>'unidad_venta') THEN
    RAISE EXCEPTION 'La unidad de venta % no está en el catálogo', _datos->>'unidad_venta';
  END IF;
  v_antes := to_jsonb(v_prod) - 'stock';

  UPDATE public.almacen_refacciones_productos SET
    descripcion = coalesce(nullif(trim(_datos->>'descripcion'), ''), descripcion),
    descripcion_corta = CASE WHEN _datos ? 'descripcion_corta' THEN nullif(trim(_datos->>'descripcion_corta'), '') ELSE descripcion_corta END,
    marca = CASE WHEN _datos ? 'marca' THEN nullif(trim(_datos->>'marca'), '') ELSE marca END,
    categoria = CASE WHEN _datos ? 'categoria' THEN nullif(trim(_datos->>'categoria'), '') ELSE categoria END,
    precio = CASE WHEN _datos ? 'precio' THEN nullif(_datos->>'precio', '')::numeric ELSE precio END,
    visible_venta = coalesce((_datos->>'visible_venta')::boolean, visible_venta),
    linea_catalogo = coalesce(nullif(trim(_datos->>'linea_catalogo'), ''), linea_catalogo),
    unidad_venta = coalesce(nullif(trim(_datos->>'unidad_venta'), ''), unidad_venta),
    piezas_por_unidad_venta = coalesce(nullif(_datos->>'piezas_por_unidad_venta', '')::integer, piezas_por_unidad_venta),
    piezas_caja_cerrada = CASE WHEN _datos ? 'piezas_caja_cerrada' THEN nullif(_datos->>'piezas_caja_cerrada', '')::integer ELSE piezas_caja_cerrada END
  WHERE id = _id;

  PERFORM public.registrar_bitacora_compras('inventario', 'editar_articulo', 'almacen_refacciones_productos', _id,
    v_prod.codigo_nuevo, jsonb_build_object('antes', v_antes, 'cambios', _datos), v_prod.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.actualizar_articulo_refaccion(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_articulo_refaccion(uuid, jsonb) TO authenticated;

-- Carga masiva de datos maestros (unidad de venta, piezas por unidad, piezas
-- por caja, precio). La pantalla ya mostró qué cambia y el usuario lo
-- confirmó; aquí sólo se aplica lo confirmado. Nunca toca existencia.
CREATE OR REPLACE FUNCTION public.aplicar_datos_maestros_refacciones(_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it jsonb;
  v_id uuid;
  v_act integer := 0;
  v_alta integer := 0;
  v_omit integer := 0;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador hace la carga masiva';
  END IF;
  IF jsonb_typeof(_items) <> 'array' THEN RAISE EXCEPTION 'Se espera un arreglo'; END IF;
  FOR it IN SELECT value FROM jsonb_array_elements(_items) LOOP
    SELECT producto_id INTO v_id FROM public.almacen_refacciones_codigos WHERE upper(codigo) = upper(trim(it->>'codigo'));
    IF v_id IS NULL THEN
      SELECT id INTO v_id FROM public.almacen_refacciones_productos WHERE upper(codigo_nuevo) = upper(trim(it->>'codigo'));
    END IF;
    IF v_id IS NULL THEN
      IF coalesce((it->>'crear')::boolean, false) THEN
        PERFORM public.alta_articulo_refaccion(jsonb_build_object('codigo_nuevo', it->>'codigo') || coalesce(it->'campos', '{}'::jsonb));
        v_alta := v_alta + 1;
      ELSE
        v_omit := v_omit + 1;
      END IF;
    ELSE
      PERFORM public.actualizar_articulo_refaccion(v_id, coalesce(it->'campos', '{}'::jsonb));
      v_act := v_act + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('actualizados', v_act, 'altas', v_alta, 'omitidos', v_omit);
END;
$$;
REVOKE ALL ON FUNCTION public.aplicar_datos_maestros_refacciones(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_datos_maestros_refacciones(jsonb) TO authenticated;

-- ── 5. Compras ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.compras_refacciones (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio            text NOT NULL UNIQUE,
  fecha            date NOT NULL DEFAULT CURRENT_DATE,
  almacen          text NOT NULL REFERENCES public.inventario_almacenes(clave),
  contenedor_ref   text,
  proveedor_id     uuid REFERENCES public.proveedores(id) ON DELETE SET NULL,
  estatus          text NOT NULL DEFAULT 'no_confirmada'
                   CHECK (estatus IN ('no_confirmada', 'confirmada', 'cancelada')),
  origen           text NOT NULL DEFAULT 'manual' CHECK (origen IN ('manual', 'packing_list', 'division')),
  archivo_nombre   text,
  archivo_path     text,
  archivo_hash     text,
  compra_origen_id uuid REFERENCES public.compras_refacciones(id) ON DELETE SET NULL,
  notas            text,
  es_prueba        boolean NOT NULL DEFAULT false,
  created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  confirmada_por   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  confirmada_at    timestamptz,
  cancelada_por    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  cancelada_at     timestamptz,
  motivo_cancelacion text
);
CREATE INDEX IF NOT EXISTS idx_compras_ref_estatus ON public.compras_refacciones (estatus, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_compras_ref_contenedor ON public.compras_refacciones (lower(contenedor_ref));
CREATE UNIQUE INDEX IF NOT EXISTS uq_compras_ref_archivo
  ON public.compras_refacciones (archivo_hash, almacen)
  WHERE archivo_hash IS NOT NULL AND estatus <> 'cancelada';

CREATE TABLE IF NOT EXISTS public.compra_refaccion_lineas (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compra_id                 uuid NOT NULL REFERENCES public.compras_refacciones(id) ON DELETE CASCADE,
  producto_id               uuid NOT NULL REFERENCES public.almacen_refacciones_productos(id),
  codigo                    text NOT NULL,
  descripcion               text,
  cantidad                  integer NOT NULL CHECK (cantidad > 0),
  unidad_archivo            text,
  cantidad_archivo          numeric(14, 2),
  piezas_por_unidad_archivo integer,
  costo_unitario            numeric(14, 4) CHECK (costo_unitario IS NULL OR costo_unitario >= 0),
  hoja                      text,
  renglon                   integer,
  created_at                timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_compra_ref_lineas_compra ON public.compra_refaccion_lineas (compra_id);
CREATE INDEX IF NOT EXISTS idx_compra_ref_lineas_producto ON public.compra_refaccion_lineas (producto_id);

-- Lo que el packing list trae y el catálogo no tiene: no se inventa.
CREATE TABLE IF NOT EXISTS public.compra_refaccion_pendientes (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compra_id        uuid NOT NULL REFERENCES public.compras_refacciones(id) ON DELETE CASCADE,
  codigo           text NOT NULL,
  descripcion      text,
  marca            text,
  unidad_archivo   text,
  cantidad_archivo numeric(14, 2),
  estatus          text NOT NULL DEFAULT 'pendiente' CHECK (estatus IN ('pendiente', 'resuelta', 'descartada')),
  producto_id      uuid REFERENCES public.almacen_refacciones_productos(id),
  linea_id         uuid REFERENCES public.compra_refaccion_lineas(id) ON DELETE SET NULL,
  nota             text,
  resuelto_por     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resuelto_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_compra_ref_pend_compra ON public.compra_refaccion_pendientes (compra_id);

DROP TRIGGER IF EXISTS trg_compras_ref_updated ON public.compras_refacciones;
CREATE TRIGGER trg_compras_ref_updated BEFORE UPDATE ON public.compras_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.compras_refacciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.compra_refaccion_lineas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.compra_refaccion_pendientes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS compras_ref_leer ON public.compras_refacciones;
CREATE POLICY compras_ref_leer ON public.compras_refacciones
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS compra_ref_lineas_leer ON public.compra_refaccion_lineas;
CREATE POLICY compra_ref_lineas_leer ON public.compra_refaccion_lineas
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS compra_ref_pend_leer ON public.compra_refaccion_pendientes;
CREATE POLICY compra_ref_pend_leer ON public.compra_refaccion_pendientes
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
GRANT SELECT ON public.compras_refacciones, public.compra_refaccion_lineas, public.compra_refaccion_pendientes TO authenticated;
-- Escritura sólo por las funciones de abajo (no hay políticas de INSERT/UPDATE/DELETE).

-- Valida y escribe las líneas de una compra no confirmada.
CREATE OR REPLACE FUNCTION public._escribir_lineas_compra_refacciones(_compra_id uuid, _lineas jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_compra public.compras_refacciones%ROWTYPE;
  it jsonb;
  v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_n integer := 0;
  v_cant integer;
BEGIN
  SELECT * INTO v_compra FROM public.compras_refacciones WHERE id = _compra_id;
  DELETE FROM public.compra_refaccion_lineas WHERE compra_id = _compra_id;
  IF _lineas IS NULL OR jsonb_typeof(_lineas) <> 'array' THEN RETURN 0; END IF;
  FOR it IN SELECT value FROM jsonb_array_elements(_lineas) LOOP
    SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = (it->>'producto_id')::uuid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Una línea trae un artículo que no existe'; END IF;
    IF v_prod.linea_catalogo <> v_compra.almacen THEN
      RAISE EXCEPTION 'Candado de pertenencia: % está dado de alta en % y la compra es para %. Divide la compra o corrige el almacén.',
        v_prod.codigo_nuevo, v_prod.linea_catalogo, v_compra.almacen;
    END IF;
    IF v_prod.es_prueba <> v_compra.es_prueba THEN
      RAISE EXCEPTION 'No se mezclan datos de prueba con reales: % es un artículo %.',
        v_prod.codigo_nuevo, CASE WHEN v_prod.es_prueba THEN 'de prueba' ELSE 'real' END;
    END IF;
    v_cant := (it->>'cantidad')::integer;
    IF v_cant IS NULL OR v_cant < 1 THEN
      RAISE EXCEPTION 'La cantidad de % debe ser un entero mayor a cero', v_prod.codigo_nuevo;
    END IF;
    INSERT INTO public.compra_refaccion_lineas (
      compra_id, producto_id, codigo, descripcion, cantidad, unidad_archivo, cantidad_archivo,
      piezas_por_unidad_archivo, costo_unitario, hoja, renglon
    ) VALUES (
      _compra_id, v_prod.id, v_prod.codigo_nuevo,
      coalesce(nullif(it->>'descripcion', ''), v_prod.descripcion_corta, v_prod.descripcion),
      v_cant, nullif(it->>'unidad_archivo', ''), nullif(it->>'cantidad_archivo', '')::numeric,
      nullif(it->>'piezas_por_unidad_archivo', '')::integer, nullif(it->>'costo_unitario', '')::numeric,
      nullif(it->>'hoja', ''), nullif(it->>'renglon', '')::integer
    );
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._escribir_lineas_compra_refacciones(uuid, jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.crear_compra_refacciones(_cabecera jsonb, _lineas jsonb, _pendientes jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_alm public.inventario_almacenes%ROWTYPE;
  v_id uuid;
  v_folio text;
  v_prueba boolean := public.es_usuario_prueba(auth.uid()) OR coalesce((_cabecera->>'es_prueba')::boolean, false);
  v_contenedor text := nullif(trim(_cabecera->>'contenedor_ref'), '');
  v_hash text := nullif(trim(_cabecera->>'archivo_hash'), '');
  v_dup text;
  v_n integer;
  it jsonb;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador registra compras';
  END IF;
  SELECT * INTO v_alm FROM public.inventario_almacenes WHERE clave = _cabecera->>'almacen';
  IF NOT FOUND THEN RAISE EXCEPTION 'Confirma el almacén de destino'; END IF;
  IF NOT v_alm.activo THEN RAISE EXCEPTION 'El almacén % está inactivo', v_alm.nombre; END IF;
  IF NOT v_alm.recibe_compras THEN
    RAISE EXCEPTION '% no recibe compras. Las compras llegan a un almacén que las recibe (hoy, Línea dorada).', v_alm.nombre;
  END IF;
  IF v_alm.es_prueba AND NOT v_prueba THEN
    RAISE EXCEPTION 'El almacén % es de prueba', v_alm.nombre;
  END IF;

  -- Duplicados: el mismo archivo, o el mismo contenedor en el mismo almacén.
  IF v_hash IS NOT NULL THEN
    SELECT folio INTO v_dup FROM public.compras_refacciones
     WHERE archivo_hash = v_hash AND almacen = v_alm.clave AND estatus <> 'cancelada' LIMIT 1;
    IF v_dup IS NOT NULL THEN
      RAISE EXCEPTION 'Este archivo ya se importó en la compra %. No se duplica.', v_dup;
    END IF;
  END IF;
  IF v_contenedor IS NOT NULL THEN
    SELECT folio INTO v_dup FROM public.compras_refacciones
     WHERE lower(contenedor_ref) = lower(v_contenedor) AND almacen = v_alm.clave
       AND estatus <> 'cancelada' AND es_prueba = v_prueba LIMIT 1;
    IF v_dup IS NOT NULL THEN
      RAISE EXCEPTION 'El contenedor «%» ya tiene la compra % en %. No se duplica.', v_contenedor, v_dup, v_alm.nombre;
    END IF;
  END IF;

  v_folio := public._siguiente_folio_compras('CR', v_prueba);
  INSERT INTO public.compras_refacciones (
    folio, fecha, almacen, contenedor_ref, proveedor_id, origen, archivo_nombre, archivo_path,
    archivo_hash, notas, es_prueba, created_by
  ) VALUES (
    v_folio, coalesce(nullif(_cabecera->>'fecha', '')::date, (now() AT TIME ZONE 'America/Mexico_City')::date), v_alm.clave, v_contenedor,
    nullif(_cabecera->>'proveedor_id', '')::uuid,
    coalesce(nullif(_cabecera->>'origen', ''), 'manual'),
    nullif(_cabecera->>'archivo_nombre', ''), nullif(_cabecera->>'archivo_path', ''), v_hash,
    nullif(trim(_cabecera->>'notas'), ''), v_prueba, auth.uid()
  ) RETURNING id INTO v_id;

  v_n := public._escribir_lineas_compra_refacciones(v_id, _lineas);

  IF jsonb_typeof(_pendientes) = 'array' THEN
    FOR it IN SELECT value FROM jsonb_array_elements(_pendientes) LOOP
      INSERT INTO public.compra_refaccion_pendientes (compra_id, codigo, descripcion, marca, unidad_archivo, cantidad_archivo)
      VALUES (v_id, coalesce(nullif(trim(it->>'codigo'), ''), '(sin código)'), nullif(it->>'descripcion', ''),
              nullif(it->>'marca', ''), nullif(it->>'unidad_archivo', ''), nullif(it->>'cantidad_archivo', '')::numeric);
    END LOOP;
  END IF;

  IF v_n = 0 AND NOT EXISTS (SELECT 1 FROM public.compra_refaccion_pendientes WHERE compra_id = v_id) THEN
    RAISE EXCEPTION 'La compra no tiene líneas';
  END IF;

  PERFORM public.registrar_bitacora_compras('inventario', 'crear_compra', 'compras_refacciones', v_id, v_folio,
    jsonb_build_object('almacen', v_alm.clave, 'contenedor', v_contenedor, 'lineas', v_n), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio, 'lineas', v_n);
END;
$$;
REVOKE ALL ON FUNCTION public.crear_compra_refacciones(jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_compra_refacciones(jsonb, jsonb, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public._compra_editable(_id uuid)
RETURNS public.compras_refacciones LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.compras_refacciones%ROWTYPE;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador modifica compras';
  END IF;
  SELECT * INTO v FROM public.compras_refacciones WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la compra'; END IF;
  PERFORM public.exigir_dato_prueba(v.es_prueba, 'la compra ' || v.folio);
  IF v.estatus = 'confirmada' THEN
    RAISE EXCEPTION 'La compra % ya está confirmada y no se edita. Corrígela con un ajuste o con otra compra.', v.folio;
  END IF;
  IF v.estatus = 'cancelada' THEN
    RAISE EXCEPTION 'La compra % está cancelada', v.folio;
  END IF;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public._compra_editable(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.actualizar_compra_refacciones(_id uuid, _cabecera jsonb, _lineas jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v public.compras_refacciones%ROWTYPE := public._compra_editable(_id);
  v_alm public.inventario_almacenes%ROWTYPE;
BEGIN
  IF _cabecera ? 'almacen' AND _cabecera->>'almacen' <> v.almacen THEN
    SELECT * INTO v_alm FROM public.inventario_almacenes WHERE clave = _cabecera->>'almacen';
    IF NOT FOUND OR NOT v_alm.recibe_compras OR NOT v_alm.activo THEN
      RAISE EXCEPTION 'El almacén elegido no recibe compras';
    END IF;
  END IF;
  UPDATE public.compras_refacciones SET
    fecha = coalesce(nullif(_cabecera->>'fecha', '')::date, fecha),
    almacen = coalesce(nullif(_cabecera->>'almacen', ''), almacen),
    contenedor_ref = CASE WHEN _cabecera ? 'contenedor_ref' THEN nullif(trim(_cabecera->>'contenedor_ref'), '') ELSE contenedor_ref END,
    proveedor_id = CASE WHEN _cabecera ? 'proveedor_id' THEN nullif(_cabecera->>'proveedor_id', '')::uuid ELSE proveedor_id END,
    notas = CASE WHEN _cabecera ? 'notas' THEN nullif(trim(_cabecera->>'notas'), '') ELSE notas END
  WHERE id = _id;
  IF _lineas IS NOT NULL THEN
    PERFORM public._escribir_lineas_compra_refacciones(_id, _lineas);
  END IF;
  PERFORM public.registrar_bitacora_compras('inventario', 'editar_compra', 'compras_refacciones', _id, v.folio,
    jsonb_build_object('cabecera', _cabecera), v.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.actualizar_compra_refacciones(uuid, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_compra_refacciones(uuid, jsonb, jsonb) TO authenticated;

-- Una compra, un almacén: separa las líneas elegidas en otra compra.
CREATE OR REPLACE FUNCTION public.dividir_compra_refacciones(_id uuid, _linea_ids uuid[], _almacen text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v public.compras_refacciones%ROWTYPE := public._compra_editable(_id);
  v_alm public.inventario_almacenes%ROWTYPE;
  v_nueva uuid;
  v_folio text;
  v_mal text;
BEGIN
  SELECT * INTO v_alm FROM public.inventario_almacenes WHERE clave = _almacen;
  IF NOT FOUND OR NOT v_alm.activo THEN RAISE EXCEPTION 'Elige un almacén activo'; END IF;
  IF NOT v_alm.recibe_compras THEN RAISE EXCEPTION '% no recibe compras', v_alm.nombre; END IF;
  IF coalesce(array_length(_linea_ids, 1), 0) = 0 THEN RAISE EXCEPTION 'Elige las líneas que van a la otra compra'; END IF;
  SELECT string_agg(l.codigo, ', ') INTO v_mal
    FROM public.compra_refaccion_lineas l JOIN public.almacen_refacciones_productos p ON p.id = l.producto_id
   WHERE l.compra_id = _id AND l.id = ANY(_linea_ids) AND p.linea_catalogo <> _almacen;
  IF v_mal IS NOT NULL THEN
    RAISE EXCEPTION 'Candado de pertenencia: % no está dado de alta en %', v_mal, v_alm.nombre;
  END IF;

  v_folio := public._siguiente_folio_compras('CR', v.es_prueba);
  INSERT INTO public.compras_refacciones (folio, fecha, almacen, contenedor_ref, proveedor_id, origen,
    archivo_nombre, archivo_path, notas, es_prueba, created_by, compra_origen_id)
  VALUES (v_folio, v.fecha, _almacen, v.contenedor_ref, v.proveedor_id, 'division',
    v.archivo_nombre, v.archivo_path, 'Dividida de ' || v.folio, v.es_prueba, auth.uid(), v.id)
  RETURNING id INTO v_nueva;

  UPDATE public.compra_refaccion_lineas SET compra_id = v_nueva WHERE compra_id = _id AND id = ANY(_linea_ids);

  PERFORM public.registrar_bitacora_compras('inventario', 'dividir_compra', 'compras_refacciones', _id, v.folio,
    jsonb_build_object('nueva', v_folio, 'almacen', _almacen, 'lineas', array_length(_linea_ids, 1)), v.es_prueba);
  RETURN jsonb_build_object('id', v_nueva, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.dividir_compra_refacciones(uuid, uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dividir_compra_refacciones(uuid, uuid[], text) TO authenticated;

-- Resolver «por dar de alta»: mapear a un artículo existente (o recién dado
-- de alta) con su cantidad, o descartar con nota.
CREATE OR REPLACE FUNCTION public.resolver_pendiente_compra_refacciones(
  _pendiente_id uuid, _producto_id uuid, _cantidad integer, _nota text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_p public.compra_refaccion_pendientes%ROWTYPE;
  v_c public.compras_refacciones%ROWTYPE;
  v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_linea uuid;
BEGIN
  SELECT * INTO v_p FROM public.compra_refaccion_pendientes WHERE id = _pendiente_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el pendiente'; END IF;
  v_c := public._compra_editable(v_p.compra_id);
  IF v_p.estatus <> 'pendiente' THEN RAISE EXCEPTION 'Este código ya se resolvió'; END IF;

  IF _producto_id IS NULL THEN
    IF nullif(trim(_nota), '') IS NULL THEN RAISE EXCEPTION 'Para descartar escribe por qué'; END IF;
    UPDATE public.compra_refaccion_pendientes
       SET estatus = 'descartada', nota = trim(_nota), resuelto_por = auth.uid(), resuelto_at = now()
     WHERE id = _pendiente_id;
    RETURN;
  END IF;

  SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = _producto_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el artículo'; END IF;
  IF v_prod.linea_catalogo <> v_c.almacen THEN
    RAISE EXCEPTION 'Candado de pertenencia: % está en % y la compra es para %', v_prod.codigo_nuevo, v_prod.linea_catalogo, v_c.almacen;
  END IF;
  IF v_prod.es_prueba <> v_c.es_prueba THEN RAISE EXCEPTION 'No se mezclan datos de prueba con reales'; END IF;
  IF _cantidad IS NULL OR _cantidad < 1 THEN RAISE EXCEPTION 'Indica la cantidad'; END IF;

  INSERT INTO public.compra_refaccion_lineas (compra_id, producto_id, codigo, descripcion, cantidad, unidad_archivo, cantidad_archivo)
  VALUES (v_c.id, v_prod.id, v_prod.codigo_nuevo, coalesce(v_prod.descripcion_corta, v_prod.descripcion), _cantidad,
          v_p.unidad_archivo, v_p.cantidad_archivo)
  RETURNING id INTO v_linea;

  UPDATE public.compra_refaccion_pendientes
     SET estatus = 'resuelta', producto_id = v_prod.id, linea_id = v_linea, nota = nullif(trim(_nota), ''),
         resuelto_por = auth.uid(), resuelto_at = now()
   WHERE id = _pendiente_id;
  PERFORM public.registrar_bitacora_compras('inventario', 'resolver_pendiente', 'compras_refacciones', v_c.id, v_c.folio,
    jsonb_build_object('codigo_archivo', v_p.codigo, 'articulo', v_prod.codigo_nuevo, 'cantidad', _cantidad), v_c.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.resolver_pendiente_compra_refacciones(uuid, uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolver_pendiente_compra_refacciones(uuid, uuid, integer, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.confirmar_compra_refacciones(_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v public.compras_refacciones%ROWTYPE := public._compra_editable(_id);
  v_alm public.inventario_almacenes%ROWTYPE;
  l public.compra_refaccion_lineas%ROWTYPE;
  v_n integer := 0;
  v_piezas integer := 0;
BEGIN
  SELECT * INTO v_alm FROM public.inventario_almacenes WHERE clave = v.almacen;
  IF NOT v_alm.recibe_compras THEN
    RAISE EXCEPTION '% no recibe compras', v_alm.nombre;
  END IF;
  IF EXISTS (SELECT 1 FROM public.compra_refaccion_pendientes WHERE compra_id = _id AND estatus = 'pendiente') THEN
    RAISE EXCEPTION 'La compra % tiene códigos por dar de alta. Resuélvelos antes de confirmar.', v.folio;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.compra_refaccion_lineas WHERE compra_id = _id) THEN
    RAISE EXCEPTION 'La compra % no tiene líneas', v.folio;
  END IF;

  FOR l IN SELECT * FROM public.compra_refaccion_lineas WHERE compra_id = _id ORDER BY renglon NULLS LAST, created_at LOOP
    PERFORM public._mover_inventario_refaccion(
      l.producto_id, v.almacen, l.cantidad, v.fecha, 'entrada', 'compra', v.id, v.folio, NULL,
      'Compra ' || v.folio || coalesce(' · contenedor ' || v.contenedor_ref, ''),
      NULL, l.costo_unitario, v.es_prueba);
    v_n := v_n + 1;
    v_piezas := v_piezas + l.cantidad;
  END LOOP;

  UPDATE public.compras_refacciones
     SET estatus = 'confirmada', confirmada_por = auth.uid(), confirmada_at = now()
   WHERE id = _id;
  PERFORM public.registrar_bitacora_compras('inventario', 'confirmar_compra', 'compras_refacciones', _id, v.folio,
    jsonb_build_object('lineas', v_n, 'cantidad', v_piezas, 'almacen', v.almacen), v.es_prueba);
  RETURN jsonb_build_object('folio', v.folio, 'lineas', v_n, 'cantidad', v_piezas);
END;
$$;
REVOKE ALL ON FUNCTION public.confirmar_compra_refacciones(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirmar_compra_refacciones(uuid) TO authenticated;

-- Por lote: todo o nada (si una falla, se dice cuál y no se confirma ninguna).
CREATE OR REPLACE FUNCTION public.confirmar_compras_refacciones(_ids uuid[])
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  v_n integer := 0;
  v_folio text;
BEGIN
  FOREACH v_id IN ARRAY coalesce(_ids, ARRAY[]::uuid[]) LOOP
    SELECT folio INTO v_folio FROM public.compras_refacciones WHERE id = v_id;
    BEGIN
      PERFORM public.confirmar_compra_refacciones(v_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'No se confirmó ninguna. % : %', coalesce(v_folio, v_id::text), SQLERRM;
    END;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.confirmar_compras_refacciones(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirmar_compras_refacciones(uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancelar_compra_refacciones(_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.compras_refacciones%ROWTYPE := public._compra_editable(_id);
BEGIN
  IF nullif(trim(_motivo), '') IS NULL THEN RAISE EXCEPTION 'Escribe el motivo'; END IF;
  UPDATE public.compras_refacciones
     SET estatus = 'cancelada', cancelada_por = auth.uid(), cancelada_at = now(), motivo_cancelacion = trim(_motivo)
   WHERE id = _id;
  PERFORM public.registrar_bitacora_compras('inventario', 'cancelar_compra', 'compras_refacciones', _id, v.folio,
    jsonb_build_object('motivo', _motivo), v.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.cancelar_compra_refacciones(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancelar_compra_refacciones(uuid, text) TO authenticated;

-- Carga inicial de un almacén que no recibe compras (Línea azul, el día antes
-- de usarla). Sólo para artículos que todavía no tienen movimientos.
CREATE OR REPLACE FUNCTION public.cargar_existencia_inicial_refacciones(_almacen text, _fecha date, _items jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it jsonb;
  v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_n integer := 0;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador carga existencias iniciales';
  END IF;
  FOR it IN SELECT value FROM jsonb_array_elements(_items) LOOP
    SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = (it->>'producto_id')::uuid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Un artículo no existe'; END IF;
    PERFORM public.exigir_dato_prueba(v_prod.es_prueba, 'el artículo ' || v_prod.codigo_nuevo);
    IF EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos WHERE producto_id = v_prod.id) OR v_prod.stock <> 0 THEN
      RAISE EXCEPTION '% ya tiene existencia o movimientos: la carga inicial es sólo para artículos en cero sin historial. Usa un ajuste.', v_prod.codigo_nuevo;
    END IF;
    PERFORM public._mover_inventario_refaccion(v_prod.id, _almacen, (it->>'cantidad')::integer, _fecha,
      'entrada', 'inicial', NULL, 'INICIAL', NULL, 'Existencia inicial', NULL, NULL, v_prod.es_prueba);
    v_n := v_n + 1;
  END LOOP;
  PERFORM public.registrar_bitacora_compras('inventario', 'carga_inicial', 'inventario_almacenes', NULL, _almacen,
    jsonb_build_object('articulos', v_n, 'fecha', _fecha), v_prueba);
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.cargar_existencia_inicial_refacciones(text, date, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_existencia_inicial_refacciones(text, date, jsonb) TO authenticated;

-- ── 6. Ajustes de inventario y propuestas de conteo ────────────────────────
CREATE TABLE IF NOT EXISTS public.ajustes_inventario (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio               text NOT NULL UNIQUE,
  almacen             text NOT NULL REFERENCES public.inventario_almacenes(clave),
  fecha_efectiva      date NOT NULL,
  motivo_clave        text NOT NULL REFERENCES public.inventario_motivos_ajuste(clave),
  motivo_texto        text,
  origen              text NOT NULL CHECK (origen IN ('ajuste_rapido', 'conteo_fisico', 'recepcion')),
  recepcion_id        uuid,
  estatus             text NOT NULL CHECK (estatus IN ('propuesta', 'aplicado', 'rechazado')),
  evidencia_path      text,
  notas               text,
  comentario_revision text,
  propuesto_por       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  revisado_por        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  revisado_at         timestamptz,
  es_prueba           boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ajustes_inv_estatus ON public.ajustes_inventario (estatus, created_at DESC);

CREATE TABLE IF NOT EXISTS public.ajuste_inventario_lineas (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ajuste_id             uuid NOT NULL REFERENCES public.ajustes_inventario(id) ON DELETE CASCADE,
  producto_id           uuid NOT NULL REFERENCES public.almacen_refacciones_productos(id),
  modo                  text NOT NULL CHECK (modo IN ('conteo', 'delta')),
  cantidad_contada      integer CHECK (cantidad_contada IS NULL OR cantidad_contada >= 0),
  cajas_cerradas        integer CHECK (cajas_cerradas IS NULL OR cajas_cerradas >= 0),
  piezas_sueltas        integer CHECK (piezas_sueltas IS NULL OR piezas_sueltas >= 0),
  delta_solicitado      integer,
  saldo_sistema         integer,
  delta_aplicado        integer,
  movimiento_id         uuid REFERENCES public.almacen_refacciones_movimientos(id),
  CONSTRAINT ajuste_linea_modo_chk CHECK (
    (modo = 'conteo' AND cantidad_contada IS NOT NULL) OR (modo = 'delta' AND delta_solicitado IS NOT NULL)
  )
);
CREATE INDEX IF NOT EXISTS idx_ajuste_inv_lineas ON public.ajuste_inventario_lineas (ajuste_id);

ALTER TABLE public.ajustes_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ajuste_inventario_lineas ENABLE ROW LEVEL SECURITY;
-- Todos los que operan el módulo ven; sólo las funciones escriben.
DROP POLICY IF EXISTS ajustes_inv_leer ON public.ajustes_inventario;
CREATE POLICY ajustes_inv_leer ON public.ajustes_inventario
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS ajuste_inv_lineas_leer ON public.ajuste_inventario_lineas;
CREATE POLICY ajuste_inv_lineas_leer ON public.ajuste_inventario_lineas
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
GRANT SELECT ON public.ajustes_inventario, public.ajuste_inventario_lineas TO authenticated;

-- Crea el encabezado y sus líneas. Las cantidades contadas pueden venir
-- como cajas cerradas + piezas sueltas (se suman con piezas_caja_cerrada).
CREATE OR REPLACE FUNCTION public._crear_ajuste_inventario(
  _almacen text, _fecha date, _motivo text, _motivo_texto text, _origen text, _estatus text,
  _lineas jsonb, _evidencia text, _notas text, _recepcion uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  v_prueba boolean;
  v_alm public.inventario_almacenes%ROWTYPE;
  v_mot public.inventario_motivos_ajuste%ROWTYPE;
  it jsonb;
  v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_cajas integer;
  v_sueltas integer;
  v_contada integer;
  v_todos_prueba boolean;
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
  v_n integer := 0;
BEGIN
  SELECT * INTO v_alm FROM public.inventario_almacenes WHERE clave = _almacen;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige el almacén'; END IF;
  SELECT * INTO v_mot FROM public.inventario_motivos_ajuste WHERE clave = _motivo AND activo;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige el motivo del ajuste'; END IF;
  IF v_mot.requiere_texto AND nullif(trim(_motivo_texto), '') IS NULL THEN
    RAISE EXCEPTION 'El motivo «%» necesita una explicación', v_mot.nombre;
  END IF;
  IF _fecha IS NULL THEN RAISE EXCEPTION 'Indica la fecha del ajuste'; END IF;
  IF _fecha > v_hoy THEN RAISE EXCEPTION 'La fecha del ajuste no puede ser futura'; END IF;
  IF _lineas IS NULL OR jsonb_typeof(_lineas) <> 'array' OR jsonb_array_length(_lineas) = 0 THEN
    RAISE EXCEPTION 'Agrega al menos un artículo';
  END IF;

  -- La prueba la define el artículo: todos deben ser del mismo tipo.
  SELECT bool_or(p.es_prueba), bool_and(p.es_prueba) INTO v_prueba, v_todos_prueba
    FROM jsonb_array_elements(_lineas) e
    JOIN public.almacen_refacciones_productos p ON p.id = (e.value->>'producto_id')::uuid;
  IF v_prueba IS NULL THEN RAISE EXCEPTION 'Un artículo del ajuste no existe'; END IF;
  IF v_prueba AND NOT v_todos_prueba THEN RAISE EXCEPTION 'No se mezclan artículos de prueba con reales en un ajuste'; END IF;
  PERFORM public.exigir_dato_prueba(v_prueba, 'un artículo real');

  INSERT INTO public.ajustes_inventario (folio, almacen, fecha_efectiva, motivo_clave, motivo_texto, origen,
    recepcion_id, estatus, evidencia_path, notas, propuesto_por, es_prueba)
  VALUES (public._siguiente_folio_compras('AJ', v_prueba), _almacen, _fecha, _motivo, nullif(trim(_motivo_texto), ''),
    _origen, _recepcion, _estatus, nullif(trim(_evidencia), ''), nullif(trim(_notas), ''), auth.uid(), v_prueba)
  RETURNING id INTO v_id;

  FOR it IN SELECT value FROM jsonb_array_elements(_lineas) LOOP
    SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = (it->>'producto_id')::uuid;
    IF v_prod.linea_catalogo <> _almacen THEN
      RAISE EXCEPTION 'Candado de pertenencia: % no está dado de alta en %', v_prod.codigo_nuevo, v_alm.nombre;
    END IF;
    v_cajas := nullif(it->>'cajas_cerradas', '')::integer;
    v_sueltas := nullif(it->>'piezas_sueltas', '')::integer;
    v_contada := nullif(it->>'cantidad_contada', '')::integer;
    IF v_contada IS NULL AND (v_cajas IS NOT NULL OR v_sueltas IS NOT NULL) THEN
      IF v_cajas IS NOT NULL AND v_prod.piezas_caja_cerrada IS NULL THEN
        RAISE EXCEPTION '% no tiene piezas por caja cerrada: captura la cantidad en piezas', v_prod.codigo_nuevo;
      END IF;
      v_contada := coalesce(v_cajas, 0) * coalesce(v_prod.piezas_caja_cerrada, 0) + coalesce(v_sueltas, 0);
    END IF;
    IF it ? 'delta' THEN
      INSERT INTO public.ajuste_inventario_lineas (ajuste_id, producto_id, modo, delta_solicitado, saldo_sistema)
      VALUES (v_id, v_prod.id, 'delta', (it->>'delta')::integer, public.saldo_refaccion_a_fecha(v_prod.id, _fecha));
    ELSE
      IF v_contada IS NULL OR v_contada < 0 THEN
        RAISE EXCEPTION 'Captura la cantidad real contada de % (no la diferencia)', v_prod.codigo_nuevo;
      END IF;
      INSERT INTO public.ajuste_inventario_lineas (ajuste_id, producto_id, modo, cantidad_contada, cajas_cerradas, piezas_sueltas, saldo_sistema)
      VALUES (v_id, v_prod.id, 'conteo', v_contada, v_cajas, v_sueltas, public.saldo_refaccion_a_fecha(v_prod.id, _fecha));
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._crear_ajuste_inventario(text, date, text, text, text, text, jsonb, text, text, uuid) FROM PUBLIC, anon, authenticated;

-- Aplica: «a esa fecha el saldo era X». Inserta la diferencia contra el saldo
-- calculado a esa fecha, con esa fecha. Lo posterior sigue sumando y restando.
CREATE OR REPLACE FUNCTION public._aplicar_ajuste_inventario(_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v public.ajustes_inventario%ROWTYPE;
  l public.ajuste_inventario_lineas%ROWTYPE;
  v_saldo integer;
  v_delta integer;
  v_mov uuid;
  v_n integer := 0;
  v_mot text;
BEGIN
  SELECT * INTO v FROM public.ajustes_inventario WHERE id = _id FOR UPDATE;
  SELECT nombre INTO v_mot FROM public.inventario_motivos_ajuste WHERE clave = v.motivo_clave;
  FOR l IN SELECT * FROM public.ajuste_inventario_lineas WHERE ajuste_id = _id LOOP
    -- Bloquea antes de leer el saldo para que nadie mueva el artículo en medio.
    PERFORM 1 FROM public.almacen_refacciones_productos WHERE id = l.producto_id FOR UPDATE;
    v_saldo := public.saldo_refaccion_a_fecha(l.producto_id, v.fecha_efectiva);
    v_delta := CASE WHEN l.modo = 'conteo' THEN l.cantidad_contada - v_saldo ELSE l.delta_solicitado END;
    v_mov := public._mover_inventario_refaccion(
      l.producto_id, v.almacen, v_delta, v.fecha_efectiva, 'ajuste',
      CASE WHEN v.origen = 'recepcion' THEN 'recepcion' ELSE 'ajuste' END,
      v.id, v.folio, v.motivo_clave,
      coalesce(v_mot, v.motivo_clave) || coalesce(': ' || v.motivo_texto, '')
        || CASE WHEN l.modo = 'conteo' THEN ' · contado ' || l.cantidad_contada || ', sistema ' || v_saldo ELSE '' END,
      NULL, NULL, v.es_prueba);
    UPDATE public.ajuste_inventario_lineas
       SET saldo_sistema = v_saldo, delta_aplicado = v_delta, movimiento_id = v_mov
     WHERE id = l.id;
    v_n := v_n + 1;
  END LOOP;
  UPDATE public.ajustes_inventario
     SET estatus = 'aplicado', revisado_por = coalesce(revisado_por, auth.uid()), revisado_at = coalesce(revisado_at, now())
   WHERE id = _id;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._aplicar_ajuste_inventario(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.aplicar_ajuste_rapido(
  _almacen text, _fecha date, _motivo text, _motivo_texto text, _lineas jsonb,
  _evidencia text DEFAULT NULL, _notas text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  v_folio text;
  v_prueba boolean;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador aplica ajustes. Almacén registra un conteo físico y Compras lo aprueba.';
  END IF;
  v_id := public._crear_ajuste_inventario(_almacen, _fecha, _motivo, _motivo_texto, 'ajuste_rapido', 'propuesta',
    _lineas, _evidencia, _notas);
  PERFORM public._aplicar_ajuste_inventario(v_id);
  SELECT folio, es_prueba INTO v_folio, v_prueba FROM public.ajustes_inventario WHERE id = v_id;
  PERFORM public.registrar_bitacora_compras('inventario', 'ajuste_rapido', 'ajustes_inventario', v_id, v_folio,
    jsonb_build_object('almacen', _almacen, 'fecha_efectiva', _fecha, 'motivo', _motivo, 'lineas', _lineas), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.aplicar_ajuste_rapido(text, date, text, text, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_ajuste_rapido(text, date, text, text, jsonb, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.proponer_conteo_fisico(
  _almacen text, _fecha date, _lineas jsonb, _notas text DEFAULT NULL, _evidencia text DEFAULT NULL,
  _motivo text DEFAULT 'auditoria'
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  v_folio text;
  v_prueba boolean;
BEGIN
  IF NOT public.puede_almacen_fisico(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Almacén o Compras registran conteos físicos';
  END IF;
  v_id := public._crear_ajuste_inventario(_almacen, _fecha, coalesce(_motivo, 'auditoria'), NULL, 'conteo_fisico',
    'propuesta', _lineas, _evidencia, _notas);
  SELECT folio, es_prueba INTO v_folio, v_prueba FROM public.ajustes_inventario WHERE id = v_id;
  PERFORM public.registrar_bitacora_compras('inventario', 'proponer_conteo', 'ajustes_inventario', v_id, v_folio,
    jsonb_build_object('almacen', _almacen, 'fecha', _fecha), v_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.proponer_conteo_fisico(text, date, jsonb, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.proponer_conteo_fisico(text, date, jsonb, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.revisar_propuesta_ajuste(_id uuid, _aprobar boolean, _comentario text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.ajustes_inventario%ROWTYPE;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador aprueba o rechaza ajustes';
  END IF;
  SELECT * INTO v FROM public.ajustes_inventario WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la propuesta'; END IF;
  PERFORM public.exigir_dato_prueba(v.es_prueba, 'el ajuste ' || v.folio);
  IF v.estatus <> 'propuesta' THEN RAISE EXCEPTION 'La propuesta % ya fue %', v.folio, v.estatus; END IF;
  IF NOT coalesce(_aprobar, false) AND nullif(trim(_comentario), '') IS NULL THEN
    RAISE EXCEPTION 'Para rechazar escribe un comentario';
  END IF;
  UPDATE public.ajustes_inventario
     SET comentario_revision = nullif(trim(_comentario), ''), revisado_por = auth.uid(), revisado_at = now(),
         estatus = CASE WHEN coalesce(_aprobar, false) THEN estatus ELSE 'rechazado' END
   WHERE id = _id;
  IF coalesce(_aprobar, false) THEN
    PERFORM public._aplicar_ajuste_inventario(_id);
  END IF;
  PERFORM public.registrar_bitacora_compras('inventario', CASE WHEN _aprobar THEN 'aprobar_ajuste' ELSE 'rechazar_ajuste' END,
    'ajustes_inventario', _id, v.folio, jsonb_build_object('comentario', _comentario), v.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.revisar_propuesta_ajuste(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revisar_propuesta_ajuste(uuid, boolean, text) TO authenticated;

-- ── 7. Recepción física de contenedor ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.recepciones_refacciones (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio         text NOT NULL UNIQUE,
  compra_id     uuid NOT NULL REFERENCES public.compras_refacciones(id),
  fecha         date NOT NULL,
  visto_bueno   boolean NOT NULL DEFAULT true,
  notas         text,
  ajuste_id     uuid REFERENCES public.ajustes_inventario(id),
  registrada_por uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  es_prueba     boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT recepciones_ref_una_por_compra UNIQUE (compra_id)
);
CREATE TABLE IF NOT EXISTS public.recepcion_refaccion_lineas (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recepcion_id   uuid NOT NULL REFERENCES public.recepciones_refacciones(id) ON DELETE CASCADE,
  producto_id    uuid NOT NULL REFERENCES public.almacen_refacciones_productos(id),
  esperado       integer NOT NULL,
  cajas_cerradas integer,
  piezas_sueltas integer,
  contado        integer NOT NULL CHECK (contado >= 0),
  incidencia     text
);
CREATE INDEX IF NOT EXISTS idx_recepcion_ref_lineas ON public.recepcion_refaccion_lineas (recepcion_id);
ALTER TABLE public.recepciones_refacciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recepcion_refaccion_lineas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS recepciones_ref_leer ON public.recepciones_refacciones;
CREATE POLICY recepciones_ref_leer ON public.recepciones_refacciones
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS recepcion_ref_lineas_leer ON public.recepcion_refaccion_lineas;
CREATE POLICY recepcion_ref_lineas_leer ON public.recepcion_refaccion_lineas
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
GRANT SELECT ON public.recepciones_refacciones, public.recepcion_refaccion_lineas TO authenticated;

-- Almacén captura lo contado (piezas, o cajas cerradas + sueltas). La
-- diferencia contra lo esperado se vuelve un ajuste «Incidencia de recepción
-- de contenedor» con la fecha de la recepción: si lo registra Compras se
-- aplica en el acto; si lo registra Almacén queda como propuesta.
CREATE OR REPLACE FUNCTION public.registrar_recepcion_refacciones(
  _compra_id uuid, _fecha date, _lineas jsonb, _notas text DEFAULT NULL, _visto_bueno boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_c public.compras_refacciones%ROWTYPE;
  v_id uuid;
  v_folio text;
  it jsonb;
  v_prod public.almacen_refacciones_productos%ROWTYPE;
  v_esperado integer;
  v_contado integer;
  v_difs jsonb := '[]'::jsonb;
  v_ajuste uuid;
  v_aplicado boolean := false;
BEGIN
  IF NOT public.puede_almacen_fisico(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Almacén o Compras registran la recepción';
  END IF;
  SELECT * INTO v_c FROM public.compras_refacciones WHERE id = _compra_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la compra'; END IF;
  PERFORM public.exigir_dato_prueba(v_c.es_prueba, 'la compra ' || v_c.folio);
  IF v_c.estatus <> 'confirmada' THEN
    RAISE EXCEPTION 'La compra % todavía no está confirmada: confírmala antes de registrar la recepción', v_c.folio;
  END IF;
  IF EXISTS (SELECT 1 FROM public.recepciones_refacciones WHERE compra_id = _compra_id) THEN
    RAISE EXCEPTION 'La compra % ya tiene recepción. Las diferencias posteriores van como ajuste.', v_c.folio;
  END IF;

  v_folio := public._siguiente_folio_compras('RC', v_c.es_prueba);
  INSERT INTO public.recepciones_refacciones (folio, compra_id, fecha, visto_bueno, notas, registrada_por, es_prueba)
  VALUES (v_folio, _compra_id, coalesce(_fecha, (now() AT TIME ZONE 'America/Mexico_City')::date), coalesce(_visto_bueno, true), nullif(trim(_notas), ''),
          auth.uid(), v_c.es_prueba)
  RETURNING id INTO v_id;

  FOR it IN SELECT value FROM jsonb_array_elements(_lineas) LOOP
    SELECT * INTO v_prod FROM public.almacen_refacciones_productos WHERE id = (it->>'producto_id')::uuid;
    SELECT sum(cantidad) INTO v_esperado FROM public.compra_refaccion_lineas
     WHERE compra_id = _compra_id AND producto_id = v_prod.id;
    IF v_esperado IS NULL THEN
      RAISE EXCEPTION '% no viene en la compra %', v_prod.codigo_nuevo, v_c.folio;
    END IF;
    v_contado := nullif(it->>'contado', '')::integer;
    IF v_contado IS NULL THEN
      IF nullif(it->>'cajas_cerradas', '') IS NOT NULL AND v_prod.piezas_caja_cerrada IS NULL THEN
        RAISE EXCEPTION '% no tiene piezas por caja cerrada: captura piezas', v_prod.codigo_nuevo;
      END IF;
      v_contado := coalesce(nullif(it->>'cajas_cerradas', '')::integer, 0) * coalesce(v_prod.piezas_caja_cerrada, 0)
                 + coalesce(nullif(it->>'piezas_sueltas', '')::integer, 0);
    END IF;
    INSERT INTO public.recepcion_refaccion_lineas (recepcion_id, producto_id, esperado, cajas_cerradas, piezas_sueltas, contado, incidencia)
    VALUES (v_id, v_prod.id, v_esperado, nullif(it->>'cajas_cerradas', '')::integer,
            nullif(it->>'piezas_sueltas', '')::integer, v_contado, nullif(trim(it->>'incidencia'), ''));
    IF v_contado <> v_esperado THEN
      v_difs := v_difs || jsonb_build_object('producto_id', v_prod.id, 'delta', v_contado - v_esperado);
    END IF;
  END LOOP;

  IF jsonb_array_length(v_difs) > 0 THEN
    v_ajuste := public._crear_ajuste_inventario(v_c.almacen, coalesce(_fecha, (now() AT TIME ZONE 'America/Mexico_City')::date), 'incidencia_recepcion',
      'Recepción ' || v_folio || ' de la compra ' || v_c.folio || coalesce(' (contenedor ' || v_c.contenedor_ref || ')', ''),
      'recepcion', 'propuesta', v_difs, NULL, _notas, v_id);
    UPDATE public.recepciones_refacciones SET ajuste_id = v_ajuste WHERE id = v_id;
    IF public.puede_compras_inventario(auth.uid()) THEN
      PERFORM public._aplicar_ajuste_inventario(v_ajuste);
      v_aplicado := true;
    END IF;
  END IF;

  PERFORM public.registrar_bitacora_compras('inventario', 'registrar_recepcion', 'recepciones_refacciones', v_id, v_folio,
    jsonb_build_object('compra', v_c.folio, 'diferencias', v_difs, 'ajuste_aplicado', v_aplicado), v_c.es_prueba);
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio, 'diferencias', jsonb_array_length(v_difs),
                            'ajuste_id', v_ajuste, 'ajuste_aplicado', v_aplicado);
END;
$$;
REVOKE ALL ON FUNCTION public.registrar_recepcion_refacciones(uuid, date, jsonb, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_recepcion_refacciones(uuid, date, jsonb, text, boolean) TO authenticated;

-- Vista de contenedor: solicitado (packing list), real en inventario (lo
-- solicitado + ajustes aplicados ligados a la recepción) y diferencia.
CREATE OR REPLACE VIEW public.v_compra_refacciones_contenedor
WITH (security_invoker = true) AS
SELECT
  c.id AS compra_id, c.folio, c.fecha, c.almacen, c.contenedor_ref, c.estatus, c.es_prueba,
  l.producto_id, p.codigo_nuevo, coalesce(p.descripcion_corta, p.descripcion) AS descripcion,
  sum(l.cantidad)::integer AS solicitado,
  r.folio AS recepcion_folio,
  rl.contado,
  rl.incidencia,
  (sum(l.cantidad) + coalesce((
     SELECT sum(al.delta_aplicado) FROM public.ajuste_inventario_lineas al
       JOIN public.ajustes_inventario a ON a.id = al.ajuste_id
      WHERE a.recepcion_id = r.id AND a.estatus = 'aplicado' AND al.producto_id = l.producto_id), 0))::integer AS real_inventario,
  coalesce((
     SELECT sum(al.delta_aplicado) FROM public.ajuste_inventario_lineas al
       JOIN public.ajustes_inventario a ON a.id = al.ajuste_id
      WHERE a.recepcion_id = r.id AND a.estatus = 'aplicado' AND al.producto_id = l.producto_id), 0)::integer AS diferencia,
  (SELECT a.estatus FROM public.ajustes_inventario a WHERE a.recepcion_id = r.id LIMIT 1) AS ajuste_estatus
FROM public.compras_refacciones c
JOIN public.compra_refaccion_lineas l ON l.compra_id = c.id
JOIN public.almacen_refacciones_productos p ON p.id = l.producto_id
LEFT JOIN public.recepciones_refacciones r ON r.compra_id = c.id
LEFT JOIN public.recepcion_refaccion_lineas rl ON rl.recepcion_id = r.id AND rl.producto_id = l.producto_id
GROUP BY c.id, c.folio, c.fecha, c.almacen, c.contenedor_ref, c.estatus, c.es_prueba, l.producto_id,
         p.codigo_nuevo, p.descripcion_corta, p.descripcion, r.id, r.folio, rl.contado, rl.incidencia;
GRANT SELECT ON public.v_compra_refacciones_contenedor TO authenticated;

-- ── 8. Kárdex ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.kardex_refaccion(_producto uuid, _desde date DEFAULT NULL, _hasta date DEFAULT NULL)
RETURNS TABLE (
  fecha date, registrado timestamptz, tipo text, documento_tipo text, folio text,
  cliente text, motivo text, notas text, entrada integer, salida integer, saldo integer, almacen text
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE
  v_desde date := coalesce(_desde, '1900-01-01'::date);
  v_hasta date := coalesce(_hasta, '2999-12-31'::date);
  v_ini integer;
BEGIN
  IF NOT public.puede_leer_compras_inventario(auth.uid()) AND NOT public.puede_ver_almacen_refacciones(auth.uid()) THEN
    RAISE EXCEPTION 'Sin acceso al kárdex';
  END IF;
  PERFORM public.exigir_lectura_prueba('almacen_refacciones_productos', _producto);
  v_ini := public.saldo_refaccion_a_fecha(_producto, v_desde - 1);
  RETURN QUERY
  SELECT v_desde - 1, NULL::timestamptz, 'saldo_inicial'::text, 'saldo_inicial'::text, NULL::text, NULL::text,
         NULL::text, 'Saldo al ' || to_char(v_desde - 1, 'DD/MM/YYYY'), NULL::integer, NULL::integer, v_ini,
         (SELECT linea_catalogo FROM public.almacen_refacciones_productos WHERE id = _producto)
  WHERE _desde IS NOT NULL OR v_ini <> 0;
  RETURN QUERY
  SELECT m.fecha_efectiva, m.created_at, m.tipo, m.documento_tipo, m.documento_folio,
         coalesce(cl.nombre_comercial, cl.razon_social, cl.codigo_erp), m.motivo_clave, m.notas,
         CASE WHEN m.cantidad > 0 THEN m.cantidad END,
         CASE WHEN m.cantidad < 0 THEN -m.cantidad END,
         (v_ini + sum(m.cantidad) OVER (ORDER BY m.fecha_efectiva, m.created_at, m.id))::integer,
         m.almacen
    FROM public.almacen_refacciones_movimientos m
    LEFT JOIN public.clientes cl ON cl.id = m.cliente_id
   WHERE m.producto_id = _producto AND m.fecha_efectiva BETWEEN v_desde AND v_hasta
   ORDER BY m.fecha_efectiva, m.created_at, m.id;
END;
$$;
REVOKE ALL ON FUNCTION public.kardex_refaccion(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kardex_refaccion(uuid, date, date) TO authenticated;

-- Base para rotación, ABC y sugeridos: una fila por artículo con sus ventas
-- del periodo (piezas y monto), existencia, apartado, en tránsito y la
-- última compra. Excluye la prueba salvo que se pida.
CREATE OR REPLACE FUNCTION public.resumen_rotacion_refacciones(_desde date, _hasta date, _incluir_prueba boolean DEFAULT false)
RETURNS TABLE (
  producto_id uuid, codigo text, codigo_antiguo text, descripcion text, linea text, marca text,
  unidad_venta text, piezas_por_unidad_venta integer, piezas_caja_cerrada integer, precio numeric,
  piezas_vendidas integer, monto_vendido numeric, meses_con_venta integer,
  existencia integer, apartado integer, en_transito integer, ultima_compra date,
  compatibilidades text, es_prueba boolean
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.puede_leer_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sin acceso a rotación';
  END IF;
  RETURN QUERY
  SELECT p.id, p.codigo_nuevo, p.codigo_antiguo, coalesce(p.descripcion_corta, p.descripcion), p.linea_catalogo, p.marca,
         p.unidad_venta, p.piezas_por_unidad_venta, p.piezas_caja_cerrada, p.precio,
         coalesce(v.piezas, 0)::integer, coalesce(v.monto, 0)::numeric, coalesce(v.meses, 0)::integer,
         p.stock, public.stock_bloqueado_producto(p.id),
         coalesce((SELECT sum(l.cantidad) FROM public.compra_refaccion_lineas l
                     JOIN public.compras_refacciones c ON c.id = l.compra_id
                    WHERE l.producto_id = p.id AND c.estatus = 'no_confirmada'), 0)::integer,
         (SELECT max(m.fecha_efectiva) FROM public.almacen_refacciones_movimientos m
           WHERE m.producto_id = p.id AND m.documento_tipo IN ('compra', 'inicial')),
         (SELECT string_agg(u.nombre, ', ' ORDER BY u.nombre)
            FROM public.almacen_refacciones_producto_compat pc
            JOIN public.almacen_refacciones_unidades u ON u.id = pc.unidad_id
           WHERE pc.producto_id = p.id),
         p.es_prueba
    FROM public.almacen_refacciones_productos p
    LEFT JOIN LATERAL (
      SELECT sum(-m.cantidad) AS piezas,
             sum(-m.cantidad * coalesce(m.precio_unitario, p.precio, 0)) AS monto,
             count(DISTINCT date_trunc('month', m.fecha_efectiva)) AS meses
        FROM public.almacen_refacciones_movimientos m
       WHERE m.producto_id = p.id AND m.tipo = 'venta'
         AND m.fecha_efectiva BETWEEN _desde AND _hasta
    ) v ON true
   WHERE (coalesce(_incluir_prueba, false) OR NOT p.es_prueba)
     AND (p.es_prueba OR NOT public.es_usuario_prueba(auth.uid()));
END;
$$;
REVOKE ALL ON FUNCTION public.resumen_rotacion_refacciones(date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resumen_rotacion_refacciones(date, date, boolean) TO authenticated;

-- Ventas por artículo y mes, con lo que se llevó el cliente más grande de
-- ese mes. Sirve para marcar ventas atípicas y no inflar el sugerido.
CREATE OR REPLACE FUNCTION public.ventas_mensuales_refacciones(_desde date, _hasta date, _incluir_prueba boolean DEFAULT false)
RETURNS TABLE (producto_id uuid, mes date, piezas integer, monto numeric, piezas_cliente_mayor integer, cliente_mayor text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.puede_leer_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sin acceso a rotación';
  END IF;
  RETURN QUERY
  WITH porcli AS (
    SELECT m.producto_id AS pid, date_trunc('month', m.fecha_efectiva)::date AS mes_, m.cliente_id AS cid,
           sum(-m.cantidad)::integer AS pz, sum(-m.cantidad * coalesce(m.precio_unitario, 0)) AS mt
      FROM public.almacen_refacciones_movimientos m
     WHERE m.tipo = 'venta' AND m.fecha_efectiva BETWEEN _desde AND _hasta
       AND (coalesce(_incluir_prueba, false) OR NOT m.es_prueba)
       AND (m.es_prueba OR NOT public.es_usuario_prueba(auth.uid()))
     GROUP BY 1, 2, 3
  )
  SELECT pc.pid, pc.mes_, sum(pc.pz)::integer, sum(pc.mt)::numeric,
         max(pc.pz)::integer,
         (SELECT coalesce(cl.nombre_comercial, cl.razon_social, '(sin cliente)') FROM porcli x
            LEFT JOIN public.clientes cl ON cl.id = x.cid
           WHERE x.pid = pc.pid AND x.mes_ = pc.mes_ ORDER BY x.pz DESC LIMIT 1)
    FROM porcli pc
   GROUP BY pc.pid, pc.mes_;
END;
$$;
REVOKE ALL ON FUNCTION public.ventas_mensuales_refacciones(date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ventas_mensuales_refacciones(date, date, boolean) TO authenticated;

-- Salidas por mes y cliente (para la marca de concentración del kárdex).
CREATE OR REPLACE FUNCTION public.salidas_por_cliente_mes(_producto uuid, _desde date, _hasta date)
RETURNS TABLE (mes date, cliente_id uuid, cliente text, piezas integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.puede_leer_compras_inventario(auth.uid()) AND NOT public.puede_ver_almacen_refacciones(auth.uid()) THEN
    RAISE EXCEPTION 'Sin acceso';
  END IF;
  PERFORM public.exigir_lectura_prueba('almacen_refacciones_productos', _producto);
  RETURN QUERY
  SELECT date_trunc('month', m.fecha_efectiva)::date, m.cliente_id,
         coalesce(cl.nombre_comercial, cl.razon_social, cl.codigo_erp, '(sin cliente)'),
         sum(-m.cantidad)::integer
    FROM public.almacen_refacciones_movimientos m
    LEFT JOIN public.clientes cl ON cl.id = m.cliente_id
   WHERE m.producto_id = _producto AND m.cantidad < 0 AND m.tipo = 'venta'
     AND m.fecha_efectiva BETWEEN coalesce(_desde, '1900-01-01') AND coalesce(_hasta, '2999-12-31')
   GROUP BY 1, 2, 3;
END;
$$;
REVOKE ALL ON FUNCTION public.salidas_por_cliente_mes(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.salidas_por_cliente_mes(uuid, date, date) TO authenticated;

-- ── 9. Saldos atípicos (se reportan, no se corrigen solos) ─────────────────
CREATE OR REPLACE FUNCTION public.saldos_atipicos_refacciones(_incluir_prueba boolean DEFAULT false)
RETURNS TABLE (producto_id uuid, codigo text, linea text, existencia integer, apartado integer,
               tipo text, gravedad text, detalle text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.puede_leer_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sin acceso';
  END IF;
  RETURN QUERY
  WITH base AS (
    SELECT p.id, p.codigo_nuevo, p.linea_catalogo, p.stock, public.stock_bloqueado_producto(p.id) AS apartado,
           public.saldo_inicial_sin_documento(p.id) AS ini, a.clave AS alm, a.activo AS alm_activo
      FROM public.almacen_refacciones_productos p
      LEFT JOIN public.inventario_almacenes a ON a.clave = p.linea_catalogo
     WHERE (coalesce(_incluir_prueba, false) OR NOT p.es_prueba)
       AND (p.es_prueba OR NOT public.es_usuario_prueba(auth.uid()))
  )
  SELECT id, codigo_nuevo, linea_catalogo, stock, apartado, 'existencia_negativa', 'alta',
         'Existencia negativa: ' || stock FROM base WHERE stock < 0
  UNION ALL
  SELECT id, codigo_nuevo, linea_catalogo, stock, apartado, 'linea_sin_almacen', 'alta',
         'La línea «' || linea_catalogo || '» no está en el catálogo de almacenes' FROM base WHERE alm IS NULL
  UNION ALL
  SELECT id, codigo_nuevo, linea_catalogo, stock, apartado, 'existencia_en_almacen_inactivo', 'media',
         'Tiene existencia en un almacén inactivo' FROM base WHERE alm IS NOT NULL AND NOT alm_activo AND stock <> 0
  UNION ALL
  SELECT id, codigo_nuevo, linea_catalogo, stock, apartado, 'apartado_mayor_existencia', 'alta',
         'Apartado (' || apartado || ') mayor que la existencia (' || stock || '): Almacén no podrá surtir todo'
    FROM base WHERE apartado > stock
  UNION ALL
  SELECT id, codigo_nuevo, linea_catalogo, stock, apartado, 'movimientos_exceden_existencia', 'alta',
         'Los movimientos registrados suman ' || (stock - ini) || ' y la existencia es ' || stock || ': falta explicar ' || (-ini)
    FROM base WHERE ini < 0
  UNION ALL
  SELECT b.id, b.codigo_nuevo, b.linea_catalogo, b.stock, b.apartado, 'movimiento_en_otro_almacen', 'alta',
         count(*) || ' movimiento(s) registrados en ' || string_agg(DISTINCT m.almacen, ', ')
    FROM base b JOIN public.almacen_refacciones_movimientos m ON m.producto_id = b.id
   WHERE m.almacen IS DISTINCT FROM b.linea_catalogo
   GROUP BY b.id, b.codigo_nuevo, b.linea_catalogo, b.stock, b.apartado
  UNION ALL
  SELECT id, codigo_nuevo, linea_catalogo, stock, apartado, 'saldo_inicial_sin_documento', 'info',
         ini || ' de la existencia no tiene documento (viene de una carga de lista de precios)'
    FROM base WHERE ini > 0;
END;
$$;
REVOKE ALL ON FUNCTION public.saldos_atipicos_refacciones(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.saldos_atipicos_refacciones(boolean) TO authenticated;

-- ── 10. Compatibilidades: unificar variantes y buscar sin importar guiones ─
CREATE OR REPLACE FUNCTION public.normalizar_modelo_refaccion(_t text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(regexp_replace(coalesce(_t, ''), '[^[:alnum:]]', '', 'g'))
$$;
GRANT EXECUTE ON FUNCTION public.normalizar_modelo_refaccion(text) TO authenticated;

ALTER TABLE public.almacen_refacciones_unidades
  ADD COLUMN IF NOT EXISTS fusionada_en uuid REFERENCES public.almacen_refacciones_unidades(id),
  ADD COLUMN IF NOT EXISTS fusionada_at timestamptz,
  ADD COLUMN IF NOT EXISTS fusionada_por uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.almacen_refacciones_unidad_alias (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unidad_id         uuid NOT NULL REFERENCES public.almacen_refacciones_unidades(id) ON DELETE CASCADE,
  alias             text NOT NULL,
  alias_normalizado text NOT NULL,
  origen_unidad_id  uuid,
  created_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT unidad_alias_unico UNIQUE (alias)
);
CREATE INDEX IF NOT EXISTS idx_unidad_alias_norm ON public.almacen_refacciones_unidad_alias (alias_normalizado);
ALTER TABLE public.almacen_refacciones_unidad_alias ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS unidad_alias_leer ON public.almacen_refacciones_unidad_alias;
CREATE POLICY unidad_alias_leer ON public.almacen_refacciones_unidad_alias
  FOR SELECT TO authenticated
  USING (public.puede_ver_almacen_refacciones() OR public.puede_leer_compras_inventario(auth.uid()));
GRANT SELECT ON public.almacen_refacciones_unidad_alias TO authenticated;

-- Si la importación de la lista de precios vuelve a ligar una variante ya
-- unificada, el vínculo se redirige solo al modelo final.
CREATE OR REPLACE FUNCTION public.redirigir_compat_unificada()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dest uuid;
  v_vueltas integer := 0;
BEGIN
  SELECT fusionada_en INTO v_dest FROM public.almacen_refacciones_unidades WHERE id = NEW.unidad_id;
  WHILE v_dest IS NOT NULL AND v_vueltas < 10 LOOP
    NEW.unidad_id := v_dest;
    SELECT fusionada_en INTO v_dest FROM public.almacen_refacciones_unidades WHERE id = NEW.unidad_id;
    v_vueltas := v_vueltas + 1;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.almacen_refacciones_producto_compat
              WHERE producto_id = NEW.producto_id AND unidad_id = NEW.unidad_id) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_redirigir_compat_unificada ON public.almacen_refacciones_producto_compat;
CREATE TRIGGER trg_redirigir_compat_unificada
  BEFORE INSERT ON public.almacen_refacciones_producto_compat
  FOR EACH ROW EXECUTE FUNCTION public.redirigir_compat_unificada();

CREATE OR REPLACE FUNCTION public.unificar_unidades_refacciones(_destino uuid, _origenes uuid[], _nombre_final text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dest public.almacen_refacciones_unidades%ROWTYPE;
  v_o public.almacen_refacciones_unidades%ROWTYPE;
  v_movidos integer := 0;
  v_n integer;
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador unifica compatibilidades';
  END IF;
  SELECT * INTO v_dest FROM public.almacen_refacciones_unidades WHERE id = _destino FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige el modelo que se queda'; END IF;
  IF v_dest.fusionada_en IS NOT NULL THEN RAISE EXCEPTION 'Ese modelo ya fue unificado en otro'; END IF;
  PERFORM public.exigir_dato_prueba(v_dest.es_prueba, 'el modelo ' || v_dest.nombre);

  FOR v_o IN SELECT * FROM public.almacen_refacciones_unidades
              WHERE id = ANY(_origenes) AND id <> _destino FOR UPDATE LOOP
    IF v_o.fusionada_en IS NOT NULL THEN CONTINUE; END IF;
    PERFORM public.exigir_dato_prueba(v_o.es_prueba, 'el modelo ' || v_o.nombre);
    INSERT INTO public.almacen_refacciones_producto_compat (producto_id, unidad_id, texto_origen)
    SELECT producto_id, _destino, coalesce(texto_origen, v_o.nombre)
      FROM public.almacen_refacciones_producto_compat WHERE unidad_id = v_o.id
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    DELETE FROM public.almacen_refacciones_producto_compat WHERE unidad_id = v_o.id;
    v_movidos := v_movidos + v_n;
    INSERT INTO public.almacen_refacciones_unidad_alias (unidad_id, alias, alias_normalizado, origen_unidad_id, created_by)
    VALUES (_destino, v_o.nombre, public.normalizar_modelo_refaccion(v_o.nombre), v_o.id, auth.uid())
    ON CONFLICT (alias) DO UPDATE SET unidad_id = EXCLUDED.unidad_id;
    -- Los alias que ya traía la variante se van con ella.
    UPDATE public.almacen_refacciones_unidad_alias SET unidad_id = _destino WHERE unidad_id = v_o.id;
    UPDATE public.almacen_refacciones_unidades
       SET fusionada_en = _destino, fusionada_at = now(), fusionada_por = auth.uid()
     WHERE id = v_o.id;
    -- Lo que antes apuntaba a la variante, ahora apunta al final.
    UPDATE public.almacen_refacciones_unidades SET fusionada_en = _destino WHERE fusionada_en = v_o.id;
  END LOOP;

  IF nullif(trim(_nombre_final), '') IS NOT NULL AND trim(_nombre_final) <> v_dest.nombre THEN
    INSERT INTO public.almacen_refacciones_unidad_alias (unidad_id, alias, alias_normalizado, origen_unidad_id, created_by)
    VALUES (_destino, v_dest.nombre, public.normalizar_modelo_refaccion(v_dest.nombre), _destino, auth.uid())
    ON CONFLICT (alias) DO NOTHING;
    UPDATE public.almacen_refacciones_unidades SET nombre = trim(_nombre_final) WHERE id = _destino;
  END IF;

  PERFORM public.registrar_bitacora_compras('inventario', 'unificar_compatibilidades', 'almacen_refacciones_unidades',
    _destino, coalesce(nullif(trim(_nombre_final), ''), v_dest.nombre),
    jsonb_build_object('origenes', _origenes, 'vinculos_movidos', v_movidos), v_prueba OR v_dest.es_prueba);
  RETURN jsonb_build_object('vinculos_movidos', v_movidos);
END;
$$;
REVOKE ALL ON FUNCTION public.unificar_unidades_refacciones(uuid, uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unificar_unidades_refacciones(uuid, uuid[], text) TO authenticated;

-- Búsqueda tolerante: FT180 encuentra FT-180 y «FT 180», también por alias.
CREATE OR REPLACE FUNCTION public.buscar_modelos_refacciones(_q text)
RETURNS TABLE (id uuid, nombre text, piezas integer, coincide_por text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.id, u.nombre,
         (SELECT count(*)::integer FROM public.almacen_refacciones_producto_compat pc WHERE pc.unidad_id = u.id),
         CASE WHEN public.normalizar_modelo_refaccion(u.nombre) LIKE '%' || public.normalizar_modelo_refaccion(_q) || '%'
              THEN 'nombre' ELSE 'alias' END
    FROM public.almacen_refacciones_unidades u
   WHERE u.fusionada_en IS NULL
     AND (public.puede_ver_almacen_refacciones() OR public.puede_leer_compras_inventario(auth.uid()))
     AND (
       public.normalizar_modelo_refaccion(u.nombre) LIKE '%' || public.normalizar_modelo_refaccion(_q) || '%'
       OR EXISTS (SELECT 1 FROM public.almacen_refacciones_unidad_alias a
                   WHERE a.unidad_id = u.id
                     AND a.alias_normalizado LIKE '%' || public.normalizar_modelo_refaccion(_q) || '%')
     )
   ORDER BY u.nombre
   LIMIT 200
$$;
REVOKE ALL ON FUNCTION public.buscar_modelos_refacciones(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.buscar_modelos_refacciones(text) TO authenticated;

-- ── 11. Postflight ──────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF to_regprocedure('public.confirmar_compra_refacciones(uuid)') IS NULL
     OR to_regprocedure('public.aplicar_ajuste_rapido(text,date,text,text,jsonb,text,text)') IS NULL
     OR to_regprocedure('public.kardex_refaccion(uuid,date,date)') IS NULL THEN
    RAISE EXCEPTION 'No quedaron las funciones de compras / ajustes / kárdex';
  END IF;
END $postflight$;

NOTIFY pgrst, 'reload schema';
