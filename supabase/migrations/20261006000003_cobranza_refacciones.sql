-- ============================================================================
-- Remisiones de refacciones: órdenes por línea, monto vigente, correcciones,
-- cobranza (aplicación de pagos) y saldos a favor — 2026-10-06
-- ----------------------------------------------------------------------------
-- Requiere 20261006000001 y 20261006000002.
--
-- · Una remisión, dos líneas: si Ventas mezcla Línea dorada y Línea azul, la
--   remisión al cliente es UNA y por dentro quedan dos órdenes de inventario
--   (una por línea), cada una con su apartado y su surtido. No se le muestra
--   error al vendedor.
-- · Monto vigente: se calcula siempre de las partidas (lo surtido + lo
--   apartado, con sus descuentos). Nunca hay dos montos. Una corrección
--   recalcula en el acto el total, el saldo por cobrar y el inventario.
-- · Cobranza: tabla NUEVA y separada. `pagos` / `movimientos_financieros`
--   son de gastos (Finanzas) y no se tocan.
-- · Nada se borra: un pago aplicado sólo se revierte, con motivo.
-- · Saldo a favor: lo que Dazon le debe al cliente. No es cuenta por cobrar
--   ni número negativo. Siempre con origen.
--
-- Nombres: la rama flujo-pagos-refacciones (sin integrar) proponía
-- `pagos_refacciones` y columnas monto_total / monto_pagado en la remisión.
-- Para no chocar si alguien la corrió a mano, aquí todo vive en tablas
-- `cobranza_*` y no se agregan esas columnas.
--
-- Idempotente. Pensado para el SQL editor de Supabase, no para db push.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('public._mover_inventario_refaccion(uuid,text,integer,date,text,text,uuid,text,text,text,uuid,numeric,boolean)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Corre antes 20261006000002_compras_ajustes_kardex.sql';
  END IF;
  IF to_regprocedure('public.recalcular_etapa_remision_refaccion(uuid)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta recalcular_etapa_remision_refaccion (20260925000001)';
  END IF;
  IF to_regprocedure('public.cliente_tiene_credito(uuid)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta cliente_tiene_credito (20260925190000_modulo_credito_cxc)';
  END IF;
END $preflight$;

-- ── 0. Compras lee remisiones de refacciones (corrige y aplica pagos) ──────
DROP POLICY IF EXISTS "compras lee remisiones refacciones" ON public.remisiones_refacciones;
CREATE POLICY "compras lee remisiones refacciones" ON public.remisiones_refacciones
  FOR SELECT TO authenticated
  USING (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid()));
DROP POLICY IF EXISTS "compras lee partidas refacciones" ON public.remision_refaccion_items;
CREATE POLICY "compras lee partidas refacciones" ON public.remision_refaccion_items
  FOR SELECT TO authenticated
  USING (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid()));
DROP POLICY IF EXISTS "compras lee eventos refacciones" ON public.remision_refaccion_eventos;
CREATE POLICY "compras lee eventos refacciones" ON public.remision_refaccion_eventos
  FOR SELECT TO authenticated
  USING (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid()));

-- ── 1. Órdenes de inventario por línea ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.remision_refaccion_ordenes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  remision_id uuid NOT NULL REFERENCES public.remisiones_refacciones(id) ON DELETE CASCADE,
  almacen     text NOT NULL,
  folio       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rem_ref_orden_unica UNIQUE (remision_id, almacen)
);
ALTER TABLE public.remision_refaccion_ordenes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rem_ref_ordenes_leer ON public.remision_refaccion_ordenes;
CREATE POLICY rem_ref_ordenes_leer ON public.remision_refaccion_ordenes
  FOR SELECT TO authenticated
  USING (public.puede_leer_remision_refaccion(remision_id) OR public.puede_compras_inventario(auth.uid())
         OR public.puede_finanzas_cobranza(auth.uid()));
GRANT SELECT ON public.remision_refaccion_ordenes TO authenticated;

ALTER TABLE public.remision_refaccion_items
  ADD COLUMN IF NOT EXISTS almacen text,
  ADD COLUMN IF NOT EXISTS orden_id uuid REFERENCES public.remision_refaccion_ordenes(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.sufijo_orden_almacen(_almacen text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE _almacen WHEN 'linea_dorada' THEN 'D' WHEN 'linea_azul' THEN 'A' WHEN 'ref_motocarro' THEN 'M'
         ELSE upper(left(regexp_replace(coalesce(_almacen, 'X'), '[^a-zA-Z0-9]', '', 'g'), 3)) END
$$;

CREATE OR REPLACE FUNCTION public._orden_de_remision(_remision uuid, _almacen text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  v_folio text;
BEGIN
  SELECT id INTO v_id FROM public.remision_refaccion_ordenes WHERE remision_id = _remision AND almacen = _almacen;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  SELECT folio INTO v_folio FROM public.remisiones_refacciones WHERE id = _remision;
  INSERT INTO public.remision_refaccion_ordenes (remision_id, almacen, folio)
  VALUES (_remision, _almacen, v_folio || '-' || public.sufijo_orden_almacen(_almacen))
  ON CONFLICT (remision_id, almacen) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.remision_refaccion_ordenes WHERE remision_id = _remision AND almacen = _almacen;
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._orden_de_remision(uuid, text) FROM PUBLIC, anon, authenticated;

-- Al levantar la remisión (con la función de siempre), cada partida se
-- acomoda sola en la orden de su línea.
CREATE OR REPLACE FUNCTION public.partida_refaccion_a_orden()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  SELECT linea_catalogo INTO NEW.almacen FROM public.almacen_refacciones_productos WHERE id = NEW.producto_id;
  NEW.orden_id := public._orden_de_remision(NEW.remision_id, coalesce(NEW.almacen, 'sin_linea'));
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_partida_refaccion_a_orden ON public.remision_refaccion_items;
CREATE TRIGGER trg_partida_refaccion_a_orden
  BEFORE INSERT ON public.remision_refaccion_items
  FOR EACH ROW EXECUTE FUNCTION public.partida_refaccion_a_orden();

-- Partidas que ya existían: se les asigna su orden (no cambia ninguna cantidad).
DO $backfill$
DECLARE r record;
BEGIN
  FOR r IN SELECT i.id, i.remision_id, p.linea_catalogo
             FROM public.remision_refaccion_items i
             JOIN public.almacen_refacciones_productos p ON p.id = i.producto_id
            WHERE i.orden_id IS NULL LOOP
    UPDATE public.remision_refaccion_items
       SET almacen = r.linea_catalogo, orden_id = public._orden_de_remision(r.remision_id, r.linea_catalogo)
     WHERE id = r.id;
  END LOOP;
END $backfill$;

CREATE OR REPLACE VIEW public.v_remision_refaccion_ordenes
WITH (security_invoker = true) AS
SELECT o.id, o.remision_id, o.almacen, o.folio,
       count(i.id)::integer AS partidas,
       coalesce(sum(i.cantidad), 0)::integer AS piezas_pedidas,
       coalesce(sum(i.cantidad_bloqueada), 0)::integer AS piezas_apartadas,
       coalesce(sum(i.cantidad_surtida), 0)::integer AS piezas_surtidas,
       coalesce(sum(i.cantidad_faltante), 0)::integer AS piezas_faltantes,
       CASE
         WHEN bool_or(i.estatus = 'faltante') THEN 'contingencia'
         WHEN bool_or(i.estatus = 'bloqueada') THEN 'en_almacen'
         WHEN bool_or(i.cantidad_surtida > 0) THEN 'surtida'
         ELSE 'cancelada'
       END AS estado
  FROM public.remision_refaccion_ordenes o
  LEFT JOIN public.remision_refaccion_items i ON i.orden_id = o.id
 GROUP BY o.id, o.remision_id, o.almacen, o.folio;
GRANT SELECT ON public.v_remision_refaccion_ordenes TO authenticated;

-- ── 2. Monto vigente (una sola fuente de verdad) ───────────────────────────
-- Piezas cobrables de una partida: lo surtido más lo que sigue apartado.
-- Lo cancelado y lo confirmado sin existencia ya no se cobra.
CREATE OR REPLACE FUNCTION public.importe_partida_refaccion(
  _precio numeric, _piezas integer, _desc_partida numeric, _desc_general numeric
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT round(greatest(coalesce(_precio, 0), 0) * greatest(coalesce(_piezas, 0), 0)
               * (1 - least(greatest(coalesce(_desc_partida, 0), 0), 100) / 100)
               * (1 - least(greatest(coalesce(_desc_general, 0), 0), 100) / 100), 2)
$$;

CREATE OR REPLACE FUNCTION public.total_vigente_remision_refaccion(_id uuid, _desc_general numeric DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN r.etapa = 'cancelada' THEN 0::numeric ELSE coalesce((
           SELECT sum(public.importe_partida_refaccion(i.precio_unitario, i.cantidad_surtida + i.cantidad_bloqueada,
                                                       i.descuento_pct, coalesce(_desc_general, r.descuento_pct)))
             FROM public.remision_refaccion_items i WHERE i.remision_id = r.id), 0) END
    FROM public.remisiones_refacciones r WHERE r.id = _id
$$;
REVOKE ALL ON FUNCTION public.total_vigente_remision_refaccion(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.total_vigente_remision_refaccion(uuid, numeric) TO authenticated;

-- ── 3. Cobranza: pagos, aplicaciones, saldos a favor ───────────────────────
CREATE TABLE IF NOT EXISTS public.cobranza_pagos (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio            text NOT NULL UNIQUE,
  cliente_id       uuid NOT NULL REFERENCES public.clientes(id),
  fecha            date NOT NULL,
  monto            numeric(14, 2) NOT NULL CHECK (monto > 0),
  forma            text NOT NULL CHECK (forma IN ('efectivo', 'transferencia', 'deposito')),
  cuenta_destino   text,
  referencia       text,
  evidencia_path   text,
  evidencia_tipo   text CHECK (evidencia_tipo IS NULL OR evidencia_tipo IN ('transferencia', 'deposito', 'vale_efectivo', 'otro')),
  notas            text,
  estatus          text NOT NULL DEFAULT 'registrado' CHECK (estatus IN ('registrado', 'validado', 'revertido')),
  conciliado       boolean NOT NULL DEFAULT false,
  capturado_por    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  validado_por     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  validado_at      timestamptz,
  revertido_por    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  revertido_at     timestamptz,
  motivo_reversion text,
  es_prueba        boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cobranza_pagos_cliente ON public.cobranza_pagos (cliente_id, fecha DESC);

CREATE TABLE IF NOT EXISTS public.cobranza_saldos_favor (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio              text NOT NULL UNIQUE,
  cliente_id         uuid NOT NULL REFERENCES public.clientes(id),
  origen             text NOT NULL CHECK (origen IN ('pago_anticipado', 'remision_corregida', 'pago_en_exceso', 'otro', 'saldo_inicial')),
  monto              numeric(14, 2) NOT NULL CHECK (monto > 0),
  remision_origen_id uuid REFERENCES public.remisiones_refacciones(id),
  pago_origen_id     uuid REFERENCES public.cobranza_pagos(id),
  notas              text,
  created_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  cancelado_at       timestamptz,
  cancelado_por      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  motivo_cancelacion text,
  es_prueba          boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_cobranza_saldos_cliente ON public.cobranza_saldos_favor (cliente_id);

CREATE TABLE IF NOT EXISTS public.cobranza_aplicaciones (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo             text NOT NULL CHECK (tipo IN ('pago', 'saldo_favor')),
  pago_id          uuid REFERENCES public.cobranza_pagos(id),
  saldo_favor_id   uuid REFERENCES public.cobranza_saldos_favor(id),
  remision_id      uuid NOT NULL REFERENCES public.remisiones_refacciones(id),
  monto            numeric(14, 2) NOT NULL CHECK (monto > 0),
  notas            text,
  created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  revertida_at     timestamptz,
  revertida_por    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  motivo_reversion text,
  es_prueba        boolean NOT NULL DEFAULT false,
  CONSTRAINT cobranza_aplicacion_origen CHECK (
    (tipo = 'pago' AND pago_id IS NOT NULL AND saldo_favor_id IS NULL)
    OR (tipo = 'saldo_favor' AND saldo_favor_id IS NOT NULL AND pago_id IS NULL)
  )
);
CREATE INDEX IF NOT EXISTS idx_cobranza_apl_remision ON public.cobranza_aplicaciones (remision_id);
CREATE INDEX IF NOT EXISTS idx_cobranza_apl_pago ON public.cobranza_aplicaciones (pago_id);
CREATE INDEX IF NOT EXISTS idx_cobranza_apl_saldo ON public.cobranza_aplicaciones (saldo_favor_id);

CREATE TABLE IF NOT EXISTS public.cobranza_solicitudes_saldo (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id    uuid NOT NULL REFERENCES public.clientes(id),
  remision_id   uuid NOT NULL REFERENCES public.remisiones_refacciones(id),
  monto         numeric(14, 2) NOT NULL CHECK (monto > 0),
  nota          text,
  estatus       text NOT NULL DEFAULT 'pendiente' CHECK (estatus IN ('pendiente', 'aplicada', 'rechazada')),
  solicitado_por uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resuelto_por  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resuelto_at   timestamptz,
  comentario    text,
  es_prueba     boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.remision_refaccion_correcciones (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  remision_id     uuid NOT NULL REFERENCES public.remisiones_refacciones(id),
  item_id         uuid REFERENCES public.remision_refaccion_items(id),
  campo           text NOT NULL,
  valor_anterior  text,
  valor_nuevo     text,
  monto_anterior  numeric(14, 2),
  monto_nuevo     numeric(14, 2),
  motivo          text,
  usuario_id      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  es_prueba       boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rem_ref_correcciones ON public.remision_refaccion_correcciones (remision_id, created_at);

ALTER TABLE public.cobranza_pagos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cobranza_saldos_favor ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cobranza_aplicaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cobranza_solicitudes_saldo ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.remision_refaccion_correcciones ENABLE ROW LEVEL SECURITY;

-- Lectura: Compras, Finanzas y admin. Ventas ve el saldo a favor de su
-- cliente con la función saldo_favor_disponible_cliente y sus solicitudes.
DO $pol$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cobranza_pagos', 'cobranza_saldos_favor', 'cobranza_aplicaciones'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_leer', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid()))', t || '_leer', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
  END LOOP;
END $pol$;
DROP POLICY IF EXISTS cobranza_solicitudes_leer ON public.cobranza_solicitudes_saldo;
CREATE POLICY cobranza_solicitudes_leer ON public.cobranza_solicitudes_saldo
  FOR SELECT TO authenticated
  USING (solicitado_por = auth.uid() OR public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid()));
GRANT SELECT ON public.cobranza_solicitudes_saldo TO authenticated;
DROP POLICY IF EXISTS rem_ref_correcciones_leer ON public.remision_refaccion_correcciones;
CREATE POLICY rem_ref_correcciones_leer ON public.remision_refaccion_correcciones
  FOR SELECT TO authenticated
  USING (public.puede_leer_remision_refaccion(remision_id) OR public.puede_compras_inventario(auth.uid())
         OR public.puede_finanzas_cobranza(auth.uid()));
GRANT SELECT ON public.remision_refaccion_correcciones TO authenticated;

-- Inmutabilidad: nadie edita ni borra un pago, una aplicación, un saldo o
-- una corrección. Las funciones sólo pueden llenar los campos de validación,
-- reversión o cancelación, una vez.
CREATE OR REPLACE FUNCTION public.cobranza_inmutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.es_prueba AND current_setting('kit.reiniciando_prueba', true) = 'si' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'En cobranza nada se borra: se revierte con motivo.';
  END IF;
  IF TG_TABLE_NAME = 'cobranza_pagos' THEN
    IF (NEW.cliente_id, NEW.fecha, NEW.monto, NEW.forma, NEW.folio, NEW.es_prueba, NEW.capturado_por)
       IS DISTINCT FROM (OLD.cliente_id, OLD.fecha, OLD.monto, OLD.forma, OLD.folio, OLD.es_prueba, OLD.capturado_por) THEN
      RAISE EXCEPTION 'Un pago no se edita. Para corregir fecha, monto o cliente, reviértelo con motivo y registra otro.';
    END IF;
    IF OLD.estatus = 'revertido' THEN RAISE EXCEPTION 'El pago % ya está revertido', OLD.folio; END IF;
    IF OLD.estatus = 'validado' AND (NEW.evidencia_path, NEW.referencia, NEW.cuenta_destino)
       IS DISTINCT FROM (OLD.evidencia_path, OLD.referencia, OLD.cuenta_destino) THEN
      RAISE EXCEPTION 'El pago % ya está validado: su evidencia y referencia no cambian', OLD.folio;
    END IF;
  ELSIF TG_TABLE_NAME = 'cobranza_aplicaciones' THEN
    IF OLD.revertida_at IS NOT NULL OR NEW.revertida_at IS NULL
       OR (NEW.tipo, NEW.pago_id, NEW.saldo_favor_id, NEW.remision_id, NEW.monto, NEW.created_at)
          IS DISTINCT FROM (OLD.tipo, OLD.pago_id, OLD.saldo_favor_id, OLD.remision_id, OLD.monto, OLD.created_at) THEN
      RAISE EXCEPTION 'Una aplicación de pago no se edita: sólo se revierte, una vez, con motivo.';
    END IF;
  ELSIF TG_TABLE_NAME = 'cobranza_saldos_favor' THEN
    IF OLD.cancelado_at IS NOT NULL OR NEW.cancelado_at IS NULL
       OR (NEW.cliente_id, NEW.origen, NEW.monto, NEW.remision_origen_id, NEW.pago_origen_id)
          IS DISTINCT FROM (OLD.cliente_id, OLD.origen, OLD.monto, OLD.remision_origen_id, OLD.pago_origen_id) THEN
      RAISE EXCEPTION 'Un saldo a favor no se edita: sólo se cancela, una vez, con motivo.';
    END IF;
  ELSIF TG_TABLE_NAME = 'remision_refaccion_correcciones' THEN
    RAISE EXCEPTION 'El historial de correcciones no se edita';
  END IF;
  RETURN NEW;
END;
$$;
DO $trg$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cobranza_pagos', 'cobranza_saldos_favor', 'cobranza_aplicaciones', 'remision_refaccion_correcciones'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_inmutable ON public.%I', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_inmutable BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.cobranza_inmutable()', t, t);
  END LOOP;
END $trg$;

-- ── 4. Estado de cobro de una remisión ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.estado_cobro_remision_refaccion(_id uuid)
RETURNS TABLE (total numeric, cobrado_dinero numeric, cobrado_saldo_favor numeric,
               trasladado_saldo_favor numeric, cobrado_neto numeric, saldo_pendiente numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH t AS (SELECT public.total_vigente_remision_refaccion(_id) AS total),
  a AS (
    SELECT coalesce(sum(monto) FILTER (WHERE tipo = 'pago'), 0) AS dinero,
           coalesce(sum(monto) FILTER (WHERE tipo = 'saldo_favor'), 0) AS saldo
      FROM public.cobranza_aplicaciones WHERE remision_id = _id AND revertida_at IS NULL
  ),
  x AS (
    SELECT coalesce(sum(monto), 0) AS trasl FROM public.cobranza_saldos_favor
     WHERE remision_origen_id = _id AND origen = 'remision_corregida' AND cancelado_at IS NULL
  )
  SELECT t.total, a.dinero, a.saldo, x.trasl, a.dinero + a.saldo - x.trasl,
         greatest(t.total - (a.dinero + a.saldo - x.trasl), 0)
    FROM t, a, x
$$;
REVOKE ALL ON FUNCTION public.estado_cobro_remision_refaccion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.estado_cobro_remision_refaccion(uuid) TO authenticated;

-- Si lo cobrado supera el monto vigente (corrección, faltante, devolución,
-- cancelación), el excedente se vuelve saldo a favor del cliente. Si la
-- remisión quedó cubierta, se marca pagada (la marca de siempre).
CREATE OR REPLACE FUNCTION public.cobranza_sincronizar_remision(_id uuid, _motivo text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  e record;
  r public.remisiones_refacciones%ROWTYPE;
  v_hay_aplicaciones boolean;
  v_sf public.cobranza_saldos_favor%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO e FROM public.estado_cobro_remision_refaccion(_id);

  -- Lo trasladado a saldo a favor no puede ser más que lo pagado de más.
  -- Pasa si se revierte un pago o si la remisión vuelve a subir de monto:
  -- se cancelan (sin borrar) los saldos de corrección que sobran, si no se
  -- han usado; después, abajo, se vuelve a generar el excedente exacto.
  WHILE e.trasladado_saldo_favor > greatest(e.cobrado_dinero + e.cobrado_saldo_favor - e.total, 0) LOOP
    SELECT * INTO v_sf FROM public.cobranza_saldos_favor
     WHERE remision_origen_id = _id AND origen = 'remision_corregida' AND cancelado_at IS NULL
     ORDER BY created_at DESC LIMIT 1;
    EXIT WHEN NOT FOUND;
    IF public.disponible_saldo_favor(v_sf.id) < v_sf.monto THEN
      RAISE EXCEPTION 'El saldo a favor % que generó % ya se usó en otra remisión: revierte primero ese uso.', v_sf.folio, r.folio;
    END IF;
    UPDATE public.cobranza_saldos_favor
       SET cancelado_at = now(), cancelado_por = auth.uid(),
           motivo_cancelacion = 'Ya no hay excedente en ' || r.folio || ' (pago revertido o monto corregido)'
     WHERE id = v_sf.id;
    SELECT * INTO e FROM public.estado_cobro_remision_refaccion(_id);
  END LOOP;

  IF e.cobrado_neto > e.total THEN
    INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, remision_origen_id, notas, created_by, es_prueba)
    VALUES (public._siguiente_folio_compras('SF', r.es_prueba), r.cliente_id, 'remision_corregida',
            e.cobrado_neto - e.total, _id,
            coalesce(_motivo, current_setting('kit.motivo_correccion', true), 'La remisión ' || r.folio || ' bajó de monto')
              || '. Excedente sobre lo ya pagado en ' || r.folio || '.',
            auth.uid(), r.es_prueba);
    PERFORM public.registrar_bitacora_compras('cobranza', 'saldo_favor_por_correccion', 'remisiones_refacciones', _id, r.folio,
      jsonb_build_object('excedente', e.cobrado_neto - e.total), r.es_prueba);
    SELECT * INTO e FROM public.estado_cobro_remision_refaccion(_id);
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE remision_id = _id) INTO v_hay_aplicaciones;
  IF v_hay_aplicaciones THEN
    UPDATE public.remisiones_refacciones
       SET pagado = (e.total > 0 AND e.saldo_pendiente = 0),
           pagado_at = CASE WHEN e.total > 0 AND e.saldo_pendiente = 0 THEN coalesce(pagado_at, now()) ELSE NULL END
     WHERE id = _id AND pagado IS DISTINCT FROM (e.total > 0 AND e.saldo_pendiente = 0);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.cobranza_sincronizar_remision(uuid, text) FROM PUBLIC, anon, authenticated;

-- ── 5. Historial de correcciones (por cualquier camino) ────────────────────
CREATE OR REPLACE FUNCTION public.registrar_correccion_partida()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rem public.remisiones_refacciones%ROWTYPE;
  v_old_imp numeric;
  v_new_imp numeric;
  v_total numeric;
  v_motivo text := current_setting('kit.motivo_correccion', true);
  v_campos text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO v_rem FROM public.remisiones_refacciones WHERE id = NEW.remision_id;
  IF (OLD.cantidad_surtida + OLD.cantidad_bloqueada) IS DISTINCT FROM (NEW.cantidad_surtida + NEW.cantidad_bloqueada) THEN
    v_campos := v_campos || 'piezas_cobrables'::text;
  END IF;
  IF OLD.precio_unitario IS DISTINCT FROM NEW.precio_unitario THEN v_campos := v_campos || 'precio_unitario'::text; END IF;
  IF OLD.descuento_pct IS DISTINCT FROM NEW.descuento_pct THEN v_campos := v_campos || 'descuento_pct'::text; END IF;
  IF array_length(v_campos, 1) IS NULL THEN RETURN NEW; END IF;

  v_old_imp := public.importe_partida_refaccion(OLD.precio_unitario, OLD.cantidad_surtida + OLD.cantidad_bloqueada, OLD.descuento_pct, v_rem.descuento_pct);
  v_new_imp := public.importe_partida_refaccion(NEW.precio_unitario, NEW.cantidad_surtida + NEW.cantidad_bloqueada, NEW.descuento_pct, v_rem.descuento_pct);
  v_total := public.total_vigente_remision_refaccion(NEW.remision_id);

  INSERT INTO public.remision_refaccion_correcciones (remision_id, item_id, campo, valor_anterior, valor_nuevo,
    monto_anterior, monto_nuevo, motivo, usuario_id, es_prueba)
  SELECT NEW.remision_id, NEW.id, c,
         CASE c WHEN 'piezas_cobrables' THEN (OLD.cantidad_surtida + OLD.cantidad_bloqueada)::text
                WHEN 'precio_unitario' THEN OLD.precio_unitario::text ELSE OLD.descuento_pct::text END,
         CASE c WHEN 'piezas_cobrables' THEN (NEW.cantidad_surtida + NEW.cantidad_bloqueada)::text
                WHEN 'precio_unitario' THEN NEW.precio_unitario::text ELSE NEW.descuento_pct::text END,
         v_total - (v_new_imp - v_old_imp), v_total,
         coalesce(nullif(v_motivo, ''),
                  CASE WHEN NEW.estatus = 'sin_existencia' OR (OLD.cantidad_faltante > 0 AND NEW.cantidad_faltante = 0)
                       THEN 'Faltante confirmado por Almacén: ' || coalesce(NEW.nota_almacen, '')
                       WHEN NEW.estatus = 'cancelada' THEN 'Partida cancelada'
                       ELSE 'Cambio en la remisión' END),
         auth.uid(), v_rem.es_prueba
    FROM unnest(v_campos) AS c;

  PERFORM public.cobranza_sincronizar_remision(NEW.remision_id);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_registrar_correccion_partida ON public.remision_refaccion_items;
CREATE TRIGGER trg_registrar_correccion_partida
  AFTER UPDATE ON public.remision_refaccion_items
  FOR EACH ROW EXECUTE FUNCTION public.registrar_correccion_partida();

CREATE OR REPLACE FUNCTION public.registrar_correccion_remision()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_motivo text := current_setting('kit.motivo_correccion', true);
BEGIN
  IF OLD.descuento_pct IS DISTINCT FROM NEW.descuento_pct THEN
    INSERT INTO public.remision_refaccion_correcciones (remision_id, campo, valor_anterior, valor_nuevo,
      monto_anterior, monto_nuevo, motivo, usuario_id, es_prueba)
    VALUES (NEW.id, 'descuento_general', OLD.descuento_pct::text, NEW.descuento_pct::text,
      public.total_vigente_remision_refaccion(NEW.id, OLD.descuento_pct), public.total_vigente_remision_refaccion(NEW.id),
      coalesce(nullif(v_motivo, ''), 'Cambio en la remisión'), auth.uid(), NEW.es_prueba);
  END IF;
  IF OLD.etapa IS DISTINCT FROM NEW.etapa AND NEW.etapa = 'cancelada' THEN
    INSERT INTO public.remision_refaccion_correcciones (remision_id, campo, valor_anterior, valor_nuevo,
      monto_nuevo, motivo, usuario_id, es_prueba)
    VALUES (NEW.id, 'etapa', OLD.etapa, NEW.etapa, 0, coalesce(NEW.motivo_cancelacion, 'Cancelada'), auth.uid(), NEW.es_prueba);
  END IF;
  PERFORM public.cobranza_sincronizar_remision(NEW.id, CASE WHEN NEW.etapa = 'cancelada' THEN 'Remisión ' || NEW.folio || ' cancelada' END);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_registrar_correccion_remision ON public.remisiones_refacciones;
CREATE TRIGGER trg_registrar_correccion_remision
  AFTER UPDATE OF descuento_pct, etapa ON public.remisiones_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.registrar_correccion_remision();

-- Con pagos aplicados, sólo Compras / Finanzas / admin cambian precios o
-- descuentos (Ventas sigue pudiendo ajustar su descuento antes de cobrar).
CREATE OR REPLACE FUNCTION public.candado_descuento_con_pago()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rem uuid;
BEGIN
  -- to_jsonb: cada tabla sólo tiene uno de los dos campos y plpgsql falla
  -- al nombrar el que no existe aunque la rama no se ejecute.
  v_rem := CASE WHEN TG_TABLE_NAME = 'remisiones_refacciones' THEN (to_jsonb(NEW)->>'id')::uuid
                ELSE (to_jsonb(NEW)->>'remision_id')::uuid END;
  IF auth.uid() IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE remision_id = v_rem AND revertida_at IS NULL)
     AND NOT (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid())) THEN
    RAISE EXCEPTION 'Esta remisión ya tiene pagos aplicados: el precio o descuento lo corrige Compras o Finanzas.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_candado_descuento_con_pago_rem ON public.remisiones_refacciones;
CREATE TRIGGER trg_candado_descuento_con_pago_rem
  BEFORE UPDATE OF descuento_pct ON public.remisiones_refacciones
  FOR EACH ROW WHEN (OLD.descuento_pct IS DISTINCT FROM NEW.descuento_pct)
  EXECUTE FUNCTION public.candado_descuento_con_pago();
DROP TRIGGER IF EXISTS trg_candado_descuento_con_pago_item ON public.remision_refaccion_items;
CREATE TRIGGER trg_candado_descuento_con_pago_item
  BEFORE UPDATE OF descuento_pct, precio_unitario ON public.remision_refaccion_items
  FOR EACH ROW WHEN (OLD.descuento_pct IS DISTINCT FROM NEW.descuento_pct OR OLD.precio_unitario IS DISTINCT FROM NEW.precio_unitario)
  EXECUTE FUNCTION public.candado_descuento_con_pago();

-- ── 6. Corregir una remisión ───────────────────────────────────────────────
-- _cambios = { "descuento_pct": 5,
--              "partidas": [{ "item_id": "...", "cantidad": 8, "precio_unitario": 120, "descuento_pct": 10 }] }
-- Bajar la cantidad suelta apartado primero y, si ya estaba surtido, regresa
-- las piezas al inventario (devolución, con kárdex). Subirla aparta más
-- (si hay disponible) y la remisión regresa a Almacén.
CREATE OR REPLACE FUNCTION public.corregir_remision_refaccion(_remision_id uuid, _cambios jsonb, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.remisiones_refacciones%ROWTYPE;
  it jsonb;
  i public.remision_refaccion_items%ROWTYPE;
  v_compras boolean := public.puede_compras_inventario(auth.uid());
  v_finanzas boolean := public.puede_finanzas_cobranza(auth.uid());
  v_antes numeric;
  v_despues numeric;
  v_n integer;
  v_bloq integer;
  v_surt integer;
  v_dev integer;
  v_disp integer;
  v_stock integer;
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
BEGIN
  IF NOT (v_compras OR v_finanzas) THEN
    RAISE EXCEPTION 'Sólo Compras, Finanzas (descuentos) o un administrador corrigen remisiones';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo de la corrección';
  END IF;
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la remisión'; END IF;
  PERFORM public.exigir_dato_prueba(r.es_prueba, 'la remisión ' || r.folio);
  IF r.etapa = 'cancelada' THEN RAISE EXCEPTION 'La remisión % está cancelada', r.folio; END IF;
  IF NOT v_compras AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(coalesce(_cambios->'partidas', '[]'::jsonb)) e
        WHERE e.value ? 'cantidad' OR e.value ? 'precio_unitario') THEN
    RAISE EXCEPTION 'Finanzas corrige descuentos; cantidades y precios los corrige Compras';
  END IF;

  PERFORM set_config('kit.motivo_correccion', trim(_motivo), true);
  v_antes := public.total_vigente_remision_refaccion(_remision_id);

  IF _cambios ? 'descuento_pct' THEN
    IF (_cambios->>'descuento_pct')::numeric NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'El descuento va de 0 a 100'; END IF;
    UPDATE public.remisiones_refacciones SET descuento_pct = (_cambios->>'descuento_pct')::numeric WHERE id = _remision_id;
  END IF;

  FOR it IN SELECT value FROM jsonb_array_elements(coalesce(_cambios->'partidas', '[]'::jsonb)) LOOP
    SELECT * INTO i FROM public.remision_refaccion_items WHERE id = (it->>'item_id')::uuid AND remision_id = _remision_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Una partida no pertenece a la remisión %', r.folio; END IF;

    IF it ? 'descuento_pct' THEN
      IF (it->>'descuento_pct')::numeric NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'El descuento va de 0 a 100'; END IF;
      UPDATE public.remision_refaccion_items SET descuento_pct = (it->>'descuento_pct')::numeric WHERE id = i.id;
    END IF;
    IF it ? 'precio_unitario' THEN
      IF (it->>'precio_unitario')::numeric < 0 THEN RAISE EXCEPTION 'El precio no puede ser negativo'; END IF;
      UPDATE public.remision_refaccion_items SET precio_unitario = (it->>'precio_unitario')::numeric WHERE id = i.id;
    END IF;
    IF it ? 'cantidad' THEN
      SELECT * INTO i FROM public.remision_refaccion_items WHERE id = i.id;
      v_n := (it->>'cantidad')::integer;
      IF v_n IS NULL OR v_n < 0 THEN RAISE EXCEPTION 'La cantidad de % no es válida', i.codigo_nuevo; END IF;
      IF v_n = i.cantidad_surtida + i.cantidad_bloqueada THEN CONTINUE; END IF;
      v_dev := 0;
      IF v_n >= i.cantidad_surtida THEN
        v_surt := i.cantidad_surtida;
        v_bloq := v_n - i.cantidad_surtida;
        IF v_bloq > i.cantidad_bloqueada THEN
          IF r.etapa = 'entregada' OR r.entregada_at IS NOT NULL THEN
            RAISE EXCEPTION 'La remisión % ya se entregó: para más piezas levanta otra remisión', r.folio;
          END IF;
          SELECT stock INTO v_stock FROM public.almacen_refacciones_productos WHERE id = i.producto_id FOR UPDATE;
          v_disp := v_stock - public.stock_bloqueado_producto(i.producto_id);
          IF v_bloq - i.cantidad_bloqueada > v_disp THEN
            RAISE EXCEPTION 'No hay disponible para subir %: se necesitan % y hay % disponibles', i.codigo_nuevo,
              v_bloq - i.cantidad_bloqueada, greatest(v_disp, 0);
          END IF;
        END IF;
      ELSE
        -- Devolución de lo ya surtido.
        v_dev := i.cantidad_surtida - v_n;
        v_surt := v_n;
        v_bloq := 0;
      END IF;
      UPDATE public.remision_refaccion_items
         SET cantidad = greatest(v_n, cantidad_surtida - v_dev, 1),
             cantidad_bloqueada = v_bloq,
             cantidad_surtida = v_surt,
             cantidad_faltante = least(cantidad_faltante, v_bloq),
             estatus = CASE WHEN v_bloq > 0 AND least(cantidad_faltante, v_bloq) > 0 THEN 'faltante'
                            WHEN v_bloq > 0 THEN 'bloqueada'
                            WHEN v_surt > 0 THEN 'surtida'
                            ELSE 'cancelada' END
       WHERE id = i.id;
      IF v_dev > 0 THEN
        PERFORM public._mover_inventario_refaccion(i.producto_id, coalesce(i.almacen, (SELECT linea_catalogo FROM public.almacen_refacciones_productos WHERE id = i.producto_id)),
          v_dev, v_hoy, 'entrada', 'devolucion', r.id, r.folio, NULL,
          'Devolución por corrección de ' || r.folio || ': ' || trim(_motivo), r.cliente_id, i.precio_unitario, r.es_prueba);
      END IF;
      INSERT INTO public.remision_refaccion_eventos (remision_id, item_id, area, accion, detalle, usuario_id)
      VALUES (r.id, i.id, 'almacen', 'correccion',
              'Corrección: ' || i.codigo_nuevo || ' pasa de ' || (i.cantidad_surtida + i.cantidad_bloqueada) || ' a ' || v_n
                || CASE WHEN v_dev > 0 THEN ' (regresan ' || v_dev || ' al inventario)' ELSE '' END || '. ' || trim(_motivo),
              auth.uid());
    END IF;
  END LOOP;

  PERFORM public.recalcular_etapa_remision_refaccion(_remision_id);
  PERFORM public.cobranza_sincronizar_remision(_remision_id, 'Corrección de ' || r.folio || ': ' || trim(_motivo));
  v_despues := public.total_vigente_remision_refaccion(_remision_id);

  PERFORM public.registrar_bitacora_compras('cobranza', 'corregir_remision', 'remisiones_refacciones', r.id, r.folio,
    jsonb_build_object('monto_anterior', v_antes, 'monto_nuevo', v_despues, 'motivo', _motivo, 'cambios', _cambios), r.es_prueba);
  RETURN jsonb_build_object('monto_anterior', v_antes, 'monto_nuevo', v_despues);
END;
$$;
REVOKE ALL ON FUNCTION public.corregir_remision_refaccion(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.corregir_remision_refaccion(uuid, jsonb, text) TO authenticated;

-- ── 7. Registrar, validar, aplicar y revertir pagos ────────────────────────
CREATE OR REPLACE FUNCTION public.registrar_pago_cobranza(_datos jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cli public.clientes%ROWTYPE;
  v_id uuid;
  v_folio text;
  v_validar boolean := coalesce((_datos->>'validar')::boolean, false);
  v_fin boolean := public.puede_finanzas_cobranza(auth.uid());
BEGIN
  IF NOT (public.puede_compras_inventario(auth.uid()) OR v_fin) THEN
    RAISE EXCEPTION 'Sólo Compras o Finanzas registran pagos de clientes';
  END IF;
  SELECT * INTO v_cli FROM public.clientes WHERE id = (_datos->>'cliente_id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Elige el cliente'; END IF;
  PERFORM public.exigir_dato_prueba(v_cli.es_prueba, 'el cliente ' || coalesce(v_cli.nombre_comercial, ''));
  IF nullif(_datos->>'monto', '')::numeric IS NULL OR (_datos->>'monto')::numeric <= 0 THEN
    RAISE EXCEPTION 'El monto debe ser mayor a cero';
  END IF;
  IF nullif(trim(_datos->>'evidencia_path'), '') IS NULL THEN
    RAISE EXCEPTION 'Sube la evidencia: imagen o PDF de la transferencia, o el vale de efectivo';
  END IF;
  IF v_validar AND NOT v_fin THEN
    RAISE EXCEPTION 'Sólo Finanzas valida un pago';
  END IF;

  v_folio := public._siguiente_folio_compras('CP', v_cli.es_prueba);
  INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, cuenta_destino, referencia,
    evidencia_path, evidencia_tipo, notas, estatus, conciliado, capturado_por, validado_por, validado_at, es_prueba)
  VALUES (v_folio, v_cli.id, coalesce(nullif(_datos->>'fecha', '')::date, (now() AT TIME ZONE 'America/Mexico_City')::date),
    round((_datos->>'monto')::numeric, 2), coalesce(nullif(_datos->>'forma', ''), 'transferencia'),
    nullif(trim(_datos->>'cuenta_destino'), ''), nullif(trim(_datos->>'referencia'), ''),
    trim(_datos->>'evidencia_path'), nullif(_datos->>'evidencia_tipo', ''), nullif(trim(_datos->>'notas'), ''),
    CASE WHEN v_validar THEN 'validado' ELSE 'registrado' END,
    v_validar AND coalesce((_datos->>'conciliado')::boolean, false),
    auth.uid(), CASE WHEN v_validar THEN auth.uid() END, CASE WHEN v_validar THEN now() END, v_cli.es_prueba)
  RETURNING id INTO v_id;

  PERFORM public.registrar_bitacora_compras('cobranza', 'registrar_pago', 'cobranza_pagos', v_id, v_folio,
    _datos - 'evidencia_path', v_cli.es_prueba);
  IF v_validar THEN
    INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, datos, creado_por)
    VALUES ('compras', 'pago_validado', 'Pago validado ' || v_folio,
            'Finanzas validó ' || to_char((_datos->>'monto')::numeric, 'FM999,999,990.00') || ' de '
              || coalesce(v_cli.nombre_comercial, v_cli.razon_social, '') || '. Falta aplicarlo a sus remisiones.',
            jsonb_build_object('pago_id', v_id, 'ruta', '/cobranza'), auth.uid());
  END IF;
  RETURN jsonb_build_object('id', v_id, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.registrar_pago_cobranza(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pago_cobranza(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.validar_pago_cobranza(_pago_id uuid, _conciliado boolean, _evidencia_path text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.cobranza_pagos%ROWTYPE;
BEGIN
  IF NOT public.puede_finanzas_cobranza(auth.uid()) THEN RAISE EXCEPTION 'Sólo Finanzas valida un pago'; END IF;
  SELECT * INTO p FROM public.cobranza_pagos WHERE id = _pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el pago'; END IF;
  PERFORM public.exigir_dato_prueba(p.es_prueba, 'el pago ' || p.folio);
  IF p.estatus = 'revertido' THEN RAISE EXCEPTION 'El pago % está revertido', p.folio; END IF;
  IF coalesce(nullif(trim(_evidencia_path), ''), p.evidencia_path) IS NULL THEN
    RAISE EXCEPTION 'Sin evidencia no se valida el pago';
  END IF;
  UPDATE public.cobranza_pagos
     SET evidencia_path = coalesce(evidencia_path, nullif(trim(_evidencia_path), '')),
         estatus = 'validado', conciliado = coalesce(_conciliado, conciliado),
         validado_por = auth.uid(), validado_at = now()
   WHERE id = _pago_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'validar_pago', 'cobranza_pagos', p.id, p.folio,
    jsonb_build_object('conciliado', _conciliado), p.es_prueba);
  IF p.estatus = 'registrado' THEN
    INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, datos, creado_por)
    VALUES ('compras', 'pago_validado', 'Pago validado ' || p.folio,
            'Finanzas validó el pago ' || p.folio || '. Falta aplicarlo a sus remisiones.',
            jsonb_build_object('pago_id', p.id, 'ruta', '/cobranza'), auth.uid());
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.validar_pago_cobranza(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validar_pago_cobranza(uuid, boolean, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.disponible_pago_cobranza(_pago_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.monto
       - coalesce((SELECT sum(a.monto) FROM public.cobranza_aplicaciones a WHERE a.pago_id = p.id AND a.revertida_at IS NULL), 0)
       - coalesce((SELECT sum(s.monto) FROM public.cobranza_saldos_favor s WHERE s.pago_origen_id = p.id AND s.cancelado_at IS NULL), 0)
    FROM public.cobranza_pagos p WHERE p.id = _pago_id
$$;
CREATE OR REPLACE FUNCTION public.disponible_saldo_favor(_saldo_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN s.cancelado_at IS NOT NULL THEN 0 ELSE s.monto
       - coalesce((SELECT sum(a.monto) FROM public.cobranza_aplicaciones a WHERE a.saldo_favor_id = s.id AND a.revertida_at IS NULL), 0) END
    FROM public.cobranza_saldos_favor s WHERE s.id = _saldo_id
$$;
REVOKE ALL ON FUNCTION public.disponible_pago_cobranza(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.disponible_saldo_favor(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.disponible_pago_cobranza(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.disponible_saldo_favor(uuid) TO authenticated;

-- Valida que la remisión pueda recibir `_monto`: mismo cliente, misma marca
-- de prueba, ya confirmada por Almacén (no cotización), no cancelada.
CREATE OR REPLACE FUNCTION public._validar_destino_cobro(_remision uuid, _cliente uuid, _es_prueba boolean, _monto numeric)
RETURNS public.remisiones_refacciones LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.remisiones_refacciones%ROWTYPE;
  e record;
BEGIN
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la remisión'; END IF;
  IF r.cliente_id <> _cliente THEN RAISE EXCEPTION 'La remisión % es de otro cliente', r.folio; END IF;
  IF r.es_prueba <> _es_prueba THEN
    RAISE EXCEPTION 'No se mezclan datos de prueba con reales: la remisión % es %', r.folio,
      CASE WHEN r.es_prueba THEN 'de prueba' ELSE 'real' END;
  END IF;
  IF r.etapa = 'cancelada' THEN RAISE EXCEPTION 'La remisión % está cancelada', r.folio; END IF;
  IF r.abierta THEN
    RAISE EXCEPTION 'La remisión % sigue como cotización: Almacén todavía no confirma existencias y monto. El dinero puede quedar como saldo a favor.', r.folio;
  END IF;
  SELECT * INTO e FROM public.estado_cobro_remision_refaccion(_remision);
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'El monto a aplicar debe ser mayor a cero'; END IF;
  IF _monto > e.saldo_pendiente THEN
    RAISE EXCEPTION 'A % le quedan % por cobrar y se quieren aplicar %', r.folio,
      to_char(e.saldo_pendiente, 'FM999,999,990.00'), to_char(_monto, 'FM999,999,990.00');
  END IF;
  RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION public._validar_destino_cobro(uuid, uuid, boolean, numeric) FROM PUBLIC, anon, authenticated;

-- Un pago a una o varias remisiones, total o parcial. El remanente se vuelve
-- saldo a favor (pago anticipado si no se aplicó a nada; pago en exceso si sí).
CREATE OR REPLACE FUNCTION public.aplicar_pago_cobranza(_pago_id uuid, _aplicaciones jsonb, _remanente_a_saldo boolean DEFAULT true, _notas text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p public.cobranza_pagos%ROWTYPE;
  it jsonb;
  r public.remisiones_refacciones%ROWTYPE;
  v_disp numeric;
  v_total numeric := 0;
  v_rem numeric;
  v_saldo_folio text;
  v_n integer := 0;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador aplican pagos';
  END IF;
  SELECT * INTO p FROM public.cobranza_pagos WHERE id = _pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el pago'; END IF;
  PERFORM public.exigir_dato_prueba(p.es_prueba, 'el pago ' || p.folio);
  IF p.estatus = 'revertido' THEN RAISE EXCEPTION 'El pago % está revertido', p.folio; END IF;
  IF p.estatus <> 'validado' THEN RAISE EXCEPTION 'Finanzas todavía no valida el pago % (falta la evidencia conciliada)', p.folio; END IF;

  v_disp := public.disponible_pago_cobranza(_pago_id);
  SELECT coalesce(sum((e.value->>'monto')::numeric), 0) INTO v_total FROM jsonb_array_elements(coalesce(_aplicaciones, '[]'::jsonb)) e;
  IF v_total > v_disp THEN
    RAISE EXCEPTION 'El pago % tiene % disponibles y se quieren aplicar %', p.folio,
      to_char(v_disp, 'FM999,999,990.00'), to_char(v_total, 'FM999,999,990.00');
  END IF;

  FOR it IN SELECT value FROM jsonb_array_elements(coalesce(_aplicaciones, '[]'::jsonb)) LOOP
    r := public._validar_destino_cobro((it->>'remision_id')::uuid, p.cliente_id, p.es_prueba, round((it->>'monto')::numeric, 2));
    INSERT INTO public.cobranza_aplicaciones (tipo, pago_id, remision_id, monto, notas, created_by, es_prueba)
    VALUES ('pago', p.id, r.id, round((it->>'monto')::numeric, 2), nullif(trim(_notas), ''), auth.uid(), p.es_prueba);
    INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
    VALUES (r.id, 'finanzas', 'pago_aplicado',
            'Se aplicaron ' || to_char(round((it->>'monto')::numeric, 2), 'FM999,999,990.00') || ' del pago ' || p.folio || '.', auth.uid());
    PERFORM public.cobranza_sincronizar_remision(r.id);
    v_n := v_n + 1;
  END LOOP;

  v_rem := public.disponible_pago_cobranza(_pago_id);
  IF coalesce(_remanente_a_saldo, true) AND v_rem > 0 THEN
    v_saldo_folio := public._siguiente_folio_compras('SF', p.es_prueba);
    INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, pago_origen_id, notas, created_by, es_prueba)
    VALUES (v_saldo_folio, p.cliente_id,
            CASE WHEN EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE pago_id = p.id AND revertida_at IS NULL)
                 THEN 'pago_en_exceso' ELSE 'pago_anticipado' END,
            v_rem, p.id, 'Remanente del pago ' || p.folio, auth.uid(), p.es_prueba);
  END IF;

  PERFORM public.registrar_bitacora_compras('cobranza', 'aplicar_pago', 'cobranza_pagos', p.id, p.folio,
    jsonb_build_object('aplicaciones', _aplicaciones, 'saldo_favor', v_saldo_folio, 'remanente', v_rem), p.es_prueba);
  RETURN jsonb_build_object('aplicadas', v_n, 'saldo_favor', v_saldo_folio, 'remanente', v_rem);
END;
$$;
REVOKE ALL ON FUNCTION public.aplicar_pago_cobranza(uuid, jsonb, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_pago_cobranza(uuid, jsonb, boolean, text) TO authenticated;

-- Quién aplica saldo a favor: parámetro editable por el administrador
-- (por defecto sólo Compras; el administrador siempre).
CREATE OR REPLACE FUNCTION public.puede_aplicar_saldo_favor(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.es_admin_global(_uid) OR public.has_role(_uid, 'admin'::public.app_role)
      OR (public.compras_parametro('saldo_favor_aplican') ? 'compras' AND public.puede_compras_inventario(_uid))
      OR (public.compras_parametro('saldo_favor_aplican') ? 'finanzas' AND public.puede_finanzas_cobranza(_uid))
$$;
REVOKE ALL ON FUNCTION public.puede_aplicar_saldo_favor(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_aplicar_saldo_favor(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.aplicar_saldo_favor(_saldo_id uuid, _remision_id uuid, _monto numeric, _solicitud_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s public.cobranza_saldos_favor%ROWTYPE;
  r public.remisiones_refacciones%ROWTYPE;
  v_id uuid;
BEGIN
  IF NOT public.puede_aplicar_saldo_favor(auth.uid()) THEN
    RAISE EXCEPTION 'No tienes permiso para aplicar saldos a favor (el vendedor puede solicitarlo)';
  END IF;
  SELECT * INTO s FROM public.cobranza_saldos_favor WHERE id = _saldo_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el saldo a favor'; END IF;
  PERFORM public.exigir_dato_prueba(s.es_prueba, 'el saldo ' || s.folio);
  IF s.cancelado_at IS NOT NULL THEN RAISE EXCEPTION 'El saldo % está cancelado', s.folio; END IF;
  IF round(_monto, 2) > public.disponible_saldo_favor(_saldo_id) THEN
    RAISE EXCEPTION 'El saldo % tiene % disponibles', s.folio, to_char(public.disponible_saldo_favor(_saldo_id), 'FM999,999,990.00');
  END IF;
  r := public._validar_destino_cobro(_remision_id, s.cliente_id, s.es_prueba, round(_monto, 2));
  INSERT INTO public.cobranza_aplicaciones (tipo, saldo_favor_id, remision_id, monto, notas, created_by, es_prueba)
  VALUES ('saldo_favor', s.id, r.id, round(_monto, 2), 'Pagado con saldo a favor ' || s.folio || ' (no es dinero nuevo)', auth.uid(), s.es_prueba)
  RETURNING id INTO v_id;
  INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
  VALUES (r.id, 'finanzas', 'saldo_favor_aplicado',
          'Pagado con saldo a favor ' || s.folio || ': ' || to_char(round(_monto, 2), 'FM999,999,990.00') || '.', auth.uid());
  IF _solicitud_id IS NOT NULL THEN
    UPDATE public.cobranza_solicitudes_saldo SET estatus = 'aplicada', resuelto_por = auth.uid(), resuelto_at = now()
     WHERE id = _solicitud_id AND estatus = 'pendiente';
  END IF;
  PERFORM public.cobranza_sincronizar_remision(r.id);
  PERFORM public.registrar_bitacora_compras('cobranza', 'aplicar_saldo_favor', 'cobranza_saldos_favor', s.id, s.folio,
    jsonb_build_object('remision', r.folio, 'monto', _monto), s.es_prueba);
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.aplicar_saldo_favor(uuid, uuid, numeric, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_saldo_favor(uuid, uuid, numeric, uuid) TO authenticated;

-- Ventas ve el saldo vivo de su cliente y solicita usarlo.
CREATE OR REPLACE FUNCTION public.saldo_favor_disponible_cliente(_cliente_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN auth.uid() IS NULL OR (public.rol_comercial(auth.uid()) = 'ninguno'
                AND NOT public.puede_compras_inventario(auth.uid()) AND NOT public.puede_finanzas_cobranza(auth.uid()))
              THEN NULL
         ELSE coalesce((SELECT sum(public.disponible_saldo_favor(s.id)) FROM public.cobranza_saldos_favor s
                         WHERE s.cliente_id = _cliente_id AND s.cancelado_at IS NULL), 0) END
$$;
REVOKE ALL ON FUNCTION public.saldo_favor_disponible_cliente(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.saldo_favor_disponible_cliente(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.solicitar_saldo_favor(_remision_id uuid, _monto numeric, _nota text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.remisiones_refacciones%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision_id;
  IF NOT FOUND OR NOT public.puede_leer_remision_refaccion(_remision_id) THEN
    RAISE EXCEPTION 'No encontramos la remisión';
  END IF;
  PERFORM public.exigir_dato_prueba(r.es_prueba, 'la remisión ' || r.folio);
  IF _monto IS NULL OR _monto <= 0 THEN RAISE EXCEPTION 'Indica el monto'; END IF;
  IF _monto > public.saldo_favor_disponible_cliente(r.cliente_id) THEN
    RAISE EXCEPTION 'El cliente no tiene ese saldo a favor disponible';
  END IF;
  INSERT INTO public.cobranza_solicitudes_saldo (cliente_id, remision_id, monto, nota, solicitado_por, es_prueba)
  VALUES (r.cliente_id, r.id, round(_monto, 2), nullif(trim(_nota), ''), auth.uid(), r.es_prueba)
  RETURNING id INTO v_id;
  INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, folio_remision, datos, creado_por, remision_refaccion_id)
  VALUES ('compras', 'solicitud_saldo_favor', 'Solicitud de saldo a favor en ' || r.folio,
          'Ventas pide aplicar ' || to_char(round(_monto, 2), 'FM999,999,990.00') || ' de saldo a favor.',
          r.folio, jsonb_build_object('solicitud_id', v_id, 'ruta', '/cobranza'), auth.uid(), r.id);
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.solicitar_saldo_favor(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.solicitar_saldo_favor(uuid, numeric, text) TO authenticated;

-- Revertir: el pago y todas sus aplicaciones quedan marcados (no se borran),
-- con motivo, quién y cuándo. Si su remanente ya se usó como saldo a favor,
-- primero hay que revertir ese uso.
CREATE OR REPLACE FUNCTION public.revertir_pago_cobranza(_pago_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p public.cobranza_pagos%ROWTYPE;
  a record;
  s record;
BEGIN
  IF NOT (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo Compras o Finanzas revierten pagos';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'El motivo de la reversión es obligatorio';
  END IF;
  SELECT * INTO p FROM public.cobranza_pagos WHERE id = _pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el pago'; END IF;
  PERFORM public.exigir_dato_prueba(p.es_prueba, 'el pago ' || p.folio);
  IF p.estatus = 'revertido' THEN RAISE EXCEPTION 'El pago % ya está revertido', p.folio; END IF;

  FOR s IN SELECT * FROM public.cobranza_saldos_favor WHERE pago_origen_id = _pago_id AND cancelado_at IS NULL LOOP
    IF EXISTS (SELECT 1 FROM public.cobranza_aplicaciones WHERE saldo_favor_id = s.id AND revertida_at IS NULL) THEN
      RAISE EXCEPTION 'El remanente de % ya se usó como saldo a favor (%). Revierte primero ese uso.', p.folio, s.folio;
    END IF;
    UPDATE public.cobranza_saldos_favor SET cancelado_at = now(), cancelado_por = auth.uid(),
           motivo_cancelacion = 'Reversión del pago ' || p.folio || ': ' || trim(_motivo)
     WHERE id = s.id;
  END LOOP;

  FOR a IN SELECT * FROM public.cobranza_aplicaciones WHERE pago_id = _pago_id AND revertida_at IS NULL LOOP
    UPDATE public.cobranza_aplicaciones SET revertida_at = now(), revertida_por = auth.uid(), motivo_reversion = trim(_motivo)
     WHERE id = a.id;
    INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
    VALUES (a.remision_id, 'finanzas', 'pago_revertido',
            'Se revirtió lo aplicado del pago ' || p.folio || ' (' || to_char(a.monto, 'FM999,999,990.00') || '). ' || trim(_motivo), auth.uid());
    PERFORM public.cobranza_sincronizar_remision(a.remision_id);
  END LOOP;

  UPDATE public.cobranza_pagos SET estatus = 'revertido', revertido_por = auth.uid(), revertido_at = now(),
         motivo_reversion = trim(_motivo)
   WHERE id = _pago_id;
  PERFORM public.registrar_bitacora_compras('cobranza', 'revertir_pago', 'cobranza_pagos', p.id, p.folio,
    jsonb_build_object('motivo', _motivo, 'monto', p.monto), p.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.revertir_pago_cobranza(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revertir_pago_cobranza(uuid, text) TO authenticated;

-- Revertir una sola aplicación (para reaplicar distinto), con motivo.
CREATE OR REPLACE FUNCTION public.revertir_aplicacion_cobranza(_aplicacion_id uuid, _motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.cobranza_aplicaciones%ROWTYPE;
BEGIN
  IF NOT (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid())) THEN
    RAISE EXCEPTION 'Sólo Compras o Finanzas revierten aplicaciones';
  END IF;
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'El motivo de la reversión es obligatorio';
  END IF;
  SELECT * INTO a FROM public.cobranza_aplicaciones WHERE id = _aplicacion_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la aplicación'; END IF;
  PERFORM public.exigir_dato_prueba(a.es_prueba, 'la aplicación');
  IF a.revertida_at IS NOT NULL THEN RAISE EXCEPTION 'Ya estaba revertida'; END IF;
  UPDATE public.cobranza_aplicaciones SET revertida_at = now(), revertida_por = auth.uid(), motivo_reversion = trim(_motivo)
   WHERE id = _aplicacion_id;
  INSERT INTO public.remision_refaccion_eventos (remision_id, area, accion, detalle, usuario_id)
  VALUES (a.remision_id, 'finanzas', 'aplicacion_revertida',
          'Se revirtió una aplicación de ' || to_char(a.monto, 'FM999,999,990.00') || '. ' || trim(_motivo), auth.uid());
  PERFORM public.cobranza_sincronizar_remision(a.remision_id);
  PERFORM public.registrar_bitacora_compras('cobranza', 'revertir_aplicacion', 'cobranza_aplicaciones', a.id, NULL,
    jsonb_build_object('motivo', _motivo, 'monto', a.monto, 'remision_id', a.remision_id), a.es_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.revertir_aplicacion_cobranza(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revertir_aplicacion_cobranza(uuid, text) TO authenticated;

-- ── 8. Vistas de consulta ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_cobranza_remisiones
WITH (security_invoker = true) AS
SELECT r.id, r.folio, r.cliente_id, r.fecha_remision, r.etapa, r.abierta, r.es_prueba, r.pagado,
       coalesce(c.nombre_comercial, c.razon_social, c.codigo_erp) AS cliente,
       c.codigo_erp, public.cliente_tiene_credito(r.cliente_id) AS cliente_con_credito,
       CASE WHEN r.etapa = 'cancelada' THEN 'cancelada'
            WHEN r.abierta THEN 'cotizacion' ELSE 'confirmada' END AS documento,
       e.total, e.cobrado_dinero, e.cobrado_saldo_favor, e.trasladado_saldo_favor, e.cobrado_neto, e.saldo_pendiente,
       (SELECT string_agg(o.folio, ', ' ORDER BY o.folio) FROM public.remision_refaccion_ordenes o WHERE o.remision_id = r.id) AS ordenes,
       (SELECT string_agg(DISTINCT i.codigo_nuevo, ', ') FROM public.remision_refaccion_items i WHERE i.remision_id = r.id) AS productos
  FROM public.remisiones_refacciones r
  JOIN public.clientes c ON c.id = r.cliente_id
  CROSS JOIN LATERAL public.estado_cobro_remision_refaccion(r.id) e;
GRANT SELECT ON public.v_cobranza_remisiones TO authenticated;

CREATE OR REPLACE VIEW public.v_cobranza_saldos_favor
WITH (security_invoker = true) AS
SELECT s.id, s.folio, s.cliente_id, coalesce(c.nombre_comercial, c.razon_social, c.codigo_erp) AS cliente,
       s.origen, s.monto AS generado,
       coalesce((SELECT sum(a.monto) FROM public.cobranza_aplicaciones a WHERE a.saldo_favor_id = s.id AND a.revertida_at IS NULL), 0) AS aplicado,
       public.disponible_saldo_favor(s.id) AS disponible,
       (SELECT folio FROM public.remisiones_refacciones WHERE id = s.remision_origen_id) AS remision_origen,
       (SELECT folio FROM public.cobranza_pagos WHERE id = s.pago_origen_id) AS pago_origen,
       s.notas, s.created_at, s.cancelado_at, s.motivo_cancelacion, s.es_prueba
  FROM public.cobranza_saldos_favor s
  JOIN public.clientes c ON c.id = s.cliente_id;
GRANT SELECT ON public.v_cobranza_saldos_favor TO authenticated;

CREATE OR REPLACE VIEW public.v_cobranza_pagos
WITH (security_invoker = true) AS
SELECT p.*, coalesce(c.nombre_comercial, c.razon_social, c.codigo_erp) AS cliente,
       coalesce((SELECT sum(a.monto) FROM public.cobranza_aplicaciones a WHERE a.pago_id = p.id AND a.revertida_at IS NULL), 0) AS aplicado,
       coalesce((SELECT sum(s.monto) FROM public.cobranza_saldos_favor s WHERE s.pago_origen_id = p.id AND s.cancelado_at IS NULL), 0) AS a_saldo_favor,
       public.disponible_pago_cobranza(p.id) AS disponible
  FROM public.cobranza_pagos p
  JOIN public.clientes c ON c.id = p.cliente_id;
GRANT SELECT ON public.v_cobranza_pagos TO authenticated;

-- Detalle para el recibo PDF de aplicación de pago.
CREATE OR REPLACE FUNCTION public.recibo_pago_cobranza(_pago_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb;
BEGIN
  IF NOT (public.puede_compras_inventario(auth.uid()) OR public.puede_finanzas_cobranza(auth.uid())) THEN
    RAISE EXCEPTION 'Sin acceso';
  END IF;
  PERFORM public.exigir_lectura_prueba('cobranza_pagos', _pago_id);
  SELECT jsonb_build_object(
    'pago', to_jsonb(p) - 'evidencia_path',
    'cliente', jsonb_build_object('nombre', coalesce(c.nombre_comercial, c.razon_social), 'codigo', c.codigo_erp, 'rfc', c.rfc),
    'aplicaciones', coalesce((
      SELECT jsonb_agg(jsonb_build_object('folio', r.folio, 'monto', a.monto, 'revertida', a.revertida_at IS NOT NULL,
             'saldo_restante', (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r.id)),
             'total', public.total_vigente_remision_refaccion(r.id)) ORDER BY r.folio)
        FROM public.cobranza_aplicaciones a JOIN public.remisiones_refacciones r ON r.id = a.remision_id
       WHERE a.pago_id = p.id), '[]'::jsonb),
    'saldos_favor', coalesce((SELECT jsonb_agg(jsonb_build_object('folio', s.folio, 'monto', s.monto, 'origen', s.origen))
        FROM public.cobranza_saldos_favor s WHERE s.pago_origen_id = p.id AND s.cancelado_at IS NULL), '[]'::jsonb),
    'disponible', public.disponible_pago_cobranza(p.id)
  ) INTO v
  FROM public.cobranza_pagos p JOIN public.clientes c ON c.id = p.cliente_id WHERE p.id = _pago_id;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public.recibo_pago_cobranza(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recibo_pago_cobranza(uuid) TO authenticated;

-- ── 9. «Marcar como pagado» pide evidencia ─────────────────────────────────
-- La función de siempre sigue existiendo; la pantalla usa ésta, que exige el
-- archivo (imagen/PDF de la transferencia o el vale) y la marca de conciliado.
ALTER TABLE public.remisiones_refacciones
  ADD COLUMN IF NOT EXISTS evidencia_pago_path text,
  ADD COLUMN IF NOT EXISTS pago_conciliado boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.marcar_pago_remision_con_evidencia(
  _remision_id uuid, _pagado boolean, _nota text, _evidencia_path text, _conciliado boolean DEFAULT true
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.remisiones_refacciones%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encontró la remisión'; END IF;
  PERFORM public.exigir_dato_prueba(r.es_prueba, 'la remisión ' || r.folio);
  IF coalesce(_pagado, false) AND nullif(trim(_evidencia_path), '') IS NULL THEN
    RAISE EXCEPTION 'Sube la evidencia del pago (imagen o PDF de la transferencia, o el vale de efectivo)';
  END IF;
  PERFORM public.marcar_pago_remision_refaccion(_remision_id, _pagado, _nota);
  UPDATE public.remisiones_refacciones
     SET evidencia_pago_path = CASE WHEN _pagado THEN trim(_evidencia_path) ELSE evidencia_pago_path END,
         pago_conciliado = coalesce(_pagado, false) AND coalesce(_conciliado, false)
   WHERE id = _remision_id;
  IF coalesce(_pagado, false) THEN
    INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, folio_remision, datos, creado_por, remision_refaccion_id)
    VALUES ('compras', 'pago_validado', 'Pago validado en ' || r.folio,
            'Finanzas validó el pago con evidencia. Registra/aplica el pago en Cobranza.',
            r.folio, jsonb_build_object('ruta', '/cobranza'), auth.uid(), r.id);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.marcar_pago_remision_con_evidencia(uuid, boolean, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_pago_remision_con_evidencia(uuid, boolean, text, text, boolean) TO authenticated;

-- ── 10. Logística cierra la entrega sólo con pago validado ─────────────────
-- Siempre en datos de prueba; en reales cuando Compras active
-- compras_parametros.entrega_exige_pago (hoy apagado para no frenar lo que
-- ya está en curso).
CREATE OR REPLACE FUNCTION public.candado_entrega_con_pago()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e record;
BEGIN
  IF NEW.entregada_at IS NOT NULL AND OLD.entregada_at IS NULL
     AND (NEW.es_prueba OR coalesce(public.compras_parametro('entrega_exige_pago') = 'true'::jsonb, false)) THEN
    SELECT * INTO e FROM public.estado_cobro_remision_refaccion(NEW.id);
    IF NOT (NEW.pagado OR e.saldo_pendiente = 0 OR public.cliente_tiene_credito(NEW.cliente_id)) THEN
      RAISE EXCEPTION 'La remisión % no tiene el pago validado (faltan %). Logística cierra la entrega cuando Finanzas valida el pago.',
        NEW.folio, to_char(e.saldo_pendiente, 'FM999,999,990.00');
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_candado_entrega_con_pago ON public.remisiones_refacciones;
CREATE TRIGGER trg_candado_entrega_con_pago
  BEFORE UPDATE OF entregada_at ON public.remisiones_refacciones
  FOR EACH ROW EXECUTE FUNCTION public.candado_entrega_con_pago();

-- ── 11. Cargador de saldos iniciales (DISEÑADO, SIN EJECUTAR) ──────────────
-- No se importa cartera de Ecount. Cuando Polo entregue los cinco clientes
-- del primer ejercicio, un administrador activa el parámetro
-- `cargador_saldos_habilitado` y corre la carga con la frase de confirmación.
INSERT INTO public.compras_parametros (clave, valor, descripcion)
VALUES ('cargador_saldos_habilitado', 'false', 'Habilita la carga de saldos iniciales de cobranza (apagado hasta que Polo entregue la lista)')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cargar_saldos_iniciales_cobranza(_items jsonb, _confirmacion text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it jsonb;
  v_cli public.clientes%ROWTYPE;
  v_sf integer := 0;
  v_cxc integer := 0;
BEGIN
  IF NOT (public.es_admin_global(auth.uid()) OR public.has_role(auth.uid(), 'admin'::public.app_role)) THEN
    RAISE EXCEPTION 'Sólo un administrador carga saldos iniciales';
  END IF;
  IF public.compras_parametro('cargador_saldos_habilitado') IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'El cargador de saldos iniciales está apagado. Se activa cuando Polo entregue la lista de clientes.';
  END IF;
  IF _confirmacion IS DISTINCT FROM 'CARGAR SALDOS INICIALES' THEN
    RAISE EXCEPTION 'Escribe exactamente: CARGAR SALDOS INICIALES';
  END IF;
  IF jsonb_array_length(_items) > 5 THEN
    RAISE EXCEPTION 'El primer ejercicio es de cinco clientes como máximo';
  END IF;
  FOR it IN SELECT value FROM jsonb_array_elements(_items) LOOP
    SELECT * INTO v_cli FROM public.clientes WHERE id = (it->>'cliente_id')::uuid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Un cliente no existe'; END IF;
    IF (it->>'monto')::numeric <= 0 THEN RAISE EXCEPTION 'Montos positivos'; END IF;
    IF it->>'tipo' = 'saldo_favor' THEN
      INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, notas, created_by, es_prueba)
      VALUES (public._siguiente_folio_compras('SF', v_cli.es_prueba), v_cli.id, 'saldo_inicial', (it->>'monto')::numeric,
              'Saldo inicial: ' || coalesce(it->>'referencia', ''), auth.uid(), v_cli.es_prueba);
      v_sf := v_sf + 1;
    ELSIF it->>'tipo' = 'por_cobrar' THEN
      IF NOT public.cliente_tiene_credito(v_cli.id) THEN
        RAISE EXCEPTION 'Sólo un cliente con crédito tiene cuenta por cobrar (%)', coalesce(v_cli.nombre_comercial, v_cli.id::text);
      END IF;
      INSERT INTO public.cuentas_por_cobrar (cliente_id, concepto, monto, saldo, fecha_emision, fecha_vencimiento, notas, created_by)
      VALUES (v_cli.id, 'Saldo inicial migrado', (it->>'monto')::numeric, (it->>'monto')::numeric,
              coalesce((it->>'fecha')::date, CURRENT_DATE), coalesce((it->>'vence')::date, CURRENT_DATE + 30),
              it->>'referencia', auth.uid());
      v_cxc := v_cxc + 1;
    ELSE
      RAISE EXCEPTION 'Tipo de saldo inválido: usa saldo_favor o por_cobrar';
    END IF;
  END LOOP;
  PERFORM public.registrar_bitacora_compras('cobranza', 'cargar_saldos_iniciales', NULL, NULL, NULL, _items, false);
  RETURN jsonb_build_object('saldos_favor', v_sf, 'por_cobrar', v_cxc);
END;
$$;
REVOKE ALL ON FUNCTION public.cargar_saldos_iniciales_cobranza(jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_saldos_iniciales_cobranza(jsonb, text) TO authenticated;

-- ── 12. Postflight ──────────────────────────────────────────────────────────
DO $postflight$
BEGIN
  IF to_regprocedure('public.aplicar_pago_cobranza(uuid,jsonb,boolean,text)') IS NULL
     OR to_regclass('public.v_cobranza_remisiones') IS NULL THEN
    RAISE EXCEPTION 'No quedó la cobranza';
  END IF;
  IF EXISTS (SELECT 1 FROM public.remision_refaccion_items WHERE orden_id IS NULL) THEN
    RAISE EXCEPTION 'Quedaron partidas sin orden de inventario';
  END IF;
END $postflight$;

NOTIFY pgrst, 'reload schema';
