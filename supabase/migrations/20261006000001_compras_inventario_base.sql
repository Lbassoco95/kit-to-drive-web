-- ============================================================================
-- Compras e inventario (base) — 2026-10-06
-- ----------------------------------------------------------------------------
-- Lo que piden Compras (Martin) y Polo después de la sesión del 30-sep-2026:
--
--   · Catálogo editable de almacenes / líneas de refacciones. El almacén de un
--     artículo ES su `linea_catalogo` (hoy: linea_dorada, linea_azul,
--     ref_motocarro). Un artículo vive en un solo almacén: así no puede haber
--     «100 llantas en Dorado y −50 en Azul».
--   · Datos maestros nuevos del artículo: unidad de venta, piezas por unidad de
--     venta, piezas por caja cerrada. Todos opcionales / con valor por defecto.
--   · Movimientos de inventario con FECHA EFECTIVA (para ajustes retroactivos)
--     y el documento que los originó (compra, remisión, ajuste…).
--   · Marca «prueba» en clientes, artículos, almacenes, remisiones y
--     movimientos, más los candados cruzados (prueba ↔ real nunca se mezclan).
--   · Permisos: Compras / Almacén físico / Finanzas (cobranza), bitácora de
--     solo agregar y bucket privado para evidencias.
--
-- No cambia el flujo de motocarros ni el de gastos (pagos / movimientos
-- financieros). No reescribe funciones existentes: todo es aditivo.
--
-- Idempotente. Pensado para el SQL editor de Supabase, no para db push.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.almacen_refacciones_productos') IS NULL THEN
    _faltan := _faltan || 'tabla almacen_refacciones_productos (20260922000001)'::text;
  END IF;
  IF to_regclass('public.almacen_refacciones_movimientos') IS NULL THEN
    _faltan := _faltan || 'tabla almacen_refacciones_movimientos (20260922000001)'::text;
  END IF;
  IF to_regclass('public.remisiones_refacciones') IS NULL THEN
    _faltan := _faltan || 'tabla remisiones_refacciones (20260923000001)'::text;
  END IF;
  IF to_regprocedure('public.es_compras(uuid)') IS NULL THEN
    _faltan := _faltan || 'función es_compras (20260922000004)'::text;
  END IF;
  IF to_regprocedure('public.es_finanzas(uuid)') IS NULL THEN
    _faltan := _faltan || 'función es_finanzas (20260823000004)'::text;
  END IF;
  IF to_regprocedure('public.stock_bloqueado_producto(uuid)') IS NULL THEN
    _faltan := _faltan || 'función stock_bloqueado_producto (20260923000001)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;

-- ── 1. Permisos ─────────────────────────────────────────────────────────────
-- Compras / Inventario: área Compras, admin global o el rol legado admin.
CREATE OR REPLACE FUNCTION public.puede_compras_inventario(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL
     AND public.usuario_activo(_uid)
     AND (public.es_compras(_uid) OR public.has_role(_uid, 'admin'::public.app_role))
$$;

-- Almacén físico (conteo, recepción): quien ya surte refacciones (allowlist),
-- el área Almacén y logística, y Compras.
CREATE OR REPLACE FUNCTION public.puede_almacen_fisico(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL
     AND public.usuario_activo(_uid)
     AND (
       public.puede_ver_almacen_refacciones(_uid)
       OR public.es_area(_uid, 'almacen_logistica'::public.user_area)
       OR public.puede_compras_inventario(_uid)
     )
$$;

-- Finanzas en cobranza: valida evidencias y concilia.
CREATE OR REPLACE FUNCTION public.puede_finanzas_cobranza(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL
     AND public.usuario_activo(_uid)
     AND (public.es_finanzas(_uid) OR public.es_admin_global(_uid))
$$;

-- Lectura del módulo (reportes, kárdex, almacenes): Compras, Almacén físico,
-- Finanzas y Dirección.
CREATE OR REPLACE FUNCTION public.puede_leer_compras_inventario(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL
     AND public.usuario_activo(_uid)
     AND (
       public.puede_compras_inventario(_uid)
       OR public.puede_almacen_fisico(_uid)
       OR public.puede_finanzas_cobranza(_uid)
       OR public.es_area(_uid, 'direccion'::public.user_area)
     )
$$;

REVOKE ALL ON FUNCTION public.puede_compras_inventario(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_almacen_fisico(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_finanzas_cobranza(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_leer_compras_inventario(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_compras_inventario(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_almacen_fisico(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_finanzas_cobranza(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_leer_compras_inventario(uuid) TO authenticated;

-- ── 2. Parámetros editables ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.compras_parametros (
  clave       text PRIMARY KEY,
  valor       jsonb NOT NULL,
  descripcion text,
  updated_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.compras_parametros ENABLE ROW LEVEL SECURITY;

INSERT INTO public.compras_parametros (clave, valor, descripcion) VALUES
  ('abc_corte_a', '80', 'Clasificación ABC: la letra A llega hasta este % acumulado'),
  ('abc_corte_b', '95', 'Clasificación ABC: la letra B llega hasta este % acumulado (A 80 + B 15)'),
  ('concentracion_umbral_pct', '40', 'Kárdex: marca el mes cuando un cliente se lleva este % o más de las salidas'),
  ('cobertura_objetivo_meses', '{"A":3,"B":2,"C":1}', 'Sugerido de compra: meses de cobertura por letra de monto'),
  ('dias_transito', '60', 'Sugerido de compra: días que tarda un contenedor'),
  ('sugerido_redondeo', '"unidad_venta"', 'Sugerido: unidad_venta | caja'),
  ('saldo_favor_aplican', '["compras"]', 'Quién aplica un saldo a favor (compras, finanzas). Decisión de Polo (2026-10-07): sólo Compras; el administrador siempre. Finanzas lo ve y Ventas lo solicita.'),
  ('entrega_exige_pago', 'false', 'Si es true, Logística no cierra una entrega real sin pago validado o crédito. Los datos de prueba siempre lo exigen.')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.compras_parametro(_clave text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT valor FROM public.compras_parametros WHERE clave = _clave
$$;
REVOKE ALL ON FUNCTION public.compras_parametro(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compras_parametro(text) TO authenticated;

DROP POLICY IF EXISTS compras_parametros_leer ON public.compras_parametros;
CREATE POLICY compras_parametros_leer ON public.compras_parametros
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS compras_parametros_escribir ON public.compras_parametros;
CREATE POLICY compras_parametros_escribir ON public.compras_parametros
  FOR UPDATE TO authenticated
  USING (public.puede_compras_inventario(auth.uid()))
  WITH CHECK (public.puede_compras_inventario(auth.uid()));
GRANT SELECT, UPDATE ON public.compras_parametros TO authenticated;

-- ── 3. Bitácora de solo agregar ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.bitacora_compras_inventario (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  modulo      text NOT NULL CHECK (modulo IN ('inventario', 'cobranza', 'prueba')),
  accion      text NOT NULL,
  entidad     text,
  entidad_id  uuid,
  folio       text,
  detalle     jsonb NOT NULL DEFAULT '{}'::jsonb,
  es_prueba   boolean NOT NULL DEFAULT false,
  usuario_id  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_bitacora_compras_modulo
  ON public.bitacora_compras_inventario (modulo, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bitacora_compras_entidad
  ON public.bitacora_compras_inventario (entidad_id);
ALTER TABLE public.bitacora_compras_inventario ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.bitacora_solo_agregar()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- El reinicio de datos de prueba es lo único que borra, y sólo filas de prueba.
  IF TG_OP = 'DELETE' AND OLD.es_prueba AND current_setting('kit.reiniciando_prueba', true) = 'si' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'La bitácora no se edita ni se borra';
END;
$$;
DROP TRIGGER IF EXISTS trg_bitacora_compras_solo_agregar ON public.bitacora_compras_inventario;
CREATE TRIGGER trg_bitacora_compras_solo_agregar
  BEFORE UPDATE OR DELETE ON public.bitacora_compras_inventario
  FOR EACH ROW EXECUTE FUNCTION public.bitacora_solo_agregar();

CREATE OR REPLACE FUNCTION public.registrar_bitacora_compras(
  _modulo text, _accion text, _entidad text, _entidad_id uuid, _folio text,
  _detalle jsonb, _es_prueba boolean DEFAULT false
) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.bitacora_compras_inventario
    (modulo, accion, entidad, entidad_id, folio, detalle, es_prueba, usuario_id)
  VALUES (_modulo, _accion, _entidad, _entidad_id, _folio, coalesce(_detalle, '{}'::jsonb),
          coalesce(_es_prueba, false), auth.uid());
$$;
REVOKE ALL ON FUNCTION public.registrar_bitacora_compras(text, text, text, uuid, text, jsonb, boolean) FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS bitacora_compras_leer ON public.bitacora_compras_inventario;
CREATE POLICY bitacora_compras_leer ON public.bitacora_compras_inventario
  FOR SELECT TO authenticated
  USING (
    public.es_admin_global(auth.uid())
    OR public.has_role(auth.uid(), 'admin'::public.app_role)
    OR (modulo = 'cobranza' AND public.puede_finanzas_cobranza(auth.uid()))
    OR (modulo IN ('inventario', 'prueba') AND public.puede_compras_inventario(auth.uid()))
  );
GRANT SELECT ON public.bitacora_compras_inventario TO authenticated;

-- ── 4. Datos y usuarios de prueba ──────────────────────────────────────────
-- Lista explícita (no por dominio): un correo real nunca queda atrapado.
CREATE TABLE IF NOT EXISTS public.inventario_usuarios_prueba (
  email      text PRIMARY KEY,
  nota       text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.inventario_usuarios_prueba ENABLE ROW LEVEL SECURITY;
INSERT INTO public.inventario_usuarios_prueba (email, nota) VALUES
  ('prueba.compras@dazon.demo',   'Compras de prueba'),
  ('prueba.almacen@dazon.demo',   'Almacén de prueba'),
  ('prueba.finanzas@dazon.demo',  'Finanzas de prueba'),
  ('prueba.logistica@dazon.demo', 'Logística de prueba'),
  ('prueba.ventas@dazon.demo',    'Ventas de prueba'),
  ('prueba.admin@dazon.demo',     'Administrador de prueba'),
  ('prueba.super@dazon.demo',     'Super administrador de prueba: recorre todo el flujo')
ON CONFLICT (email) DO NOTHING;

CREATE OR REPLACE FUNCTION public.es_usuario_prueba(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM auth.users u
      JOIN public.inventario_usuarios_prueba p ON lower(p.email) = lower(u.email)
     WHERE u.id = _uid
  )
$$;
REVOKE ALL ON FUNCTION public.es_usuario_prueba(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_usuario_prueba(uuid) TO authenticated;

DROP POLICY IF EXISTS usuarios_prueba_leer ON public.inventario_usuarios_prueba;
CREATE POLICY usuarios_prueba_leer ON public.inventario_usuarios_prueba
  FOR SELECT TO authenticated USING (public.puede_compras_inventario(auth.uid()));
GRANT SELECT ON public.inventario_usuarios_prueba TO authenticated;

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;
ALTER TABLE public.almacen_refacciones_productos
  ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;
ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;

-- Un usuario de prueba sólo CONSULTA datos de prueba: guarda para las
-- funciones SECURITY DEFINER que reciben el id de un registro (kárdex, recibo,
-- estado de cobro…), que no pasan por la seguridad por filas.
CREATE OR REPLACE FUNCTION public.exigir_lectura_prueba(_tabla text, _id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v boolean;
BEGIN
  IF _id IS NULL OR NOT public.es_usuario_prueba(auth.uid()) THEN
    RETURN;
  END IF;
  IF _tabla NOT IN ('almacen_refacciones_productos', 'remisiones_refacciones', 'cobranza_pagos',
                    'cobranza_saldos_favor', 'clientes', 'compras_refacciones') THEN
    RAISE EXCEPTION 'exigir_lectura_prueba: tabla no permitida %', _tabla;
  END IF;
  EXECUTE format('SELECT es_prueba FROM public.%I WHERE id = $1', _tabla) INTO v USING _id;
  IF NOT coalesce(v, false) THEN
    RAISE EXCEPTION 'Estás en MODO PRUEBA: ese registro es real y un usuario de prueba no lo puede consultar.';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.exigir_lectura_prueba(text, uuid) FROM PUBLIC, anon, authenticated;

-- Un usuario de prueba sólo escribe sobre datos de prueba.
CREATE OR REPLACE FUNCTION public.exigir_dato_prueba(_es_prueba boolean, _que text)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF public.es_usuario_prueba(auth.uid()) AND NOT coalesce(_es_prueba, false) THEN
    RAISE EXCEPTION 'Estás en MODO PRUEBA: % es un dato real y un usuario de prueba no lo puede tocar.', _que;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.exigir_dato_prueba(boolean, text) FROM PUBLIC, anon, authenticated;

-- Lo que un usuario de prueba da de alta en Clientes nace como prueba, y no
-- puede editar clientes reales.
CREATE OR REPLACE FUNCTION public.cliente_marca_prueba()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF public.es_usuario_prueba(auth.uid()) THEN
    IF TG_OP = 'INSERT' THEN
      NEW.es_prueba := true;
    ELSIF NOT OLD.es_prueba THEN
      RAISE EXCEPTION 'Estás en MODO PRUEBA: no puedes modificar un cliente real.';
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.es_prueba IS DISTINCT FROM OLD.es_prueba
     AND current_setting('kit.reiniciando_prueba', true) IS DISTINCT FROM 'si' THEN
    RAISE EXCEPTION 'Un cliente no cambia entre real y prueba';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_cliente_marca_prueba ON public.clientes;
CREATE TRIGGER trg_cliente_marca_prueba
  BEFORE INSERT OR UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.cliente_marca_prueba();

-- ── 5. Almacenes / líneas ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.inventario_almacenes (
  clave          text PRIMARY KEY CHECK (clave ~ '^[a-z0-9_]{2,40}$'),
  nombre         text NOT NULL,
  descripcion    text,
  recibe_compras boolean NOT NULL DEFAULT false,
  es_refacciones boolean NOT NULL DEFAULT true,
  activo         boolean NOT NULL DEFAULT true,
  es_prueba      boolean NOT NULL DEFAULT false,
  orden          integer NOT NULL DEFAULT 100,
  created_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.inventario_almacenes ENABLE ROW LEVEL SECURITY;

INSERT INTO public.inventario_almacenes (clave, nombre, descripcion, recibe_compras, orden) VALUES
  ('linea_dorada',  'Línea dorada',   'Lo nuevo. Aquí llegan todas las compras.', true, 10),
  ('linea_azul',    'Línea azul',     'Lo anterior. Nunca recibe compras; sólo su carga inicial.', false, 20),
  ('ref_motocarro', 'Ref. motocarro', 'Refacciones de motocarro del catálogo de venta.', false, 30)
ON CONFLICT (clave) DO NOTHING;

-- Las líneas que ya usa el catálogo y no estén en la lista se dan de alta
-- (sin recibir compras) para no dejar artículos huérfanos.
INSERT INTO public.inventario_almacenes (clave, nombre, recibe_compras, orden)
SELECT DISTINCT p.linea_catalogo, initcap(replace(p.linea_catalogo, '_', ' ')), false, 90
  FROM public.almacen_refacciones_productos p
 WHERE p.linea_catalogo ~ '^[a-z0-9_]{2,40}$'
ON CONFLICT (clave) DO NOTHING;

DROP TRIGGER IF EXISTS trg_inventario_almacenes_updated ON public.inventario_almacenes;
CREATE TRIGGER trg_inventario_almacenes_updated
  BEFORE UPDATE ON public.inventario_almacenes
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Ventas no ve almacenes: sólo Compras, Almacén, Finanzas y Dirección.
DROP POLICY IF EXISTS inventario_almacenes_leer ON public.inventario_almacenes;
CREATE POLICY inventario_almacenes_leer ON public.inventario_almacenes
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
GRANT SELECT ON public.inventario_almacenes TO authenticated;

CREATE OR REPLACE FUNCTION public.guardar_almacen_inventario(
  _clave text, _nombre text, _descripcion text DEFAULT NULL,
  _recibe_compras boolean DEFAULT false, _activo boolean DEFAULT true
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_clave text := lower(regexp_replace(trim(coalesce(_clave, '')), '[^a-zA-Z0-9]+', '_', 'g'));
  v_prueba boolean := public.es_usuario_prueba(auth.uid());
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador da de alta almacenes';
  END IF;
  v_clave := trim(both '_' from v_clave);
  IF v_clave !~ '^[a-z0-9_]{2,40}$' THEN
    RAISE EXCEPTION 'La clave del almacén lleva de 2 a 40 letras o números';
  END IF;
  IF nullif(trim(_nombre), '') IS NULL THEN
    RAISE EXCEPTION 'Escribe el nombre del almacén';
  END IF;
  IF v_clave = 'linea_azul' AND coalesce(_recibe_compras, false) THEN
    RAISE EXCEPTION 'La Línea azul nunca recibe compras';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventario_almacenes WHERE clave = v_clave) THEN
    PERFORM public.exigir_dato_prueba((SELECT es_prueba FROM public.inventario_almacenes WHERE clave = v_clave), 'el almacén ' || v_clave);
    UPDATE public.inventario_almacenes
       SET nombre = trim(_nombre), descripcion = nullif(trim(_descripcion), ''),
           recibe_compras = coalesce(_recibe_compras, false), activo = coalesce(_activo, true)
     WHERE clave = v_clave;
  ELSE
    INSERT INTO public.inventario_almacenes (clave, nombre, descripcion, recibe_compras, activo, es_prueba, created_by)
    VALUES (v_clave, trim(_nombre), nullif(trim(_descripcion), ''), coalesce(_recibe_compras, false),
            coalesce(_activo, true), v_prueba, auth.uid());
  END IF;
  PERFORM public.registrar_bitacora_compras('inventario', 'guardar_almacen', 'inventario_almacenes', NULL, v_clave,
    jsonb_build_object('nombre', _nombre, 'recibe_compras', _recibe_compras, 'activo', _activo), v_prueba);
  RETURN v_clave;
END;
$$;
REVOKE ALL ON FUNCTION public.guardar_almacen_inventario(text, text, text, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_almacen_inventario(text, text, text, boolean, boolean) TO authenticated;

-- ── 6. Catálogos editables: unidad de venta y motivos de ajuste ────────────
CREATE TABLE IF NOT EXISTS public.inventario_unidades_venta (
  clave  text PRIMARY KEY CHECK (clave ~ '^[a-z0-9_]{2,30}$'),
  nombre text NOT NULL,
  orden  integer NOT NULL DEFAULT 100,
  activo boolean NOT NULL DEFAULT true
);
ALTER TABLE public.inventario_unidades_venta ENABLE ROW LEVEL SECURITY;
INSERT INTO public.inventario_unidades_venta (clave, nombre, orden) VALUES
  ('pieza', 'Pieza', 10), ('bolsa', 'Bolsa', 20), ('juego', 'Juego', 30),
  ('par', 'Par', 40), ('paquete', 'Paquete', 50)
ON CONFLICT (clave) DO NOTHING;

DROP POLICY IF EXISTS unidades_venta_leer ON public.inventario_unidades_venta;
CREATE POLICY unidades_venta_leer ON public.inventario_unidades_venta
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS unidades_venta_escribir ON public.inventario_unidades_venta;
CREATE POLICY unidades_venta_escribir ON public.inventario_unidades_venta
  FOR ALL TO authenticated
  USING (public.puede_compras_inventario(auth.uid()))
  WITH CHECK (public.puede_compras_inventario(auth.uid()));
GRANT SELECT, INSERT, UPDATE ON public.inventario_unidades_venta TO authenticated;

CREATE TABLE IF NOT EXISTS public.inventario_motivos_ajuste (
  clave          text PRIMARY KEY CHECK (clave ~ '^[a-z0-9_]{2,40}$'),
  nombre         text NOT NULL,
  requiere_texto boolean NOT NULL DEFAULT false,
  orden          integer NOT NULL DEFAULT 100,
  activo         boolean NOT NULL DEFAULT true
);
ALTER TABLE public.inventario_motivos_ajuste ENABLE ROW LEVEL SECURITY;
INSERT INTO public.inventario_motivos_ajuste (clave, nombre, requiere_texto, orden) VALUES
  ('mal_conteo',           'Mal conteo', false, 10),
  ('auditoria',            'Auditoría o conteo físico', false, 20),
  ('incidencia_recepcion', 'Incidencia de recepción de contenedor', false, 30),
  ('merma',                'Merma o daño', false, 40),
  ('correccion_captura',   'Corrección de captura', false, 50),
  ('otro',                 'Otro', true, 90)
ON CONFLICT (clave) DO NOTHING;

DROP POLICY IF EXISTS motivos_ajuste_leer ON public.inventario_motivos_ajuste;
CREATE POLICY motivos_ajuste_leer ON public.inventario_motivos_ajuste
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS motivos_ajuste_escribir ON public.inventario_motivos_ajuste;
CREATE POLICY motivos_ajuste_escribir ON public.inventario_motivos_ajuste
  FOR ALL TO authenticated
  USING (public.puede_compras_inventario(auth.uid()))
  WITH CHECK (public.puede_compras_inventario(auth.uid()));
GRANT SELECT, INSERT, UPDATE ON public.inventario_motivos_ajuste TO authenticated;

-- ── 7. Datos maestros nuevos del artículo ──────────────────────────────────
ALTER TABLE public.almacen_refacciones_productos
  ADD COLUMN IF NOT EXISTS unidad_venta text NOT NULL DEFAULT 'pieza',
  ADD COLUMN IF NOT EXISTS piezas_por_unidad_venta integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS piezas_caja_cerrada integer;

DO $chk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ref_prod_piezas_unidad_venta_pos') THEN
    ALTER TABLE public.almacen_refacciones_productos
      ADD CONSTRAINT ref_prod_piezas_unidad_venta_pos CHECK (piezas_por_unidad_venta >= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ref_prod_piezas_caja_pos') THEN
    ALTER TABLE public.almacen_refacciones_productos
      ADD CONSTRAINT ref_prod_piezas_caja_pos CHECK (piezas_caja_cerrada IS NULL OR piezas_caja_cerrada >= 1);
  END IF;
END $chk$;

-- La vista que leen Inventario y Remisiones expone los datos nuevos. Mismo
-- método que 20260925000002: se copian las columnas que la vista YA tiene
-- (en producción trae algunas que el repo no conoce: foto_url, etc.), en su
-- orden, y lo nuevo se agrega al final.
DO $vista$
DECLARE
  _cols text;
  _nuevas text := '';
BEGIN
  IF to_regclass('public.v_almacen_refacciones') IS NULL THEN
    RAISE EXCEPTION 'No está la vista v_almacen_refacciones';
  END IF;
  SELECT string_agg(
    CASE column_name
      WHEN 'num_compatibilidades' THEN 'coalesce(c.num_compat, 0)::integer AS num_compatibilidades'
      WHEN 'tiene_compatibilidad' THEN '(coalesce(c.num_compat, 0) > 0) AS tiene_compatibilidad'
      ELSE 'p.' || quote_ident(column_name)
    END, ', ' ORDER BY ordinal_position)
  INTO _cols
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'v_almacen_refacciones'
    AND column_name NOT IN ('stock_bloqueado', 'stock_disponible',
                            'unidad_venta', 'piezas_por_unidad_venta', 'piezas_caja_cerrada', 'es_prueba');

  EXECUTE 'DROP VIEW IF EXISTS public.v_almacen_refacciones';
  EXECUTE format($sql$
    CREATE VIEW public.v_almacen_refacciones
    WITH (security_invoker = true) AS
    SELECT %s,
      b.stock_bloqueado,
      GREATEST(p.stock - b.stock_bloqueado, 0) AS stock_disponible,
      p.unidad_venta, p.piezas_por_unidad_venta, p.piezas_caja_cerrada, p.es_prueba
    FROM public.almacen_refacciones_productos p
    CROSS JOIN LATERAL (SELECT public.stock_bloqueado_producto(p.id) AS stock_bloqueado) b
    LEFT JOIN (
      SELECT producto_id, count(*)::INTEGER AS num_compat
      FROM public.almacen_refacciones_producto_compat
      GROUP BY producto_id
    ) c ON c.producto_id = p.id
  $sql$, _cols);
END $vista$;
GRANT SELECT ON public.v_almacen_refacciones TO authenticated;

-- ── 8. Movimientos: fecha efectiva y documento de origen ───────────────────
ALTER TABLE public.almacen_refacciones_movimientos
  ADD COLUMN IF NOT EXISTS fecha_efectiva date,
  ADD COLUMN IF NOT EXISTS almacen text,
  ADD COLUMN IF NOT EXISTS documento_tipo text,
  ADD COLUMN IF NOT EXISTS documento_id uuid,
  ADD COLUMN IF NOT EXISTS documento_folio text,
  ADD COLUMN IF NOT EXISTS motivo_clave text,
  ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;

-- Lo que ya había: su fecha efectiva es el día en que se registró (hora de
-- México). No cambia ninguna cantidad.
UPDATE public.almacen_refacciones_movimientos m
   SET fecha_efectiva = (m.created_at AT TIME ZONE 'America/Mexico_City')::date
 WHERE m.fecha_efectiva IS NULL;
UPDATE public.almacen_refacciones_movimientos m
   SET almacen = p.linea_catalogo
  FROM public.almacen_refacciones_productos p
 WHERE p.id = m.producto_id AND m.almacen IS NULL;
UPDATE public.almacen_refacciones_movimientos
   SET documento_tipo = CASE tipo WHEN 'venta' THEN 'remision' WHEN 'entrada' THEN 'compra' WHEN 'ajuste' THEN 'ajuste' ELSE 'otro' END
 WHERE documento_tipo IS NULL;

CREATE INDEX IF NOT EXISTS idx_ref_mov_producto_fecha
  ON public.almacen_refacciones_movimientos (producto_id, fecha_efectiva, created_at);
CREATE INDEX IF NOT EXISTS idx_ref_mov_documento
  ON public.almacen_refacciones_movimientos (documento_id) WHERE documento_id IS NOT NULL;

-- Cada movimiento nuevo hereda fecha, almacén, documento y marca de prueba si
-- quien lo inserta (también las funciones que ya existían) no los manda.
CREATE OR REPLACE FUNCTION public.completar_movimiento_refaccion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_linea text;
  v_prueba boolean;
BEGIN
  SELECT linea_catalogo, es_prueba INTO v_linea, v_prueba
    FROM public.almacen_refacciones_productos WHERE id = NEW.producto_id;
  NEW.fecha_efectiva := coalesce(NEW.fecha_efectiva, (coalesce(NEW.created_at, now()) AT TIME ZONE 'America/Mexico_City')::date);
  NEW.almacen := coalesce(NEW.almacen, v_linea);
  NEW.es_prueba := coalesce(NEW.es_prueba, false) OR coalesce(v_prueba, false);
  IF NEW.documento_tipo IS NULL THEN
    NEW.documento_tipo := CASE NEW.tipo WHEN 'venta' THEN 'remision' WHEN 'entrada' THEN 'compra' WHEN 'ajuste' THEN 'ajuste' ELSE 'otro' END;
  END IF;
  -- Liberar / confirmar faltante ya existían y escriben «… remisión RF-00012»
  -- en notas: se recupera el folio para el kárdex.
  IF NEW.documento_folio IS NULL AND NEW.notas ~ 'RF-\d+' THEN
    NEW.documento_folio := substring(NEW.notas FROM 'RF-\d+');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_completar_movimiento_refaccion ON public.almacen_refacciones_movimientos;
CREATE TRIGGER trg_completar_movimiento_refaccion
  BEFORE INSERT ON public.almacen_refacciones_movimientos
  FOR EACH ROW EXECUTE FUNCTION public.completar_movimiento_refaccion();

-- Los movimientos son evidencia: no se editan ni se borran (salvo el
-- reinicio de datos de prueba).
CREATE OR REPLACE FUNCTION public.movimiento_refaccion_inmutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.es_prueba AND current_setting('kit.reiniciando_prueba', true) = 'si' THEN
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    -- Sólo se permite completar metadatos que estaban vacíos.
    IF NEW.producto_id = OLD.producto_id AND NEW.cantidad = OLD.cantidad AND NEW.tipo = OLD.tipo
       AND NEW.fecha_efectiva IS NOT DISTINCT FROM coalesce(OLD.fecha_efectiva, NEW.fecha_efectiva) THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION 'Los movimientos de inventario no se editan ni se borran: se corrigen con un ajuste.';
END;
$$;
DROP TRIGGER IF EXISTS trg_movimiento_refaccion_inmutable ON public.almacen_refacciones_movimientos;
CREATE TRIGGER trg_movimiento_refaccion_inmutable
  BEFORE UPDATE OR DELETE ON public.almacen_refacciones_movimientos
  FOR EACH ROW EXECUTE FUNCTION public.movimiento_refaccion_inmutable();

-- ── 9. Candado de pertenencia: un artículo con existencia no cambia de línea
CREATE OR REPLACE FUNCTION public.candado_linea_refaccion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_apartado integer;
BEGIN
  IF NEW.linea_catalogo IS DISTINCT FROM OLD.linea_catalogo THEN
    v_apartado := public.stock_bloqueado_producto(OLD.id);
    IF coalesce(OLD.stock, 0) <> 0 OR coalesce(v_apartado, 0) <> 0 THEN
      RAISE EXCEPTION
        'El artículo % tiene % en existencia y % apartadas en % . No se puede mover a % sin antes dejarlo en cero: un artículo vive en un solo almacén.',
        OLD.codigo_nuevo, OLD.stock, v_apartado, OLD.linea_catalogo, NEW.linea_catalogo;
    END IF;
  END IF;
  IF NEW.es_prueba IS DISTINCT FROM OLD.es_prueba AND current_setting('kit.reiniciando_prueba', true) IS DISTINCT FROM 'si' THEN
    RAISE EXCEPTION 'Un artículo no cambia entre real y prueba';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_candado_linea_refaccion ON public.almacen_refacciones_productos;
CREATE TRIGGER trg_candado_linea_refaccion
  BEFORE UPDATE OF linea_catalogo, es_prueba ON public.almacen_refacciones_productos
  FOR EACH ROW EXECUTE FUNCTION public.candado_linea_refaccion();

-- ── 10. Candados cruzados prueba ↔ real en remisiones de refacciones ──────
CREATE OR REPLACE FUNCTION public.remision_refaccion_marca_prueba()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cliente_prueba boolean;
BEGIN
  SELECT coalesce(es_prueba, false) INTO v_cliente_prueba FROM public.clientes WHERE id = NEW.cliente_id;
  NEW.es_prueba := coalesce(v_cliente_prueba, false);
  IF public.es_usuario_prueba(auth.uid()) AND NOT NEW.es_prueba THEN
    RAISE EXCEPTION 'Estás en MODO PRUEBA: sólo puedes levantar remisiones a clientes de prueba.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_remision_refaccion_marca_prueba ON public.remisiones_refacciones;
CREATE TRIGGER trg_remision_refaccion_marca_prueba
  BEFORE INSERT ON public.remisiones_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.remision_refaccion_marca_prueba();

CREATE OR REPLACE FUNCTION public.partida_refaccion_candado_prueba()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rem_prueba boolean;
  v_prod_prueba boolean;
  v_codigo text;
BEGIN
  SELECT es_prueba INTO v_rem_prueba FROM public.remisiones_refacciones WHERE id = NEW.remision_id;
  SELECT es_prueba, codigo_nuevo INTO v_prod_prueba, v_codigo FROM public.almacen_refacciones_productos WHERE id = NEW.producto_id;
  IF coalesce(v_rem_prueba, false) <> coalesce(v_prod_prueba, false) THEN
    RAISE EXCEPTION 'No se mezclan datos de prueba con reales: % es un artículo %, y la remisión es de un cliente %.',
      v_codigo,
      CASE WHEN v_prod_prueba THEN 'de prueba' ELSE 'real' END,
      CASE WHEN v_rem_prueba THEN 'de prueba' ELSE 'real' END;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_partida_refaccion_candado_prueba ON public.remision_refaccion_items;
CREATE TRIGGER trg_partida_refaccion_candado_prueba
  BEFORE INSERT ON public.remision_refaccion_items
  FOR EACH ROW EXECUTE FUNCTION public.partida_refaccion_candado_prueba();

-- ── 11. Bucket privado de evidencias (fotos, PDF, vales) ───────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('evidencias-compras', 'evidencias-compras', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "evidencias_compras_select" ON storage.objects;
CREATE POLICY "evidencias_compras_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'evidencias-compras' AND public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS "evidencias_compras_insert" ON storage.objects;
CREATE POLICY "evidencias_compras_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'evidencias-compras' AND public.puede_leer_compras_inventario(auth.uid()));
-- Sin política de UPDATE ni DELETE: la evidencia no se reemplaza ni se borra.

-- ── 12. Postflight ──────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF to_regclass('public.inventario_almacenes') IS NULL THEN
    RAISE EXCEPTION 'No quedó inventario_almacenes';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'almacen_refacciones_movimientos'
                    AND column_name = 'fecha_efectiva') THEN
    RAISE EXCEPTION 'No quedó almacen_refacciones_movimientos.fecha_efectiva';
  END IF;
  IF EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos WHERE fecha_efectiva IS NULL) THEN
    RAISE EXCEPTION 'Quedaron movimientos sin fecha efectiva';
  END IF;
END $postflight$;

NOTIFY pgrst, 'reload schema';
