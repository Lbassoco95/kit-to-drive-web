-- ============================================================================
-- Documento de recepción de inventario y ajuste de la compra
-- ----------------------------------------------------------------------------
-- Al cargar inventario (contenedor, Excel o partes) queda un documento de
-- qué llegó en ese contenedor. Si el documento se liga a una compra, lo
-- recibido se acumula sobre esa compra. Si llegó de menos, Compras puede
-- cerrar la línea en lo recibido o dejar el faltante pendiente.
--
-- Idempotente. Pensado para el SQL editor de Supabase, no para db push.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.contenedores') IS NULL THEN
    _faltan := _faltan || 'tabla contenedores'::text;
  END IF;
  IF to_regclass('public.proveedores') IS NULL THEN
    _faltan := _faltan || 'tabla proveedores (corre 20260823000004)'::text;
  END IF;
  IF to_regprocedure('public.has_role(uuid,public.app_role)') IS NULL THEN
    _faltan := _faltan || 'has_role(uuid,app_role)'::text;
  END IF;
  IF to_regprocedure('public.set_updated_at()') IS NULL THEN
    _faltan := _faltan || 'set_updated_at()'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;


-- ============================================================================
-- Compras: lo que se pidió, contra lo que va llegando por contenedor
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.compras (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio           text NOT NULL,
  proveedor_id    uuid REFERENCES public.proveedores(id) ON DELETE SET NULL,
  contenedor_id   uuid REFERENCES public.contenedores(id) ON DELETE SET NULL,
  fecha           date NOT NULL DEFAULT CURRENT_DATE,
  estatus         text NOT NULL DEFAULT 'abierta',
  notas           text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT compras_folio_unico UNIQUE (folio),
  CONSTRAINT compras_estatus_chk CHECK (estatus IN ('abierta', 'parcial', 'completa', 'ajustada'))
);

CREATE INDEX IF NOT EXISTS idx_compras_estatus ON public.compras (estatus, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_compras_contenedor ON public.compras (contenedor_id);

CREATE TABLE IF NOT EXISTS public.compra_lineas (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compra_id          uuid NOT NULL REFERENCES public.compras(id) ON DELETE CASCADE,
  tipo               text NOT NULL,
  descripcion        text,
  modelo             text,
  color              text,
  cantidad_pedida    integer NOT NULL,
  cantidad_recibida  integer NOT NULL DEFAULT 0,
  -- Si se acepta un faltante, este es el nuevo objetivo. La pedida original
  -- no se borra: sigue diciendo cuánto se ordenó.
  cantidad_ajustada  integer,
  estatus            text NOT NULL DEFAULT 'pendiente',
  notas              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT compra_lineas_tipo_chk CHECK (tipo IN ('chasis', 'motor', 'parte', 'unidad')),
  CONSTRAINT compra_lineas_estatus_chk CHECK (estatus IN ('pendiente', 'parcial', 'completa', 'ajustada')),
  CONSTRAINT compra_lineas_pedida_pos CHECK (cantidad_pedida > 0),
  CONSTRAINT compra_lineas_recibida_no_neg CHECK (cantidad_recibida >= 0),
  CONSTRAINT compra_lineas_ajustada_no_neg CHECK (cantidad_ajustada IS NULL OR cantidad_ajustada >= 0)
);

CREATE INDEX IF NOT EXISTS idx_compra_lineas_compra ON public.compra_lineas (compra_id);

ALTER TABLE public.compras ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.compra_lineas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "leer compras" ON public.compras;
CREATE POLICY "leer compras" ON public.compras
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "leer compra lineas" ON public.compra_lineas;
CREATE POLICY "leer compra lineas" ON public.compra_lineas
  FOR SELECT TO authenticated USING (true);

DROP TRIGGER IF EXISTS trg_compras_updated ON public.compras;
CREATE TRIGGER trg_compras_updated
  BEFORE UPDATE ON public.compras
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_compra_lineas_updated ON public.compra_lineas;
CREATE TRIGGER trg_compra_lineas_updated
  BEFORE UPDATE ON public.compra_lineas
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ============================================================================
-- Documento que queda cada vez que se carga inventario de un contenedor
-- ============================================================================

CREATE SEQUENCE IF NOT EXISTS public.documentos_inventario_folio_seq;

CREATE TABLE IF NOT EXISTS public.documentos_inventario (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio             text NOT NULL,
  contenedor_id     uuid NOT NULL REFERENCES public.contenedores(id) ON DELETE RESTRICT,
  folio_contenedor  text NOT NULL,
  compra_id         uuid REFERENCES public.compras(id) ON DELETE SET NULL,
  origen            text NOT NULL,
  fecha             date NOT NULL DEFAULT CURRENT_DATE,
  notas             text,
  created_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT documentos_inventario_folio_unico UNIQUE (folio),
  CONSTRAINT documentos_inventario_origen_chk CHECK (origen IN ('excel', 'manual', 'partes'))
);

CREATE INDEX IF NOT EXISTS idx_documentos_inventario_contenedor
  ON public.documentos_inventario (contenedor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_documentos_inventario_compra
  ON public.documentos_inventario (compra_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.documento_inventario_lineas (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  documento_id        uuid NOT NULL REFERENCES public.documentos_inventario(id) ON DELETE CASCADE,
  compra_linea_id     uuid REFERENCES public.compra_lineas(id) ON DELETE SET NULL,
  tipo                text NOT NULL,
  clave               text NOT NULL,
  modelo              text,
  color               text,
  cantidad_esperada   integer NOT NULL DEFAULT 0,
  cantidad_recibida   integer NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT documento_inventario_lineas_tipo_chk CHECK (tipo IN ('chasis', 'motor', 'parte', 'unidad')),
  CONSTRAINT documento_inventario_lineas_cantidades_chk
    CHECK (cantidad_esperada >= 0 AND cantidad_recibida >= 0)
);

CREATE INDEX IF NOT EXISTS idx_documento_inventario_lineas_doc
  ON public.documento_inventario_lineas (documento_id);
CREATE INDEX IF NOT EXISTS idx_documento_inventario_lineas_compra
  ON public.documento_inventario_lineas (compra_linea_id);

ALTER TABLE public.documentos_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documento_inventario_lineas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "leer documentos inventario" ON public.documentos_inventario;
CREATE POLICY "leer documentos inventario" ON public.documentos_inventario
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "leer documento inventario lineas" ON public.documento_inventario_lineas;
CREATE POLICY "leer documento inventario lineas" ON public.documento_inventario_lineas
  FOR SELECT TO authenticated USING (true);

GRANT SELECT ON public.compras, public.compra_lineas,
  public.documentos_inventario, public.documento_inventario_lineas
  TO authenticated;


-- ============================================================================
-- Lo recibido de una compra se recalcula desde los documentos, no se suma
-- a ciegas: el último documento de cada contenedor y clave reemplaza al
-- anterior. Volver a cargar el mismo VIN no infla la compra.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._recalcular_compra(_compra_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _estatus text;
  _alguna_actividad boolean;
  _algun_ajuste boolean;
  _todas_cubiertas boolean;
BEGIN
  -- El último documento de cada contenedor y clave es el que cuenta.
  -- Volver a cargar el mismo serial no suma otra vez.
  UPDATE public.compra_lineas cl
     SET cantidad_recibida = COALESCE((
           SELECT SUM(dl.cantidad_recibida)::int
             FROM (
               SELECT DISTINCT ON (d.contenedor_id, lower(prev.clave))
                      d.id AS documento_id,
                      lower(prev.clave) AS clave
                 FROM public.documento_inventario_lineas prev
                 JOIN public.documentos_inventario d ON d.id = prev.documento_id
                WHERE d.compra_id = _compra_id
                  AND prev.compra_linea_id = cl.id
                ORDER BY d.contenedor_id, lower(prev.clave), d.created_at DESC, d.id DESC
             ) marca
             JOIN public.documento_inventario_lineas dl
               ON dl.documento_id = marca.documento_id
              AND dl.compra_linea_id = cl.id
              AND lower(dl.clave) = marca.clave
         ), 0)
   WHERE cl.compra_id = _compra_id;

  UPDATE public.compra_lineas cl
     SET estatus = CASE
           WHEN cl.cantidad_recibida >= COALESCE(cl.cantidad_ajustada, cl.cantidad_pedida)
                AND cl.cantidad_ajustada IS NOT NULL
                AND cl.cantidad_ajustada < cl.cantidad_pedida THEN 'ajustada'
           WHEN cl.cantidad_recibida >= COALESCE(cl.cantidad_ajustada, cl.cantidad_pedida) THEN 'completa'
           WHEN cl.cantidad_recibida = 0 AND cl.cantidad_ajustada IS NULL THEN 'pendiente'
           ELSE 'parcial'
         END
   WHERE cl.compra_id = _compra_id;

  SELECT
    COALESCE(bool_or(cantidad_recibida > 0 OR cantidad_ajustada IS NOT NULL), false),
    COALESCE(bool_or(cantidad_ajustada IS NOT NULL AND cantidad_ajustada < cantidad_pedida), false),
    COALESCE(bool_and(cantidad_recibida >= COALESCE(cantidad_ajustada, cantidad_pedida)), true)
    INTO _alguna_actividad, _algun_ajuste, _todas_cubiertas
    FROM public.compra_lineas
   WHERE compra_id = _compra_id;

  IF NOT EXISTS (SELECT 1 FROM public.compra_lineas WHERE compra_id = _compra_id) THEN
    _estatus := 'abierta';
  ELSIF _todas_cubiertas AND _algun_ajuste THEN
    _estatus := 'ajustada';
  ELSIF _todas_cubiertas THEN
    _estatus := 'completa';
  ELSIF NOT _alguna_actividad THEN
    _estatus := 'abierta';
  ELSE
    _estatus := 'parcial';
  END IF;

  UPDATE public.compras SET estatus = _estatus WHERE id = _compra_id;
  RETURN _estatus;
END;
$$;

REVOKE ALL ON FUNCTION public._recalcular_compra(uuid) FROM PUBLIC, anon, authenticated;


CREATE OR REPLACE FUNCTION public._puede_cargar_inventario(_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.has_role(_uid, 'admin')
      OR public.has_role(_uid, 'fabrica')
      OR public.has_role(_uid, 'logistica');
$$;

CREATE OR REPLACE FUNCTION public._puede_capturar_compra(_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.has_role(_uid, 'admin')
      OR public.has_role(_uid, 'compras')
      OR public.has_role(_uid, 'admin_financiero')
      OR public.has_role(_uid, 'fabrica');
$$;

CREATE OR REPLACE FUNCTION public._puede_ajustar_compra(_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.has_role(_uid, 'admin')
      OR public.has_role(_uid, 'compras')
      OR public.has_role(_uid, 'admin_financiero');
$$;

REVOKE ALL ON FUNCTION public._puede_cargar_inventario(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._puede_capturar_compra(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._puede_ajustar_compra(uuid) FROM PUBLIC, anon, authenticated;


-- ============================================================================
-- Alta de la compra (lo pedido)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.crear_compra(
  _folio text,
  _proveedor_id uuid,
  _contenedor_id uuid,
  _fecha date,
  _notas text,
  _lineas jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _id uuid;
  _folio_limpio text;
  _p jsonb;
  _tipo text;
  _desc text;
  _modelo text;
  _color text;
  _pedida int;
  _n int := 0;
BEGIN
  IF NOT public._puede_capturar_compra(auth.uid()) THEN
    RAISE EXCEPTION 'Solo Compras, Fábrica o un administrador puede capturar una compra';
  END IF;

  _folio_limpio := NULLIF(trim(COALESCE(_folio, '')), '');
  IF _folio_limpio IS NULL OR length(_folio_limpio) > 50 THEN
    RAISE EXCEPTION 'Folio de compra requerido (máximo 50 caracteres)';
  END IF;
  IF EXISTS (SELECT 1 FROM public.compras WHERE folio = _folio_limpio) THEN
    RAISE EXCEPTION 'Ya existe una compra con el folio %', _folio_limpio;
  END IF;
  IF _proveedor_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.proveedores WHERE id = _proveedor_id) THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;
  IF _contenedor_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.contenedores WHERE id = _contenedor_id) THEN
    RAISE EXCEPTION 'Contenedor no encontrado';
  END IF;
  IF _lineas IS NULL OR jsonb_typeof(_lineas) <> 'array' OR jsonb_array_length(_lineas) = 0 THEN
    RAISE EXCEPTION 'La compra necesita al menos una línea';
  END IF;

  INSERT INTO public.compras (folio, proveedor_id, contenedor_id, fecha, notas, created_by)
  VALUES (
    _folio_limpio,
    _proveedor_id,
    _contenedor_id,
    COALESCE(_fecha, CURRENT_DATE),
    NULLIF(trim(COALESCE(_notas, '')), ''),
    auth.uid()
  )
  RETURNING id INTO _id;

  FOR _p IN SELECT * FROM jsonb_array_elements(_lineas) LOOP
    _tipo := lower(NULLIF(trim(COALESCE(_p->>'tipo', '')), ''));
    _desc := NULLIF(trim(COALESCE(_p->>'descripcion', '')), '');
    _modelo := NULLIF(trim(COALESCE(_p->>'modelo', '')), '');
    _color := NULLIF(upper(trim(COALESCE(_p->>'color', ''))), '');
    _pedida := COALESCE((_p->>'cantidad_pedida')::int, 0);

    IF _tipo IS NULL OR _tipo NOT IN ('chasis', 'motor', 'parte', 'unidad') THEN
      RAISE EXCEPTION 'Tipo de línea inválido (chasis, motor, parte o unidad)';
    END IF;
    IF _desc IS NULL AND _modelo IS NULL THEN
      RAISE EXCEPTION 'Cada línea necesita descripción o modelo';
    END IF;
    IF _pedida <= 0 OR _pedida > 100000 THEN
      RAISE EXCEPTION 'La cantidad pedida debe estar entre 1 y 100000';
    END IF;

    INSERT INTO public.compra_lineas (compra_id, tipo, descripcion, modelo, color, cantidad_pedida)
    VALUES (_id, _tipo, _desc, _modelo, _color, _pedida);
    _n := _n + 1;
  END LOOP;

  PERFORM public._recalcular_compra(_id);

  RETURN jsonb_build_object('ok', true, 'compra_id', _id, 'folio', _folio_limpio, 'lineas', _n);
END;
$$;

REVOKE ALL ON FUNCTION public.crear_compra(text, uuid, uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_compra(text, uuid, uuid, date, text, jsonb) TO authenticated;


-- ============================================================================
-- Documento de lo que llegó en un contenedor. Si hay compra, actualiza
-- esa compra y devuelve las líneas que siguen cortas.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.registrar_documento_inventario(
  _contenedor_id uuid,
  _compra_id uuid,
  _origen text,
  _notas text,
  _lineas jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _doc uuid;
  _folio text;
  _folio_cont text;
  _origen_limpio text;
  _p jsonb;
  _tipo text;
  _clave text;
  _modelo text;
  _color text;
  _esperada int;
  _recibida int;
  _linea_id uuid;
  _n_tipo int;
  _insertadas int := 0;
  _sin_emparejar int := 0;
  _estatus text;
  _faltantes jsonb;
BEGIN
  IF NOT public._puede_cargar_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Solo Fábrica, Almacén o un administrador puede documentar una carga de inventario';
  END IF;

  IF _contenedor_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.contenedores WHERE id = _contenedor_id) THEN
    RAISE EXCEPTION 'Contenedor no encontrado';
  END IF;

  _origen_limpio := lower(NULLIF(trim(COALESCE(_origen, '')), ''));
  IF _origen_limpio IS NULL OR _origen_limpio NOT IN ('excel', 'manual', 'partes') THEN
    RAISE EXCEPTION 'Origen de carga inválido';
  END IF;

  IF _compra_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.compras WHERE id = _compra_id) THEN
    RAISE EXCEPTION 'Compra no encontrada';
  END IF;

  IF _lineas IS NULL OR jsonb_typeof(_lineas) <> 'array' OR jsonb_array_length(_lineas) = 0 THEN
    RAISE EXCEPTION 'El documento necesita al menos una línea de lo recibido';
  END IF;

  SELECT folio_contenedor INTO _folio_cont FROM public.contenedores WHERE id = _contenedor_id;

  _folio := 'DOC-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-'
         || lpad(nextval('public.documentos_inventario_folio_seq')::text, 4, '0');

  INSERT INTO public.documentos_inventario (
    folio, contenedor_id, folio_contenedor, compra_id, origen, fecha, notas, created_by
  ) VALUES (
    _folio, _contenedor_id, _folio_cont, _compra_id, _origen_limpio, CURRENT_DATE,
    NULLIF(trim(COALESCE(_notas, '')), ''), auth.uid()
  )
  RETURNING id INTO _doc;

  FOR _p IN SELECT * FROM jsonb_array_elements(_lineas) LOOP
    _tipo := lower(NULLIF(trim(COALESCE(_p->>'tipo', '')), ''));
    _clave := NULLIF(trim(COALESCE(_p->>'clave', '')), '');
    _modelo := NULLIF(trim(COALESCE(_p->>'modelo', '')), '');
    _color := NULLIF(upper(trim(COALESCE(_p->>'color', ''))), '');
    _esperada := GREATEST(COALESCE((_p->>'cantidad_esperada')::int, 0), 0);
    _recibida := GREATEST(COALESCE((_p->>'cantidad_recibida')::int, 0), 0);
    _linea_id := NULL;

    IF _tipo IS NULL OR _tipo NOT IN ('chasis', 'motor', 'parte', 'unidad') THEN
      RAISE EXCEPTION 'Tipo de línea inválido en el documento';
    END IF;
    IF _clave IS NULL THEN
      CONTINUE;
    END IF;
    IF _tipo IN ('chasis', 'motor', 'unidad') THEN
      _clave := upper(_clave);
    END IF;

    IF _compra_id IS NOT NULL THEN
      SELECT cl.id INTO _linea_id
        FROM public.compra_lineas cl
       WHERE cl.compra_id = _compra_id
         AND cl.tipo = _tipo
         AND (
           (cl.descripcion IS NOT NULL AND lower(cl.descripcion) = lower(_clave))
           OR (cl.modelo IS NOT NULL AND _modelo IS NOT NULL AND lower(cl.modelo) = lower(_modelo))
         )
       ORDER BY
         CASE WHEN cl.descripcion IS NOT NULL AND lower(cl.descripcion) = lower(_clave) THEN 0 ELSE 1 END,
         CASE WHEN cl.modelo IS NOT NULL AND _modelo IS NOT NULL AND lower(cl.modelo) = lower(_modelo) THEN 0 ELSE 1 END,
         cl.created_at
       LIMIT 1;

      IF _linea_id IS NULL THEN
        SELECT count(*) INTO _n_tipo
          FROM public.compra_lineas
         WHERE compra_id = _compra_id AND tipo = _tipo;
        IF _n_tipo = 1 THEN
          SELECT id INTO _linea_id
            FROM public.compra_lineas
           WHERE compra_id = _compra_id AND tipo = _tipo;
        ELSE
          _sin_emparejar := _sin_emparejar + 1;
        END IF;
      END IF;
    END IF;

    INSERT INTO public.documento_inventario_lineas (
      documento_id, compra_linea_id, tipo, clave, modelo, color, cantidad_esperada, cantidad_recibida
    ) VALUES (
      _doc, _linea_id, _tipo, _clave, _modelo, _color, _esperada, _recibida
    );
    _insertadas := _insertadas + 1;
  END LOOP;

  IF _insertadas = 0 THEN
    RAISE EXCEPTION 'Ninguna línea del documento tenía identificador';
  END IF;

  _estatus := NULL;
  _faltantes := '[]'::jsonb;
  IF _compra_id IS NOT NULL THEN
    _estatus := public._recalcular_compra(_compra_id);
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'linea_id', cl.id,
             'tipo', cl.tipo,
             'descripcion', COALESCE(cl.descripcion, cl.modelo, cl.tipo),
             'modelo', cl.modelo,
             'pedida', cl.cantidad_pedida,
             'recibida', cl.cantidad_recibida,
             'objetivo', COALESCE(cl.cantidad_ajustada, cl.cantidad_pedida),
             'diferencia', COALESCE(cl.cantidad_ajustada, cl.cantidad_pedida) - cl.cantidad_recibida
           )), '[]'::jsonb)
      INTO _faltantes
      FROM public.compra_lineas cl
     WHERE cl.compra_id = _compra_id
       AND cl.cantidad_recibida < COALESCE(cl.cantidad_ajustada, cl.cantidad_pedida);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'documento_id', _doc,
    'folio', _folio,
    'folio_contenedor', _folio_cont,
    'compra_id', _compra_id,
    'estatus_compra', _estatus,
    'lineas', _insertadas,
    'sin_emparejar', _sin_emparejar,
    'faltantes', _faltantes
  );
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_documento_inventario(uuid, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_documento_inventario(uuid, uuid, text, text, jsonb) TO authenticated;


-- ============================================================================
-- Ajuste de UNA compra cuando llegó de menos.
--   aceptar_llegada   — el objetivo pasa a ser lo recibido; la pedida original queda
--   seguir_pendiente  — se reabre el faltante contra lo pedido original
-- ============================================================================

CREATE OR REPLACE FUNCTION public.ajustar_compra_faltante(
  _compra_linea_id uuid,
  _accion text,
  _notas text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _linea public.compra_lineas%ROWTYPE;
  _accion_limpia text;
  _estatus text;
  _nota text;
BEGIN
  IF NOT public._puede_ajustar_compra(auth.uid()) THEN
    RAISE EXCEPTION 'Solo Compras o un administrador puede ajustar una compra';
  END IF;

  SELECT * INTO _linea FROM public.compra_lineas WHERE id = _compra_linea_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La línea de compra no existe';
  END IF;

  _accion_limpia := lower(NULLIF(trim(COALESCE(_accion, '')), ''));
  _nota := NULLIF(trim(COALESCE(_notas, '')), '');

  IF _accion_limpia = 'aceptar_llegada' THEN
    IF _linea.cantidad_recibida >= _linea.cantidad_pedida
       AND (_linea.cantidad_ajustada IS NULL OR _linea.cantidad_ajustada >= _linea.cantidad_pedida) THEN
      RAISE EXCEPTION 'Esa línea no tiene faltante: ya llegó lo pedido';
    END IF;
    UPDATE public.compra_lineas
       SET cantidad_ajustada = cantidad_recibida,
           notas = CASE
             WHEN _nota IS NULL THEN notas
             ELSE concat_ws(E'\n', NULLIF(notas, ''), _nota)
           END
     WHERE id = _linea.id;
  ELSIF _accion_limpia = 'seguir_pendiente' THEN
    UPDATE public.compra_lineas
       SET cantidad_ajustada = NULL,
           notas = CASE
             WHEN _nota IS NULL THEN notas
             ELSE concat_ws(E'\n', NULLIF(notas, ''), _nota)
           END
     WHERE id = _linea.id;
  ELSE
    RAISE EXCEPTION 'Acción inválida: usa aceptar_llegada o seguir_pendiente';
  END IF;

  _estatus := public._recalcular_compra(_linea.compra_id);

  RETURN jsonb_build_object(
    'ok', true,
    'compra_id', _linea.compra_id,
    'linea_id', _linea.id,
    'estatus', _estatus,
    'accion', _accion_limpia
  );
END;
$$;

REVOKE ALL ON FUNCTION public.ajustar_compra_faltante(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ajustar_compra_faltante(uuid, text, text) TO authenticated;


-- ============================================================================
-- Verificación: si algo no quedó, el script avisa en vez de parecer que sí
-- ============================================================================

DO $verificar$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.compras') IS NULL THEN
    _faltan := _faltan || 'tabla compras'::text; END IF;
  IF to_regclass('public.compra_lineas') IS NULL THEN
    _faltan := _faltan || 'tabla compra_lineas'::text; END IF;
  IF to_regclass('public.documentos_inventario') IS NULL THEN
    _faltan := _faltan || 'tabla documentos_inventario'::text; END IF;
  IF to_regclass('public.documento_inventario_lineas') IS NULL THEN
    _faltan := _faltan || 'tabla documento_inventario_lineas'::text; END IF;
  IF to_regprocedure('public.crear_compra(text,uuid,uuid,date,text,jsonb)') IS NULL THEN
    _faltan := _faltan || 'crear_compra'::text; END IF;
  IF to_regprocedure('public.registrar_documento_inventario(uuid,uuid,text,text,jsonb)') IS NULL THEN
    _faltan := _faltan || 'registrar_documento_inventario'::text; END IF;
  IF to_regprocedure('public.ajustar_compra_faltante(uuid,text,text)') IS NULL THEN
    _faltan := _faltan || 'ajustar_compra_faltante'::text; END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'El script no dejó: %', array_to_string(_faltan, ' | ');
  END IF;
END $verificar$;
