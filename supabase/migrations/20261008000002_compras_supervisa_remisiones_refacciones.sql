-- ============================================================================
-- Compras (supervisor y administrador) también levanta y corrige remisiones de
-- REFACCIONES
-- Fecha: 2026-10-08
--
-- Complemento de 20261008000001 (remisiones de motocarro). Las remisiones de
-- refacciones validan el permiso dentro de sus RPC con `rol_comercial()`, que
-- para Compras devuelve 'ninguno': «No tienes permiso para levantar remisiones
-- de refacciones».
--
-- Misma regla por ÁREA × NIVEL (`compras_supervisa_remisiones`): el supervisor y
-- el administrador de Compras trabajan como un supervisor de Comercial:
--   · levantan remisiones nuevas      (crear_remision_refacciones)
--   · corrigen envío/pago/descuentos  (actualizar_envio_remision_refaccion)
--   · cancelan partidas o la remisión (cancelar_linea_refaccion,
--                                      cancelar_remision_refacciones)
-- La lectura de todas ya la tenía Compras («compras lee remisiones
-- refacciones», 20261006000003). Almacén, logística y pagos no cambian.
--
-- Las 3 funciones de corrección/cancelación se copian tal cual de su última
-- versión (20260925000001/03/04) con un único cambio: `OR
-- public.compras_supervisa_remisiones(auth.uid())` junto a ('global','supervisor').
--
-- Requiere 20261008000001 y las migraciones de refacciones 20260923000001,
-- 20260925000001, 20260925000003 y 20260925000004.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regprocedure('public.compras_supervisa_remisiones(uuid)') IS NULL THEN _faltan := _faltan || 'función compras_supervisa_remisiones (20261008000001)'::text; END IF;
  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN _faltan := _faltan || 'función rol_comercial (20260902000001)'::text; END IF;
  IF to_regclass('public.remisiones_refacciones') IS NULL THEN _faltan := _faltan || 'tabla remisiones_refacciones (20260923000001)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND table_name = 'remisiones_refacciones' AND column_name = 'cancelada_at') THEN
    _faltan := _faltan || 'columna remisiones_refacciones.cancelada_at (20260925000004)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                  AND table_name = 'remisiones_refacciones' AND column_name = 'descuento_pct') THEN
    _faltan := _faltan || 'columna remisiones_refacciones.descuento_pct (20260925000003)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END $preflight$;

-- ── 1. Levantar remisiones (crear_remision_refacciones lo revisa) ───────────
CREATE OR REPLACE FUNCTION public.puede_capturar_refacciones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.rol_comercial(_user_id) IN ('operador', 'supervisor', 'global')
      OR public.compras_supervisa_remisiones(_user_id);
$$;

REVOKE ALL ON FUNCTION public.puede_capturar_refacciones(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.puede_capturar_refacciones(UUID) TO authenticated;

-- ── 2. Corregir envío, pago y descuentos (copia de 20260925000003) ──────────
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
  IF NOT (v_rol IN ('global', 'supervisor') OR public.compras_supervisa_remisiones(auth.uid()) OR v_row.vendedor_id = auth.uid() OR v_row.created_by = auth.uid()) THEN
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

-- ── 3. Cancelar una partida (copia de 20260925000001) ───────────────────────
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
    OR public.compras_supervisa_remisiones(auth.uid())
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

-- ── 4. Cancelar la remisión (copia de 20260925000004) ───────────────────────
CREATE OR REPLACE FUNCTION public.cancelar_remision_refacciones(_remision_id UUID, _motivo TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.remisiones_refacciones%ROWTYPE;
  v_rol text;
  v_item public.remision_refaccion_items%ROWTYPE;
BEGIN
  IF nullif(trim(_motivo), '') IS NULL OR char_length(trim(_motivo)) < 3 THEN
    RAISE EXCEPTION 'Escribe el motivo (mínimo 3 caracteres)';
  END IF;

  SELECT * INTO v_row
  FROM public.remisiones_refacciones
  WHERE id = _remision_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la remisión';
  END IF;
  IF v_row.etapa = 'cancelada' THEN
    RAISE EXCEPTION 'Esta remisión ya está cancelada';
  END IF;
  IF v_row.etapa = 'entregada' OR v_row.entregada_at IS NOT NULL THEN
    RAISE EXCEPTION 'Una remisión entregada no se cancela; queda en Entregadas';
  END IF;

  v_rol := public.rol_comercial();
  IF NOT (
    v_rol IN ('global', 'supervisor')
    OR public.compras_supervisa_remisiones(auth.uid())
    OR (v_rol = 'operador' AND (v_row.vendedor_id = auth.uid() OR v_row.created_by = auth.uid()))
  ) THEN
    RAISE EXCEPTION 'No puedes cancelar esta remisión';
  END IF;

  FOR v_item IN
    SELECT * FROM public.remision_refaccion_items
    WHERE remision_id = _remision_id
      AND cantidad_bloqueada > 0
    FOR UPDATE
  LOOP
    UPDATE public.remision_refaccion_items
    SET cantidad_bloqueada = 0,
        cantidad_faltante = 0,
        estatus = 'cancelada'
    WHERE id = v_item.id;
  END LOOP;

  UPDATE public.remision_refaccion_items
  SET estatus = 'cancelada'
  WHERE remision_id = _remision_id
    AND estatus <> 'surtida';

  UPDATE public.remisiones_refacciones
  SET etapa = 'cancelada',
      area_actual = 'ventas',
      abierta = false,
      motivo_cancelacion = trim(_motivo),
      cancelada_at = now()
  WHERE id = _remision_id;

  INSERT INTO public.remision_refaccion_eventos (
    remision_id, area, accion, detalle, usuario_id
  ) VALUES (
    _remision_id, 'ventas', 'cancelar_remision',
    'Cancelada. Quedó en Canceladas para revisión. ' || trim(_motivo),
    auth.uid()
  );
END;
$$;

NOTIFY pgrst, 'reload schema';

-- ── Verificación: quién puede levantar remisiones de refacciones en Compras ─
SELECT u.email, ur.area::text AS area, ur.nivel::text AS nivel,
       public.compras_supervisa_remisiones(u.id) AS supervisa_remisiones_desde_compras,
       public.puede_capturar_refacciones(u.id) AS puede_levantar_refacciones
  FROM public.user_roles ur
  JOIN auth.users u ON u.id = ur.user_id
 WHERE ur.area::text = 'compras'
 ORDER BY ur.nivel::text, u.email;
