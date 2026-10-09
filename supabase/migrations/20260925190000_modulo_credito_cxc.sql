-- ============================================================
-- Módulo de Crédito · Cuentas por cobrar (CxC)
-- 2026-09-25
--
-- Lista los clientes con línea de crédito y registra su cartera.
-- Si un cliente tiene CxC ABIERTA/PARCIAL con saldo y fecha de
-- vencimiento pasada (no ha pagado a tiempo), se detiene el
-- proceso comercial (alta/edición de remisión) vía RPC.
--
-- Idempotente: se puede pegar otra vez en el SQL editor.
-- ============================================================

-- ── 1. Tabla de cuentas por cobrar ──────────────────────────
CREATE TABLE IF NOT EXISTS public.cuentas_por_cobrar (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio              text UNIQUE,
  cliente_id         uuid NOT NULL REFERENCES public.clientes(id) ON DELETE RESTRICT,
  remision_id        uuid REFERENCES public.remisiones(id) ON DELETE SET NULL,
  concepto           text NOT NULL,
  monto              numeric(18,2) NOT NULL CHECK (monto > 0),
  saldo              numeric(18,2) NOT NULL CHECK (saldo >= 0),
  moneda             text NOT NULL DEFAULT 'MXN',
  fecha_emision      date NOT NULL DEFAULT CURRENT_DATE,
  fecha_vencimiento  date NOT NULL,
  estatus            text NOT NULL DEFAULT 'ABIERTA'
                     CHECK (estatus IN ('ABIERTA', 'PARCIAL', 'PAGADA', 'CANCELADA')),
  notas              text,
  created_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_cxc_saldo_monto CHECK (saldo <= monto),
  CONSTRAINT chk_cxc_vencimiento CHECK (fecha_vencimiento >= fecha_emision)
);

CREATE INDEX IF NOT EXISTS idx_cxc_cliente
  ON public.cuentas_por_cobrar (cliente_id);
CREATE INDEX IF NOT EXISTS idx_cxc_estatus
  ON public.cuentas_por_cobrar (estatus);
CREATE INDEX IF NOT EXISTS idx_cxc_vencimiento
  ON public.cuentas_por_cobrar (fecha_vencimiento)
  WHERE estatus IN ('ABIERTA', 'PARCIAL') AND saldo > 0;
CREATE INDEX IF NOT EXISTS idx_cxc_remision
  ON public.cuentas_por_cobrar (remision_id)
  WHERE remision_id IS NOT NULL;

DO $$ BEGIN
  IF to_regprocedure('public.set_updated_at()') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS cxc_set_updated_at ON public.cuentas_por_cobrar;
    CREATE TRIGGER cxc_set_updated_at
      BEFORE UPDATE ON public.cuentas_por_cobrar
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $$;

-- Folio automático CxC-000001
CREATE SEQUENCE IF NOT EXISTS public.seq_folio_cxc START 1;

CREATE OR REPLACE FUNCTION public.set_folio_cxc()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.folio IS NULL OR btrim(NEW.folio) = '' THEN
    NEW.folio := 'CxC-' || lpad(nextval('public.seq_folio_cxc')::text, 6, '0');
  END IF;
  -- Al alta el saldo pendiente es el monto completo si no vino capturado.
  IF TG_OP = 'INSERT' AND NEW.saldo IS NULL THEN
    NEW.saldo := NEW.monto;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cxc_set_folio ON public.cuentas_por_cobrar;
CREATE TRIGGER cxc_set_folio
  BEFORE INSERT ON public.cuentas_por_cobrar
  FOR EACH ROW EXECUTE FUNCTION public.set_folio_cxc();

-- ── 2. Abonos a una CxC ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cxc_abonos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cxc_id          uuid NOT NULL REFERENCES public.cuentas_por_cobrar(id) ON DELETE CASCADE,
  monto           numeric(18,2) NOT NULL CHECK (monto > 0),
  fecha_abono     date NOT NULL DEFAULT CURRENT_DATE,
  metodo_pago     text,
  referencia      text,
  movimiento_id   uuid REFERENCES public.movimientos_financieros(id) ON DELETE SET NULL,
  notas           text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cxc_abonos_cxc
  ON public.cxc_abonos (cxc_id);

-- Cada abono baja el saldo y ajusta el estatus.
CREATE OR REPLACE FUNCTION public.aplicar_abono_cxc()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_saldo numeric(18,2);
  v_estatus text;
BEGIN
  SELECT saldo, estatus INTO v_saldo, v_estatus
    FROM public.cuentas_por_cobrar
   WHERE id = NEW.cxc_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La cuenta por cobrar no existe';
  END IF;
  IF v_estatus = 'CANCELADA' THEN
    RAISE EXCEPTION 'No se puede abonar a una CxC cancelada';
  END IF;
  IF v_estatus = 'PAGADA' OR v_saldo <= 0 THEN
    RAISE EXCEPTION 'La cuenta por cobrar ya está pagada';
  END IF;
  IF NEW.monto > v_saldo THEN
    RAISE EXCEPTION 'El abono (%) supera el saldo pendiente (%)', NEW.monto, v_saldo;
  END IF;

  v_saldo := round(v_saldo - NEW.monto, 2);
  IF v_saldo = 0 THEN
    v_estatus := 'PAGADA';
  ELSE
    v_estatus := 'PARCIAL';
  END IF;

  UPDATE public.cuentas_por_cobrar
     SET saldo = v_saldo,
         estatus = v_estatus
   WHERE id = NEW.cxc_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cxc_abono_aplica ON public.cxc_abonos;
CREATE TRIGGER cxc_abono_aplica
  BEFORE INSERT ON public.cxc_abonos
  FOR EACH ROW EXECUTE FUNCTION public.aplicar_abono_cxc();

-- ── 3. ¿Tiene crédito el cliente? ───────────────────────────
-- Criterio operativo: días de crédito > 0 o límite capturado.
CREATE OR REPLACE FUNCTION public.cliente_tiene_credito(_cliente_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.clientes c
     WHERE c.id = _cliente_id
       AND c.activo IS DISTINCT FROM false
       AND (
         COALESCE(c.dias_credito, 0) > 0
         OR COALESCE(c.limite_credito, 0) > 0
       )
  );
$$;

-- ── 4. Bloqueo: CxC abiertas y fuera de tiempo ──────────────
CREATE OR REPLACE FUNCTION public.cliente_tiene_cxc_vencidas(_cliente_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.cuentas_por_cobrar c
     WHERE c.cliente_id = _cliente_id
       AND c.estatus IN ('ABIERTA', 'PARCIAL')
       AND c.saldo > 0
       AND c.fecha_vencimiento < CURRENT_DATE
  );
$$;

-- Detalle para el mensaje en pantalla (folios y días de atraso).
CREATE OR REPLACE FUNCTION public.cxc_vencidas_resumen(_cliente_id uuid)
RETURNS TABLE (
  folio text,
  saldo numeric,
  fecha_vencimiento date,
  dias_atraso integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.folio,
         c.saldo,
         c.fecha_vencimiento,
         (CURRENT_DATE - c.fecha_vencimiento)::integer AS dias_atraso
    FROM public.cuentas_por_cobrar c
   WHERE c.cliente_id = _cliente_id
     AND c.estatus IN ('ABIERTA', 'PARCIAL')
     AND c.saldo > 0
     AND c.fecha_vencimiento < CURRENT_DATE
   ORDER BY c.fecha_vencimiento ASC;
$$;

REVOKE ALL ON FUNCTION public.cliente_tiene_credito(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cliente_tiene_cxc_vencidas(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cxc_vencidas_resumen(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cliente_tiene_credito(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cliente_tiene_cxc_vencidas(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cxc_vencidas_resumen(uuid) TO authenticated;

-- ── 5. Vista de cartera por cliente con crédito ─────────────
CREATE OR REPLACE VIEW public.v_clientes_credito AS
SELECT
  cl.id,
  cl.codigo_erp,
  cl.folio_interno,
  cl.nombre_comercial,
  cl.razon_social,
  cl.telefono,
  cl.email_cobranza,
  cl.limite_credito,
  COALESCE(cl.dias_credito, 0) AS dias_credito,
  COALESCE(cl.moneda_credito, 'MXN') AS moneda_credito,
  cl.activo,
  COALESCE(SUM(cxc.saldo) FILTER (
    WHERE cxc.estatus IN ('ABIERTA', 'PARCIAL') AND cxc.saldo > 0
  ), 0)::numeric(18,2) AS saldo_abierto,
  COALESCE(SUM(cxc.saldo) FILTER (
    WHERE cxc.estatus IN ('ABIERTA', 'PARCIAL')
      AND cxc.saldo > 0
      AND cxc.fecha_vencimiento < CURRENT_DATE
  ), 0)::numeric(18,2) AS saldo_vencido,
  COUNT(cxc.id) FILTER (
    WHERE cxc.estatus IN ('ABIERTA', 'PARCIAL') AND cxc.saldo > 0
  )::integer AS cxc_abiertas,
  COUNT(cxc.id) FILTER (
    WHERE cxc.estatus IN ('ABIERTA', 'PARCIAL')
      AND cxc.saldo > 0
      AND cxc.fecha_vencimiento < CURRENT_DATE
  )::integer AS cxc_vencidas
FROM public.clientes cl
LEFT JOIN public.cuentas_por_cobrar cxc ON cxc.cliente_id = cl.id
WHERE cl.activo IS DISTINCT FROM false
  AND (COALESCE(cl.dias_credito, 0) > 0 OR COALESCE(cl.limite_credito, 0) > 0)
GROUP BY
  cl.id, cl.codigo_erp, cl.folio_interno, cl.nombre_comercial, cl.razon_social,
  cl.telefono, cl.email_cobranza, cl.limite_credito, cl.dias_credito,
  cl.moneda_credito, cl.activo;

GRANT SELECT ON public.v_clientes_credito TO authenticated;

-- ── 6. RLS ──────────────────────────────────────────────────
ALTER TABLE public.cuentas_por_cobrar ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cxc_abonos        ENABLE ROW LEVEL SECURITY;

-- Lectura: cualquier autenticado (Comercial necesita saber si hay bloqueo).
DROP POLICY IF EXISTS cxc_select ON public.cuentas_por_cobrar;
CREATE POLICY cxc_select ON public.cuentas_por_cobrar
  FOR SELECT TO authenticated USING (true);

-- Escritura: finanzas / admin financiero / admin global.
DROP POLICY IF EXISTS cxc_insert ON public.cuentas_por_cobrar;
CREATE POLICY cxc_insert ON public.cuentas_por_cobrar
  FOR INSERT TO authenticated
  WITH CHECK (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS cxc_update ON public.cuentas_por_cobrar;
CREATE POLICY cxc_update ON public.cuentas_por_cobrar
  FOR UPDATE TO authenticated
  USING (public.es_finanzas(auth.uid()))
  WITH CHECK (public.es_finanzas(auth.uid()));

DROP POLICY IF EXISTS cxc_delete ON public.cuentas_por_cobrar;
CREATE POLICY cxc_delete ON public.cuentas_por_cobrar
  FOR DELETE TO authenticated
  USING (public.es_finanzas_admin(auth.uid()));

DROP POLICY IF EXISTS cxc_abonos_select ON public.cxc_abonos;
CREATE POLICY cxc_abonos_select ON public.cxc_abonos
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS cxc_abonos_insert ON public.cxc_abonos;
CREATE POLICY cxc_abonos_insert ON public.cxc_abonos
  FOR INSERT TO authenticated
  WITH CHECK (public.es_finanzas(auth.uid()) AND created_by = auth.uid());

DROP POLICY IF EXISTS cxc_abonos_delete ON public.cxc_abonos;
CREATE POLICY cxc_abonos_delete ON public.cxc_abonos
  FOR DELETE TO authenticated
  USING (public.es_finanzas_admin(auth.uid()));
