-- ============================================================
-- Control Financiero v2 — Libro mayor de INGRESOS y EGRESOS
-- 2026-08-23 · KIT-4d
--
-- Reemplaza la tabla plana `pagos` (solo egresos, beneficiario en
-- texto libre, una sola factura) por un libro mayor único que:
--   * registra ingresos de caja y egresos en la misma línea de tiempo
--   * amarra la contraparte al catálogo real (cliente / proveedor /
--     empleado) en lugar de texto libre
--   * distingue quién PAGÓ de quién TRAJO el dinero (intermediario)
--   * exige comprobación cuando se entrega efectivo a alguien para pagar
--   * guarda un expediente con N documentos por movimiento
--   * lleva bitácora de todo cambio y no permite borrar sin motivo
-- ============================================================

-- ── 1. Enums ────────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE public.mov_tipo AS ENUM ('INGRESO','EGRESO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  -- BORRADOR: capturado a medias · PENDIENTE: capturado, falta confirmar
  -- que el dinero entró/salió · CONFIRMADO: afecta saldo · CANCELADO: anulado
  CREATE TYPE public.mov_estatus AS ENUM ('BORRADOR','PENDIENTE','CONFIRMADO','CANCELADO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.metodo_pago AS ENUM
    ('EFECTIVO','TRANSFERENCIA','CHEQUE','TARJETA','DEPOSITO','COMPENSACION','OTRO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.contraparte_tipo AS ENUM ('CLIENTE','PROVEEDOR','EMPLEADO','OTRO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  -- DIRECTO: el cliente vino a pagar / le pagamos al proveedor nosotros
  -- INTERMEDIARIO: alguien trajo el efectivo / le dimos efectivo a alguien para que pague
  CREATE TYPE public.mov_via AS ENUM ('DIRECTO','INTERMEDIARIO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.cuenta_tipo AS ENUM ('EFECTIVO','BANCO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.adjunto_tipo AS ENUM
    ('FACTURA','RECIBO','COMPROBANTE_PAGO','TICKET','VALE_EFECTIVO','FOTO_EFECTIVO',
     'CONTRATO','IDENTIFICACION','ESTADO_CUENTA','COTIZACION','OTRO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 2. Helper de permisos financieros ───────────────────────
CREATE OR REPLACE FUNCTION public.es_finanzas(_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_uid,'admin'::app_role)
      OR public.has_role(_uid,'admin_financiero'::app_role)
      OR public.has_role(_uid,'finanzas'::app_role)
$$;

CREATE OR REPLACE FUNCTION public.es_finanzas_admin(_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_uid,'admin'::app_role)
      OR public.has_role(_uid,'admin_financiero'::app_role)
$$;

-- ── 3. Proveedores ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.proveedores (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo            text UNIQUE,
  nombre_comercial  text NOT NULL,
  razon_social      text,
  rfc               text,
  categoria         text,                -- partes, fletes, aduana, servicios, nómina…
  telefono          text,
  email             text,
  nombre_contacto   text,
  direccion         text,
  banco             text,
  clabe             text,
  cuenta_bancaria   text,
  moneda_preferida  text NOT NULL DEFAULT 'MXN',
  dias_credito      integer NOT NULL DEFAULT 0,
  notas             text,
  activo            boolean NOT NULL DEFAULT true,
  created_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_proveedores_nombre ON public.proveedores (lower(nombre_comercial));
CREATE INDEX IF NOT EXISTS idx_proveedores_activo ON public.proveedores (activo);

DROP TRIGGER IF EXISTS proveedores_set_updated_at ON public.proveedores;
CREATE TRIGGER proveedores_set_updated_at
  BEFORE UPDATE ON public.proveedores
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── 4. Cuentas (cajas y bancos) ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.cuentas_financieras (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre         text NOT NULL,
  tipo           cuenta_tipo NOT NULL,
  moneda         text NOT NULL DEFAULT 'MXN',
  banco          text,
  numero_cuenta  text,
  saldo_inicial  numeric(18,2) NOT NULL DEFAULT 0,
  responsable_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  activo         boolean NOT NULL DEFAULT true,
  orden          integer NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (nombre, moneda)
);

DROP TRIGGER IF EXISTS cuentas_financieras_set_updated_at ON public.cuentas_financieras;
CREATE TRIGGER cuentas_financieras_set_updated_at
  BEFORE UPDATE ON public.cuentas_financieras
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.cuentas_financieras (nombre, tipo, moneda, orden) VALUES
  ('Caja chica',    'EFECTIVO', 'MXN', 1),
  ('Caja dólares',  'EFECTIVO', 'USD', 2),
  ('Banco principal','BANCO',   'MXN', 3)
ON CONFLICT (nombre, moneda) DO NOTHING;

-- ── 5. Catálogo de categorías ───────────────────────────────
CREATE TABLE IF NOT EXISTS public.categorias_financieras (
  id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo    mov_tipo NOT NULL,
  nombre  text NOT NULL,
  activo  boolean NOT NULL DEFAULT true,
  orden   integer NOT NULL DEFAULT 0,
  UNIQUE (tipo, nombre)
);

INSERT INTO public.categorias_financieras (tipo, nombre, orden) VALUES
  ('INGRESO','Venta de unidad',        1),
  ('INGRESO','Anticipo de cliente',    2),
  ('INGRESO','Abono a crédito',        3),
  ('INGRESO','Venta de refacciones',   4),
  ('INGRESO','Servicio / taller',      5),
  ('INGRESO','Devolución',             6),
  ('INGRESO','Préstamo / aportación',  7),
  ('INGRESO','Otro ingreso',          99),
  ('EGRESO','Pago a proveedor',        1),
  ('EGRESO','Compra de partes',        2),
  ('EGRESO','Flete / transporte',      3),
  ('EGRESO','Aduana / importación',    4),
  ('EGRESO','Nómina / raya',           5),
  ('EGRESO','Servicios (luz, agua, renta)', 6),
  ('EGRESO','Mantenimiento',           7),
  ('EGRESO','Impuestos',               8),
  ('EGRESO','Viáticos',                9),
  ('EGRESO','Otro egreso',            99)
ON CONFLICT (tipo, nombre) DO NOTHING;

-- ── 6. Libro mayor: movimientos_financieros ─────────────────
CREATE SEQUENCE IF NOT EXISTS public.seq_folio_ingreso START 1;
CREATE SEQUENCE IF NOT EXISTS public.seq_folio_egreso  START 1;

CREATE TABLE IF NOT EXISTS public.movimientos_financieros (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio               text UNIQUE,
  tipo                mov_tipo NOT NULL,
  estatus             mov_estatus NOT NULL DEFAULT 'PENDIENTE',

  concepto            text NOT NULL,
  categoria           text,
  descripcion         text,

  -- Importe
  monto               numeric(18,2) NOT NULL CHECK (monto > 0),
  moneda              text NOT NULL DEFAULT 'MXN',
  tipo_cambio         numeric(12,4),
  monto_mxn           numeric(18,2) GENERATED ALWAYS AS
                        (round(monto * coalesce(tipo_cambio, 1), 2)) STORED,

  fecha_movimiento    date NOT NULL DEFAULT CURRENT_DATE,
  metodo_pago         metodo_pago NOT NULL DEFAULT 'EFECTIVO',
  cuenta_id           uuid REFERENCES public.cuentas_financieras(id) ON DELETE SET NULL,
  referencia          text,             -- folio de transferencia, cheque, etc.

  -- Contraparte: quién nos pagó (ingreso) o a quién le pagamos (egreso)
  contraparte_tipo    contraparte_tipo NOT NULL DEFAULT 'OTRO',
  cliente_id          uuid REFERENCES public.clientes(id)   ON DELETE SET NULL,
  proveedor_id        uuid REFERENCES public.proveedores(id) ON DELETE SET NULL,
  empleado_id         uuid REFERENCES public.profiles(id)    ON DELETE SET NULL,
  contraparte_nombre  text NOT NULL,    -- snapshot para búsqueda e histórico

  -- Vía: directo o a través de alguien
  via                 mov_via NOT NULL DEFAULT 'DIRECTO',
  intermediario_id    uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  intermediario_nombre text,            -- si es externo (chofer, familiar, etc.)
  recibido_por        uuid REFERENCES public.profiles(id) ON DELETE SET NULL,

  -- Comprobación de efectivo entregado a un tercero para que pague
  requiere_comprobacion boolean NOT NULL DEFAULT false,
  comprobado          boolean NOT NULL DEFAULT false,
  monto_comprobado    numeric(18,2) CHECK (monto_comprobado IS NULL OR monto_comprobado >= 0),
  monto_devuelto      numeric(18,2) CHECK (monto_devuelto   IS NULL OR monto_devuelto   >= 0),
  comprobado_por      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  comprobado_at       timestamptz,
  movimiento_padre_id uuid REFERENCES public.movimientos_financieros(id) ON DELETE SET NULL,

  -- Fiscal
  tiene_factura       boolean NOT NULL DEFAULT false,
  factura_folio       text,
  factura_uuid        text,             -- UUID del CFDI
  factura_rfc         text,

  -- Amarres con la operación
  remision_id         uuid REFERENCES public.remisiones(id)        ON DELETE SET NULL,
  oportunidad_id      uuid REFERENCES public.crm_oportunidades(id) ON DELETE SET NULL,
  contenedor_id       uuid REFERENCES public.contenedores(id)      ON DELETE SET NULL,

  -- Autorización y control
  autorizado_por      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  autorizado_nombre   text,
  autorizado_at       timestamptz,
  confirmado_por      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  confirmado_at       timestamptz,
  cancelado_por       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  cancelado_at        timestamptz,
  motivo_cancelacion  text,

  created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- La contraparte apunta al catálogo que corresponde a su tipo, y a uno solo
  CONSTRAINT chk_contraparte CHECK (
    (contraparte_tipo = 'CLIENTE'   AND cliente_id   IS NOT NULL AND proveedor_id IS NULL     AND empleado_id IS NULL) OR
    (contraparte_tipo = 'PROVEEDOR' AND proveedor_id IS NOT NULL AND cliente_id   IS NULL     AND empleado_id IS NULL) OR
    (contraparte_tipo = 'EMPLEADO'  AND empleado_id  IS NOT NULL AND cliente_id   IS NULL     AND proveedor_id IS NULL) OR
    (contraparte_tipo = 'OTRO'      AND cliente_id   IS NULL     AND proveedor_id IS NULL     AND empleado_id IS NULL)
  ),
  -- Si el dinero pasó por alguien, hay que decir por quién
  CONSTRAINT chk_intermediario CHECK (
    via = 'DIRECTO'
    OR intermediario_id IS NOT NULL
    OR nullif(btrim(coalesce(intermediario_nombre,'')),'') IS NOT NULL
  ),
  -- Moneda extranjera exige tipo de cambio para poder sumar en MXN
  CONSTRAINT chk_tipo_cambio CHECK (
    moneda = 'MXN' OR (tipo_cambio IS NOT NULL AND tipo_cambio > 0)
  ),
  CONSTRAINT chk_cancelacion CHECK (
    estatus <> 'CANCELADO'
    OR nullif(btrim(coalesce(motivo_cancelacion,'')),'') IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS idx_mov_tipo_fecha    ON public.movimientos_financieros (tipo, fecha_movimiento DESC);
CREATE INDEX IF NOT EXISTS idx_mov_estatus       ON public.movimientos_financieros (estatus);
CREATE INDEX IF NOT EXISTS idx_mov_cliente       ON public.movimientos_financieros (cliente_id)   WHERE cliente_id   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mov_proveedor     ON public.movimientos_financieros (proveedor_id) WHERE proveedor_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mov_cuenta        ON public.movimientos_financieros (cuenta_id);
CREATE INDEX IF NOT EXISTS idx_mov_por_comprobar ON public.movimientos_financieros (requiere_comprobacion)
  WHERE requiere_comprobacion AND NOT comprobado;
CREATE INDEX IF NOT EXISTS idx_mov_contraparte   ON public.movimientos_financieros (lower(contraparte_nombre));
CREATE INDEX IF NOT EXISTS idx_mov_padre         ON public.movimientos_financieros (movimiento_padre_id) WHERE movimiento_padre_id IS NOT NULL;

DROP TRIGGER IF EXISTS movimientos_set_updated_at ON public.movimientos_financieros;
CREATE TRIGGER movimientos_set_updated_at
  BEFORE UPDATE ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Folio automático: ING-000001 / EGR-000001
CREATE OR REPLACE FUNCTION public.set_folio_movimiento()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.folio IS NULL OR btrim(NEW.folio) = '' THEN
    IF NEW.tipo = 'INGRESO' THEN
      NEW.folio := 'ING-' || lpad(nextval('public.seq_folio_ingreso')::text, 6, '0');
    ELSE
      NEW.folio := 'EGR-' || lpad(nextval('public.seq_folio_egreso')::text, 6, '0');
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS movimientos_set_folio ON public.movimientos_financieros;
CREATE TRIGGER movimientos_set_folio
  BEFORE INSERT ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public.set_folio_movimiento();

-- Efectivo entregado a un tercero para que pague ⇒ hay que comprobarlo
CREATE OR REPLACE FUNCTION public.marcar_comprobacion_movimiento()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.tipo = 'EGRESO' AND NEW.metodo_pago = 'EFECTIVO' AND NEW.via = 'INTERMEDIARIO' THEN
    NEW.requiere_comprobacion := true;
  END IF;
  IF NEW.comprobado AND NEW.comprobado_at IS NULL THEN
    NEW.comprobado_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS movimientos_marcar_comprobacion ON public.movimientos_financieros;
CREATE TRIGGER movimientos_marcar_comprobacion
  BEFORE INSERT OR UPDATE ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public.marcar_comprobacion_movimiento();

-- La cuenta y el movimiento tienen que estar en la misma moneda, o el saldo
-- de caja mezclaría pesos con dólares.
CREATE OR REPLACE FUNCTION public.validar_moneda_cuenta()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  moneda_cuenta text;
BEGIN
  IF NEW.cuenta_id IS NULL THEN RETURN NEW; END IF;
  SELECT moneda INTO moneda_cuenta FROM public.cuentas_financieras WHERE id = NEW.cuenta_id;
  IF moneda_cuenta IS NOT NULL AND moneda_cuenta <> NEW.moneda THEN
    RAISE EXCEPTION 'El movimiento está en % pero la cuenta maneja %', NEW.moneda, moneda_cuenta
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS movimientos_validar_moneda ON public.movimientos_financieros;
CREATE TRIGGER movimientos_validar_moneda
  BEFORE INSERT OR UPDATE OF cuenta_id, moneda ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public.validar_moneda_cuenta();

-- ── 7. Expediente: adjuntos por movimiento ──────────────────
CREATE TABLE IF NOT EXISTS public.movimiento_adjuntos (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movimiento_id  uuid NOT NULL REFERENCES public.movimientos_financieros(id) ON DELETE CASCADE,
  tipo_documento adjunto_tipo NOT NULL DEFAULT 'OTRO',
  nombre_archivo text NOT NULL,
  storage_path   text NOT NULL,
  mime_type      text,
  tamano_bytes   bigint,
  notas          text,
  subido_por     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_adjuntos_movimiento ON public.movimiento_adjuntos (movimiento_id);

-- `tiene_factura` se mantiene en automático según el expediente
CREATE OR REPLACE FUNCTION public.sync_tiene_factura()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  mov uuid := coalesce(NEW.movimiento_id, OLD.movimiento_id);
BEGIN
  UPDATE public.movimientos_financieros m
     SET tiene_factura = EXISTS (
           SELECT 1 FROM public.movimiento_adjuntos a
            WHERE a.movimiento_id = mov AND a.tipo_documento = 'FACTURA'
         )
   WHERE m.id = mov;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS adjuntos_sync_factura ON public.movimiento_adjuntos;
CREATE TRIGGER adjuntos_sync_factura
  AFTER INSERT OR DELETE OR UPDATE OF tipo_documento ON public.movimiento_adjuntos
  FOR EACH ROW EXECUTE FUNCTION public.sync_tiene_factura();

-- ── 8. Bitácora de movimientos ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.movimiento_bitacora (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movimiento_id uuid NOT NULL REFERENCES public.movimientos_financieros(id) ON DELETE CASCADE,
  accion        text NOT NULL,          -- CREADO, EDITADO, CONFIRMADO, CANCELADO, COMPROBADO
  usuario_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  detalle       jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mov_bitacora ON public.movimiento_bitacora (movimiento_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.log_movimiento()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  accion  text;
  detalle jsonb := '{}'::jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    accion  := 'CREADO';
    detalle := jsonb_build_object(
      'tipo', NEW.tipo, 'monto', NEW.monto, 'moneda', NEW.moneda,
      'contraparte', NEW.contraparte_nombre, 'estatus', NEW.estatus);
  ELSE
    IF NEW.estatus <> OLD.estatus THEN
      accion  := CASE NEW.estatus
                   WHEN 'CONFIRMADO' THEN 'CONFIRMADO'
                   WHEN 'CANCELADO'  THEN 'CANCELADO'
                   ELSE 'ESTATUS' END;
      detalle := jsonb_build_object('de', OLD.estatus, 'a', NEW.estatus,
                                    'motivo', NEW.motivo_cancelacion);
    ELSIF NEW.comprobado AND NOT OLD.comprobado THEN
      accion  := 'COMPROBADO';
      detalle := jsonb_build_object('monto_comprobado', NEW.monto_comprobado,
                                    'monto_devuelto',  NEW.monto_devuelto);
    ELSE
      accion  := 'EDITADO';
      detalle := jsonb_strip_nulls(jsonb_build_object(
        'monto',       CASE WHEN NEW.monto <> OLD.monto THEN jsonb_build_object('de', OLD.monto, 'a', NEW.monto) END,
        'concepto',    CASE WHEN NEW.concepto <> OLD.concepto THEN jsonb_build_object('de', OLD.concepto, 'a', NEW.concepto) END,
        'contraparte', CASE WHEN NEW.contraparte_nombre <> OLD.contraparte_nombre
                            THEN jsonb_build_object('de', OLD.contraparte_nombre, 'a', NEW.contraparte_nombre) END
      ));
      IF detalle = '{}'::jsonb THEN RETURN NULL; END IF;   -- nada relevante cambió
    END IF;
  END IF;

  INSERT INTO public.movimiento_bitacora (movimiento_id, accion, usuario_id, detalle)
  VALUES (NEW.id, accion, auth.uid(), detalle);
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS movimientos_log ON public.movimientos_financieros;
CREATE TRIGGER movimientos_log
  AFTER INSERT OR UPDATE ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public.log_movimiento();

-- Un borrado deja rastro en la bitácora general del sistema
CREATE OR REPLACE FUNCTION public.log_borrado_movimiento()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.bitacora_eliminaciones (tabla, registro_id, eliminado_por, motivo, datos_eliminados)
  VALUES ('movimientos_financieros', OLD.id, auth.uid(),
          coalesce(OLD.motivo_cancelacion, 'Eliminado desde Control Financiero'),
          to_jsonb(OLD));
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS movimientos_log_borrado ON public.movimientos_financieros;
CREATE TRIGGER movimientos_log_borrado
  BEFORE DELETE ON public.movimientos_financieros
  FOR EACH ROW EXECUTE FUNCTION public.log_borrado_movimiento();

-- ── 9. Vistas de reporte ────────────────────────────────────
CREATE OR REPLACE VIEW public.v_movimientos_financieros
WITH (security_invoker = true) AS
SELECT
  m.*,
  c.nombre  AS cuenta_nombre,
  c.tipo    AS cuenta_tipo,
  cl.nombre_comercial AS cliente_nombre,
  cl.codigo_erp       AS cliente_codigo,
  pr.nombre_comercial AS proveedor_nombre,
  pe.nombre_completo  AS empleado_nombre,
  pi.nombre_completo  AS intermediario_perfil_nombre,
  coalesce(pi.nombre_completo, m.intermediario_nombre) AS intermediario_display,
  pr2.nombre_completo AS recibido_por_nombre,
  reg.nombre_completo AS registrado_por_nombre,
  r.folio_remision,
  (SELECT count(*) FROM public.movimiento_adjuntos a WHERE a.movimiento_id = m.id) AS adjuntos_count,
  CASE WHEN m.tipo = 'INGRESO' THEN m.monto_mxn ELSE -m.monto_mxn END AS efecto_mxn
FROM public.movimientos_financieros m
LEFT JOIN public.cuentas_financieras c  ON c.id  = m.cuenta_id
LEFT JOIN public.clientes           cl ON cl.id = m.cliente_id
LEFT JOIN public.proveedores        pr ON pr.id = m.proveedor_id
LEFT JOIN public.profiles           pe ON pe.id = m.empleado_id
LEFT JOIN public.profiles           pi ON pi.id = m.intermediario_id
LEFT JOIN public.profiles           pr2 ON pr2.id = m.recibido_por
LEFT JOIN public.profiles           reg ON reg.id = m.created_by
LEFT JOIN public.remisiones          r ON r.id  = m.remision_id;

CREATE OR REPLACE VIEW public.v_saldos_cuentas
WITH (security_invoker = true) AS
SELECT
  c.id,
  c.nombre,
  c.tipo,
  c.moneda,
  c.activo,
  c.orden,
  c.saldo_inicial,
  coalesce(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto END), 0) AS total_ingresos,
  coalesce(sum(CASE WHEN m.tipo = 'EGRESO'  THEN m.monto END), 0) AS total_egresos,
  c.saldo_inicial
    + coalesce(sum(CASE WHEN m.tipo = 'INGRESO' THEN m.monto ELSE -m.monto END), 0) AS saldo_actual
FROM public.cuentas_financieras c
LEFT JOIN public.movimientos_financieros m
       ON m.cuenta_id = c.id AND m.estatus = 'CONFIRMADO'
GROUP BY c.id, c.nombre, c.tipo, c.moneda, c.activo, c.orden, c.saldo_inicial;

CREATE OR REPLACE VIEW public.v_estado_cuenta_cliente
WITH (security_invoker = true) AS
SELECT
  cl.id   AS cliente_id,
  cl.codigo_erp,
  cl.nombre_comercial,
  count(m.id)                            AS pagos_registrados,
  coalesce(sum(m.monto_mxn), 0)          AS total_pagado_mxn,
  max(m.fecha_movimiento)                AS ultimo_pago
FROM public.clientes cl
LEFT JOIN public.movimientos_financieros m
       ON m.cliente_id = cl.id AND m.tipo = 'INGRESO' AND m.estatus = 'CONFIRMADO'
GROUP BY cl.id, cl.codigo_erp, cl.nombre_comercial;

-- ── 10. RLS ─────────────────────────────────────────────────
ALTER TABLE public.proveedores            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cuentas_financieras    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categorias_financieras ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimientos_financieros ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimiento_adjuntos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimiento_bitacora    ENABLE ROW LEVEL SECURITY;

-- Proveedores: los ve todo usuario autenticado (compras/producción los necesitan),
-- los escribe finanzas.
DROP POLICY IF EXISTS proveedores_select ON public.proveedores;
CREATE POLICY proveedores_select ON public.proveedores
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS proveedores_insert ON public.proveedores;
CREATE POLICY proveedores_insert ON public.proveedores
  FOR INSERT TO authenticated WITH CHECK (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS proveedores_update ON public.proveedores;
CREATE POLICY proveedores_update ON public.proveedores
  FOR UPDATE TO authenticated USING (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS proveedores_delete ON public.proveedores;
CREATE POLICY proveedores_delete ON public.proveedores
  FOR DELETE TO authenticated USING (public.es_finanzas_admin(auth.uid()));

-- Cuentas y categorías: lectura para finanzas, escritura para admin financiero
DROP POLICY IF EXISTS cuentas_select ON public.cuentas_financieras;
CREATE POLICY cuentas_select ON public.cuentas_financieras
  FOR SELECT TO authenticated USING (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS cuentas_write ON public.cuentas_financieras;
CREATE POLICY cuentas_write ON public.cuentas_financieras
  FOR ALL TO authenticated
  USING (public.es_finanzas_admin(auth.uid()))
  WITH CHECK (public.es_finanzas_admin(auth.uid()));

DROP POLICY IF EXISTS categorias_select ON public.categorias_financieras;
CREATE POLICY categorias_select ON public.categorias_financieras
  FOR SELECT TO authenticated USING (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS categorias_write ON public.categorias_financieras;
CREATE POLICY categorias_write ON public.categorias_financieras
  FOR ALL TO authenticated
  USING (public.es_finanzas_admin(auth.uid()))
  WITH CHECK (public.es_finanzas_admin(auth.uid()));

-- Movimientos: finanzas ve todo y captura; solo puede editar lo suyo mientras
-- no esté confirmado. Admin financiero corrige y cancela cualquiera.
DROP POLICY IF EXISTS movimientos_select ON public.movimientos_financieros;
CREATE POLICY movimientos_select ON public.movimientos_financieros
  FOR SELECT TO authenticated USING (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS movimientos_insert ON public.movimientos_financieros;
CREATE POLICY movimientos_insert ON public.movimientos_financieros
  FOR INSERT TO authenticated
  WITH CHECK (public.es_finanzas(auth.uid()) AND created_by = auth.uid());

DROP POLICY IF EXISTS movimientos_update_admin ON public.movimientos_financieros;
CREATE POLICY movimientos_update_admin ON public.movimientos_financieros
  FOR UPDATE TO authenticated
  USING (public.es_finanzas_admin(auth.uid()))
  WITH CHECK (public.es_finanzas_admin(auth.uid()));

DROP POLICY IF EXISTS movimientos_update_propio ON public.movimientos_financieros;
CREATE POLICY movimientos_update_propio ON public.movimientos_financieros
  FOR UPDATE TO authenticated
  USING (
    public.has_role(auth.uid(),'finanzas'::app_role)
    AND created_by = auth.uid()
    AND estatus IN ('BORRADOR','PENDIENTE')
  )
  WITH CHECK (
    public.has_role(auth.uid(),'finanzas'::app_role)
    AND created_by = auth.uid()
    -- Separación de funciones: quien captura el dinero no lo confirma ni lo
    -- cancela; eso es del admin financiero.
    AND estatus IN ('BORRADOR','PENDIENTE')
  );

DROP POLICY IF EXISTS movimientos_delete ON public.movimientos_financieros;
CREATE POLICY movimientos_delete ON public.movimientos_financieros
  FOR DELETE TO authenticated USING (public.es_finanzas_admin(auth.uid()));

-- Adjuntos: quien ve el movimiento ve su expediente
DROP POLICY IF EXISTS adjuntos_select ON public.movimiento_adjuntos;
CREATE POLICY adjuntos_select ON public.movimiento_adjuntos
  FOR SELECT TO authenticated USING (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS adjuntos_insert ON public.movimiento_adjuntos;
CREATE POLICY adjuntos_insert ON public.movimiento_adjuntos
  FOR INSERT TO authenticated
  WITH CHECK (public.es_finanzas(auth.uid()) AND subido_por = auth.uid());

DROP POLICY IF EXISTS adjuntos_delete ON public.movimiento_adjuntos;
CREATE POLICY adjuntos_delete ON public.movimiento_adjuntos
  FOR DELETE TO authenticated
  USING (public.es_finanzas_admin(auth.uid()) OR subido_por = auth.uid());

-- Bitácora: solo lectura desde la app; la escriben los triggers
DROP POLICY IF EXISTS mov_bitacora_select ON public.movimiento_bitacora;
CREATE POLICY mov_bitacora_select ON public.movimiento_bitacora
  FOR SELECT TO authenticated USING (public.es_finanzas(auth.uid()));

-- Finanzas necesita leer remisiones para poder amarrar un ingreso a su remisión
DROP POLICY IF EXISTS "leer remisiones por rol" ON public.remisiones;
CREATE POLICY "leer remisiones por rol" ON public.remisiones
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR vendedor_id = auth.uid()
);

-- ── 11. Storage: expedientes financieros ────────────────────
--
-- `storage.buckets` y `storage.objects` son de supabase_storage_admin, no del
-- usuario que corre esta migración. Como el SQL Editor manda todo el archivo en
-- una sola transacción, un error de permisos aquí revertiría el módulo
-- completo. Por eso va aislado: si no hay permiso, avisa y sigue, y el bucket
-- y sus políticas se crean desde el dashboard (Storage → New bucket).
DO $$
BEGIN
  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  VALUES (
    'finanzas-docs', 'finanzas-docs', false, 20971520,  -- 20 MB
    ARRAY['application/pdf','application/xml','text/xml',
          'image/jpeg','image/png','image/webp','image/heic','image/heif']
  )
  ON CONFLICT (id) DO NOTHING;
EXCEPTION
  WHEN insufficient_privilege OR undefined_table THEN
    RAISE NOTICE 'PENDIENTE MANUAL: crea el bucket privado «finanzas-docs» en Storage → New bucket (20 MB, PDF/XML/imágenes).';
END $$;

DO $$
BEGIN
  DROP POLICY IF EXISTS finanzas_docs_select ON storage.objects;
  CREATE POLICY finanzas_docs_select ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'finanzas-docs' AND public.es_finanzas(auth.uid()));

  DROP POLICY IF EXISTS finanzas_docs_insert ON storage.objects;
  CREATE POLICY finanzas_docs_insert ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'finanzas-docs' AND public.es_finanzas(auth.uid()));

  DROP POLICY IF EXISTS finanzas_docs_delete ON storage.objects;
  CREATE POLICY finanzas_docs_delete ON storage.objects
    FOR DELETE TO authenticated
    USING (bucket_id = 'finanzas-docs' AND public.es_finanzas(auth.uid()));
EXCEPTION
  WHEN insufficient_privilege OR undefined_table THEN
    RAISE NOTICE 'PENDIENTE MANUAL: las políticas del bucket «finanzas-docs» se crean desde Storage → Policies (lectura, subida y borrado para el rol authenticated).';
END $$;

-- ── 12. Migración de los `pagos` existentes ─────────────────
ALTER TABLE public.pagos ADD COLUMN IF NOT EXISTS migrado_a_movimiento uuid
  REFERENCES public.movimientos_financieros(id) ON DELETE SET NULL;

DO $$
DECLARE
  p             record;
  cuenta_default uuid;
  nuevo_id      uuid;
BEGIN
  SELECT id INTO cuenta_default
    FROM public.cuentas_financieras
   WHERE nombre = 'Banco principal' AND moneda = 'MXN'
   LIMIT 1;

  FOR p IN SELECT * FROM public.pagos WHERE migrado_a_movimiento IS NULL LOOP
    INSERT INTO public.movimientos_financieros (
      tipo, estatus, concepto, categoria, descripcion,
      monto, moneda, tipo_cambio, fecha_movimiento, metodo_pago, cuenta_id,
      contraparte_tipo, contraparte_nombre, via,
      tiene_factura, autorizado_nombre,
      created_by, created_at
    ) VALUES (
      'EGRESO', 'CONFIRMADO', p.nombre_pago, 'Otro egreso',
      nullif(btrim(coalesce(p.descripcion,'')),''),
      p.monto, p.moneda,
      CASE WHEN p.moneda = 'MXN' THEN NULL ELSE 1 END,   -- revisar tipo de cambio a mano
      p.created_at::date, 'OTRO',
      CASE WHEN p.moneda = 'MXN' THEN cuenta_default ELSE NULL END,
      'OTRO', p.beneficiario, 'DIRECTO',
      p.tiene_factura, p.aprobado_por,
      p.created_by, p.created_at
    )
    RETURNING id INTO nuevo_id;

    -- La factura suelta del registro viejo se vuelve el primer documento del expediente
    IF p.factura_url IS NOT NULL AND btrim(p.factura_url) <> '' THEN
      INSERT INTO public.movimiento_adjuntos (
        movimiento_id, tipo_documento, nombre_archivo, storage_path, notas, subido_por, created_at
      ) VALUES (
        nuevo_id, 'FACTURA',
        regexp_replace(p.factura_url, '^.*/', ''),
        p.factura_url,
        'Migrado del módulo de pagos (bucket facturas)',
        p.created_by, p.created_at
      );
    END IF;

    UPDATE public.pagos SET migrado_a_movimiento = nuevo_id WHERE id = p.id;
  END LOOP;
END $$;

COMMENT ON TABLE public.pagos IS
  'OBSOLETA — reemplazada por movimientos_financieros. Se conserva solo como respaldo de la migración (ver migrado_a_movimiento).';

COMMENT ON TABLE public.movimientos_financieros IS
  'Libro mayor de caja: ingresos y egresos con contraparte del catálogo, intermediario, comprobación de efectivo y expediente documental.';
COMMENT ON COLUMN public.movimientos_financieros.via IS
  'DIRECTO = el cliente pagó en caja / le pagamos al proveedor. INTERMEDIARIO = alguien trajo el efectivo o alguien lo llevó a pagar.';
COMMENT ON COLUMN public.movimientos_financieros.requiere_comprobacion IS
  'Se enciende solo cuando se entrega efectivo a un tercero para que pague; queda pendiente hasta que devuelve comprobante y cambio.';
