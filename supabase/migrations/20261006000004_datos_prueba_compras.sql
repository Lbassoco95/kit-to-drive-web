-- ============================================================================
-- Datos de prueba para Compras — 2026-10-06
-- ----------------------------------------------------------------------------
-- Requiere 20261006000001..3.
--
-- Este script SÓLO crea las funciones. No siembra nada por sí mismo: la
-- siembra la corre un administrador desde la pantalla (o en el SQL editor con
-- `SELECT public.sembrar_datos_prueba_compras();`).
--
-- · Todo lo sembrado lleva es_prueba = true y nombres «PRUEBA» / códigos TST-.
-- · La siembra es idempotente: si ya está, no duplica.
-- · «Reiniciar datos de prueba» borra SOLO lo marcado como prueba y vuelve a
--   sembrar. Pide escribir la frase de confirmación.
-- · Las remisiones de prueba llevan su propia serie (P-RF-00001) para no
--   gastar ni dejar huecos en la numeración real RF-.
--
-- Idempotente. Pensado para el SQL editor de Supabase, no para db push.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('public.aplicar_pago_cobranza(uuid,jsonb,boolean,text)') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Corre antes 20261006000003_cobranza_refacciones.sql';
  END IF;
END $preflight$;

-- Las remisiones de prueba usan su propia serie de folios.
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
  IF NEW.es_prueba AND NEW.folio NOT LIKE 'P-%' THEN
    NEW.folio := public._siguiente_folio_compras('RF', true);
  END IF;
  RETURN NEW;
END;
$$;

-- Ayudantes de la siembra (internos) ----------------------------------------
CREATE OR REPLACE FUNCTION public._prueba_producto(_codigo text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.almacen_refacciones_productos WHERE codigo_nuevo = _codigo AND es_prueba
$$;
CREATE OR REPLACE FUNCTION public._prueba_cliente(_n integer)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.clientes WHERE codigo_erp = 'TST-C' || lpad(_n::text, 2, '0') AND es_prueba
$$;

CREATE OR REPLACE FUNCTION public._prueba_remision(_cliente integer, _dias_atras integer, _partidas jsonb, _notas text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  it jsonb;
  p public.almacen_refacciones_productos%ROWTYPE;
BEGIN
  INSERT INTO public.remisiones_refacciones (folio, cliente_id, nombre_vendedor, fecha_remision, notas, etapa, area_actual,
    abierta, tipo_envio, direccion_entrega, tipo_pago, forma_pago, descuento_pct, pagado)
  VALUES ('tmp-' || gen_random_uuid(), public._prueba_cliente(_cliente), 'Vendedor PRUEBA',
          (now() AT TIME ZONE 'America/Mexico_City')::date - _dias_atras, _notas, 'almacen', 'almacen', true,
          'directo', 'Calle PRUEBA 123, Col. Ficticia, CDMX', 'anticipado', 'transferencia', 0, false)
  RETURNING id INTO v_id;
  FOR it IN SELECT value FROM jsonb_array_elements(_partidas) LOOP
    SELECT * INTO p FROM public.almacen_refacciones_productos WHERE id = public._prueba_producto(it->>'codigo');
    INSERT INTO public.remision_refaccion_items (remision_id, producto_id, codigo_nuevo, codigo_antiguo, descripcion,
      precio_unitario, descuento_pct, cantidad, cantidad_bloqueada, cantidad_surtida, cantidad_faltante, estatus)
    VALUES (v_id, p.id, p.codigo_nuevo, p.codigo_antiguo, coalesce(p.descripcion_corta, p.descripcion), p.precio,
            coalesce((it->>'descuento')::numeric, 0), (it->>'cantidad')::integer, (it->>'cantidad')::integer, 0, 0, 'bloqueada');
  END LOOP;
  INSERT INTO public.remision_refaccion_eventos (remision_id, etapa, area, accion, detalle)
  VALUES (v_id, 'almacen', 'ventas', 'captura', 'Remisión de PRUEBA sembrada.');
  RETURN v_id;
END;
$$;

-- Surte todo lo apartado de una remisión (como «Liberar y descontar»).
CREATE OR REPLACE FUNCTION public._prueba_surtir(_remision uuid, _codigo text DEFAULT NULL, _cantidad integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  i public.remision_refaccion_items%ROWTYPE;
  r public.remisiones_refacciones%ROWTYPE;
  q integer;
BEGIN
  SELECT * INTO r FROM public.remisiones_refacciones WHERE id = _remision;
  FOR i IN SELECT * FROM public.remision_refaccion_items
            WHERE remision_id = _remision AND cantidad_bloqueada > 0 AND (_codigo IS NULL OR codigo_nuevo = _codigo) LOOP
    q := coalesce(_cantidad, i.cantidad_bloqueada);
    PERFORM public._mover_inventario_refaccion(i.producto_id, i.almacen, -q, r.fecha_remision, 'venta', 'remision', r.id,
      r.folio, NULL, 'Salida por remisión ' || r.folio, r.cliente_id, i.precio_unitario, true);
    UPDATE public.remision_refaccion_items
       SET cantidad_bloqueada = cantidad_bloqueada - q, cantidad_surtida = cantidad_surtida + q,
           estatus = CASE WHEN cantidad_bloqueada - q = 0 THEN 'surtida' ELSE 'bloqueada' END
     WHERE id = i.id;
  END LOOP;
  PERFORM public.recalcular_etapa_remision_refaccion(_remision);
END;
$$;

CREATE OR REPLACE FUNCTION public._prueba_pago(_cliente integer, _dias_atras integer, _monto numeric, _forma text, _ref text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.cobranza_pagos (folio, cliente_id, fecha, monto, forma, cuenta_destino, referencia, evidencia_path,
    evidencia_tipo, notas, estatus, conciliado, validado_at, es_prueba)
  VALUES (public._siguiente_folio_compras('CP', true), public._prueba_cliente(_cliente),
          (now() AT TIME ZONE 'America/Mexico_City')::date - _dias_atras, _monto, _forma, 'Cuenta PRUEBA ****0000', _ref,
          'prueba/evidencia-PRUEBA.png', CASE WHEN _forma = 'efectivo' THEN 'vale_efectivo' ELSE 'transferencia' END,
          'Pago de PRUEBA', 'validado', true, now(), true)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._prueba_aplicar(_pago uuid, _remision uuid, _monto numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.cobranza_aplicaciones (tipo, pago_id, remision_id, monto, es_prueba)
  VALUES ('pago', _pago, _remision, _monto, true);
  PERFORM public.cobranza_sincronizar_remision(_remision);
END;
$$;

REVOKE ALL ON FUNCTION public._prueba_producto(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._prueba_cliente(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._prueba_remision(integer, integer, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._prueba_surtir(uuid, text, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._prueba_pago(integer, integer, numeric, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._prueba_aplicar(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;

-- ── Siembra ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sembrar_datos_prueba_compras()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Mexico_City')::date;
  cat jsonb := '[
    {"c":"TST-001","d":"Balata delantera PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":200,"p":85,"m":"TST-FT-180"},
    {"c":"TST-002","d":"Bujía PRUEBA (10 PZAS/BOLSA)","l":"linea_dorada","u":"bolsa","pu":10,"cj":50,"p":250,"m":"TST-DS-150"},
    {"c":"TST-003","d":"Juego de empaques de motor PRUEBA","l":"linea_dorada","u":"juego","pu":12,"cj":null,"p":320,"m":"TST-DS-150"},
    {"c":"TST-004","d":"Amortiguador trasero PRUEBA","l":"linea_dorada","u":"par","pu":2,"cj":10,"p":900,"m":"TST-FT-180"},
    {"c":"TST-005","d":"Cadena 428 PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":20,"p":210,"m":"TST-FT180"},
    {"c":"TST-006","d":"Llanta 3.00-18 PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":null,"p":650,"m":"TST-DS-150"},
    {"c":"TST-007","d":"Filtro de aire PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":100,"p":95,"m":"TST-FT 180"},
    {"c":"TST-008","d":"Foco H4 PRUEBA (10 PZAS/BOLSA)","l":"linea_dorada","u":"bolsa","pu":10,"cj":20,"p":180,"m":"TST-DS-150"},
    {"c":"TST-009","d":"Espejo retrovisor PRUEBA","l":"linea_dorada","u":"par","pu":2,"cj":null,"p":160,"m":"TST-FT-180"},
    {"c":"TST-010","d":"Palanca de freno PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":null,"p":70,"m":"TST-FT180"},
    {"c":"TST-011","d":"Cable de clutch PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":50,"p":60,"m":"TST-DS-150"},
    {"c":"TST-012","d":"Juego de tornillería PRUEBA","l":"linea_dorada","u":"juego","pu":20,"cj":null,"p":120,"m":"TST-DS-150"},
    {"c":"TST-013","d":"Manubrio PRUEBA (sin existencia)","l":"linea_dorada","u":"pieza","pu":1,"cj":null,"p":380,"m":"TST-FT 180"},
    {"c":"TST-014","d":"Faro delantero PRUEBA (existencia baja)","l":"linea_dorada","u":"pieza","pu":1,"cj":null,"p":540,"m":"TST-FT-180"},
    {"c":"TST-015","d":"Carburador PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":null,"p":980,"m":"TST-DS-150"},
    {"c":"TST-016","d":"Juego de arrastre PRUEBA","l":"linea_dorada","u":"juego","pu":3,"cj":null,"p":750,"m":"TST-FT180"},
    {"c":"TST-017","d":"Batería 12V PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":6,"p":720,"m":"TST-DS-150"},
    {"c":"TST-018","d":"Asiento PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":null,"p":600,"m":"TST-FT-180"},
    {"c":"TST-019","d":"Amortiguador delantero línea azul PRUEBA","l":"linea_azul","u":"pieza","pu":1,"cj":null,"p":450,"m":"TST-DS-150"},
    {"c":"TST-020","d":"Balata trasera línea azul PRUEBA","l":"linea_azul","u":"pieza","pu":1,"cj":100,"p":70,"m":"TST-FT-180"},
    {"c":"TST-021","d":"Bujía línea azul PRUEBA","l":"linea_azul","u":"pieza","pu":1,"cj":null,"p":25,"m":"TST-DS-150"},
    {"c":"TST-022","d":"Cadena línea azul PRUEBA","l":"linea_azul","u":"pieza","pu":1,"cj":null,"p":180,"m":"TST-FT180"},
    {"c":"TST-023","d":"Filtro de gasolina PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":100,"p":30,"m":"TST-DS-150"},
    {"c":"TST-024","d":"Tapón de tanque PRUEBA","l":"linea_dorada","u":"pieza","pu":1,"cj":null,"p":90,"m":"TST-FT 180"},
    {"c":"TST-025","d":"Direccional PRUEBA","l":"linea_dorada","u":"par","pu":2,"cj":null,"p":140,"m":"TST-DS-150"}
  ]'::jsonb;
  it jsonb;
  k integer;
  v_prod uuid;
  v_uni uuid;
  v_base integer;
  v_final integer;
  v_ventas integer;
  m integer;
  q integer;
  v_fecha date;
  v_cli integer;
  v_q integer;
  r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid; r6 uuid; r7 uuid; r8 uuid; r9 uuid; r10 uuid;
  v_compra uuid;
  v_compra2 uuid;
  v_rec uuid;
  v_aj uuid;
  pg1 uuid; pg2 uuid; pg3 uuid; pg4 uuid; pg5 uuid;
  v_sf uuid;
  v_hist integer := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT (public.es_admin_global(auth.uid()) OR public.has_role(auth.uid(), 'admin'::public.app_role)) THEN
    RAISE EXCEPTION 'Sólo un administrador siembra los datos de prueba';
  END IF;
  IF EXISTS (SELECT 1 FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-001' AND es_prueba) THEN
    RETURN jsonb_build_object('sembrado', false, 'mensaje', 'Los datos de prueba ya estaban sembrados; no se duplicó nada.');
  END IF;
  IF EXISTS (SELECT 1 FROM public.almacen_refacciones_productos WHERE codigo_nuevo LIKE 'TST-%' AND NOT es_prueba) THEN
    RAISE EXCEPTION 'Hay artículos reales con código TST-: no se siembra para no confundirlos';
  END IF;

  -- Clientes (8) ------------------------------------------------------------
  INSERT INTO public.clientes (codigo_erp, nombre_comercial, razon_social, rfc, telefono, email, direccion,
                               dias_credito, limite_credito, notas, es_prueba)
  VALUES
    ('TST-C01', 'CLIENTE PRUEBA 1', 'CLIENTE PRUEBA 1 CONTADO SA DE CV', 'PRUE000000T01', '5500000001', 'prueba1@dazon.demo', 'Calle PRUEBA 1', 0, NULL, 'De contado', true),
    ('TST-C02', 'CLIENTE PRUEBA 2', 'CLIENTE PRUEBA 2 CREDITO SA DE CV', 'PRUE000000T02', '5500000002', 'prueba2@dazon.demo', 'Calle PRUEBA 2', 30, 50000, 'Con crédito a 30 días', true),
    ('TST-C03', 'CLIENTE PRUEBA 3', 'CLIENTE PRUEBA 3 SALDO A FAVOR', 'PRUE000000T03', '5500000003', 'prueba3@dazon.demo', 'Calle PRUEBA 3', 0, NULL, 'Tiene saldo a favor vivo', true),
    ('TST-C04', 'CLIENTE PRUEBA 4', 'CLIENTE PRUEBA 4 ANTICIPO', 'PRUE000000T04', '5500000004', 'prueba4@dazon.demo', 'Calle PRUEBA 4', 0, NULL, 'Pagó por adelantado y no ha comprado', true),
    ('TST-C05', 'CLIENTE PRUEBA 5', 'CLIENTE PRUEBA 5 NUEVO', 'PRUE000000T05', '5500000005', 'prueba5@dazon.demo', 'Calle PRUEBA 5', 0, NULL, 'Nuevo, sin historial', true),
    ('TST-C06', 'CLIENTE PRUEBA 6', 'CLIENTE PRUEBA 6 MAYORISTA', 'PRUE000000T06', '5500000006', 'prueba6@dazon.demo', 'Calle PRUEBA 6', 0, NULL, 'Concentra compras (venta atípica de 300)', true),
    ('TST-C07', 'CLIENTE PRUEBA 7', 'CLIENTE PRUEBA 7 TALLER', 'PRUE000000T07', '5500000007', 'prueba7@dazon.demo', 'Calle PRUEBA 7', 15, 20000, 'Taller con crédito corto', true),
    ('TST-C08', 'CLIENTE PRUEBA 8', 'CLIENTE PRUEBA 8 FORANEO', 'PRUE000000T08', '5500000008', 'prueba8@dazon.demo', 'Calle PRUEBA 8', 0, NULL, 'Foráneo, paquetería', true);

  -- Catálogo (25) y compatibilidades con variantes mal escritas -------------
  FOR it IN SELECT value FROM jsonb_array_elements(cat) LOOP
    INSERT INTO public.almacen_refacciones_productos (codigo_nuevo, codigo_antiguo, clave_completa, linea_catalogo, marca,
      categoria, descripcion, descripcion_corta, precio, stock, visible_venta, fuente_archivo, unidad_venta,
      piezas_por_unidad_venta, piezas_caja_cerrada, es_prueba)
    VALUES (it->>'c', 'OLD-' || (it->>'c'), it->>'c', it->>'l', 'DAZON PRUEBA', 'PRUEBA', it->>'d', it->>'d',
            (it->>'p')::numeric, 0, true, 'semilla de prueba', it->>'u', (it->>'pu')::integer,
            nullif(it->>'cj', '')::integer, true)
    RETURNING id INTO v_prod;
    INSERT INTO public.almacen_refacciones_codigos (producto_id, codigo, tipo) VALUES (v_prod, it->>'c', 'nuevo'), (v_prod, 'OLD-' || (it->>'c'), 'antiguo');
    INSERT INTO public.almacen_refacciones_unidades (nombre, nombre_normalizado, tipo_unidad, es_prueba)
    VALUES (it->>'m', lower(it->>'m'), 'motoneta', true)
    ON CONFLICT (nombre_normalizado) DO NOTHING;
    SELECT id INTO v_uni FROM public.almacen_refacciones_unidades WHERE nombre_normalizado = lower(it->>'m');
    INSERT INTO public.almacen_refacciones_producto_compat (producto_id, unidad_id, texto_origen) VALUES (v_prod, v_uni, it->>'m');
  END LOOP;

  -- Historial de 12 meses con forma de Pareto -------------------------------
  -- Ventas mensuales base = 150 · k^-1.4 (pocos artículos con casi todo).
  FOR k IN 1..25 LOOP
    IF k = 13 THEN CONTINUE; END IF;  -- TST-013 queda sin existencia ni historia
    v_prod := public._prueba_producto('TST-' || lpad(k::text, 3, '0'));
    v_base := greatest(round(150 * power(k, -1.4))::integer, 1);
    v_final := CASE WHEN k = 14 THEN 2 ELSE round(v_base * 2.5)::integer + 5 END;
    v_ventas := 0;
    FOR m IN 1..12 LOOP
      v_ventas := v_ventas + greatest(round(v_base * (0.7 + (abs(hashtext('v' || k || '-' || m)) % 60) / 100.0))::integer, 0);
    END LOOP;
    IF k = 2 THEN v_ventas := v_ventas + 300; END IF;
    PERFORM public._mover_inventario_refaccion(v_prod, (SELECT linea_catalogo FROM public.almacen_refacciones_productos WHERE id = v_prod),
      v_final + v_ventas + 40, v_hoy - 400, 'entrada', 'inicial', NULL, 'INICIAL-PRUEBA', NULL, 'Existencia inicial de PRUEBA',
      NULL, NULL, true);
    FOR m IN REVERSE 12..1 LOOP
      q := greatest(round(v_base * (0.7 + (abs(hashtext('v' || k || '-' || m)) % 60) / 100.0))::integer, 0);
      CONTINUE WHEN q = 0;
      v_fecha := (date_trunc('month', v_hoy) - make_interval(months => m))::date + (abs(hashtext('d' || k || m)) % 25);
      -- Cada mes se reparte entre tres clientes (ninguno pasa del 40 %),
      -- así la marca de concentración sólo sale con la venta atípica.
      FOR v_cli IN 0..2 LOOP
        v_q := CASE v_cli WHEN 0 THEN ceil(q * 0.36) WHEN 1 THEN ceil(q * 0.33) ELSE q - ceil(q * 0.36) - ceil(q * 0.33) END;
        CONTINUE WHEN v_q <= 0;
        PERFORM public._mover_inventario_refaccion(v_prod, (SELECT linea_catalogo FROM public.almacen_refacciones_productos WHERE id = v_prod),
          -v_q, v_fecha + v_cli, 'venta', 'remision', NULL, 'P-HIST-' || to_char(v_fecha, 'YYMM'), NULL, 'Venta histórica de PRUEBA',
          public._prueba_cliente(1 + (abs(hashtext('c' || k || m)) + v_cli * 2) % 7),
          (SELECT precio FROM public.almacen_refacciones_productos WHERE id = v_prod), true);
        v_hist := v_hist + 1;
      END LOOP;
    END LOOP;
  END LOOP;
  -- Venta atípica: CLIENTE PRUEBA 6 se lleva 300 bolsas de TST-002 de golpe.
  PERFORM public._mover_inventario_refaccion(public._prueba_producto('TST-002'), 'linea_dorada', -300,
    (date_trunc('month', v_hoy) - interval '4 months')::date + 10, 'venta', 'remision', NULL, 'P-HIST-ATIPICA', NULL,
    'Venta atípica de PRUEBA (un cliente se llevó 300)', public._prueba_cliente(6), 250, true);
  -- Deja la existencia baja de TST-014 en 2.
  PERFORM public._mover_inventario_refaccion(public._prueba_producto('TST-014'), 'linea_dorada',
    2 - (SELECT stock FROM public.almacen_refacciones_productos WHERE id = public._prueba_producto('TST-014')),
    v_hoy - 60, 'ajuste', 'ajuste', NULL, 'P-AJ-SEMILLA', 'merma', 'Merma de PRUEBA para dejar existencia baja', NULL, NULL, true);

  -- Compra confirmada con diferencia de recepción (pedidas 500, contadas 490)
  INSERT INTO public.compras_refacciones (folio, fecha, almacen, contenedor_ref, origen, notas, es_prueba, estatus, confirmada_at)
  VALUES (public._siguiente_folio_compras('CR', true), v_hoy - 30, 'linea_dorada', 'Contenedor PRUEBA 23', 'packing_list',
          'Compra de PRUEBA con diferencia de recepción', true, 'no_confirmada', NULL)
  RETURNING id INTO v_compra;
  PERFORM public._escribir_lineas_compra_refacciones(v_compra, jsonb_build_array(
    jsonb_build_object('producto_id', public._prueba_producto('TST-001'), 'cantidad', 500, 'unidad_archivo', 'PZA', 'cantidad_archivo', 500, 'costo_unitario', 40),
    jsonb_build_object('producto_id', public._prueba_producto('TST-007'), 'cantidad', 200, 'unidad_archivo', 'PZA', 'cantidad_archivo', 200),
    jsonb_build_object('producto_id', public._prueba_producto('TST-002'), 'cantidad', 30, 'unidad_archivo', '10 PZAS/BOLSA', 'cantidad_archivo', 30, 'piezas_por_unidad_archivo', 10)));
  PERFORM public._mover_inventario_refaccion(l.producto_id, 'linea_dorada', l.cantidad, v_hoy - 30, 'entrada', 'compra', v_compra,
      c.folio, NULL, 'Compra ' || c.folio || ' · contenedor Contenedor PRUEBA 23', NULL, l.costo_unitario, true)
    FROM public.compra_refaccion_lineas l JOIN public.compras_refacciones c ON c.id = l.compra_id WHERE l.compra_id = v_compra;
  UPDATE public.compras_refacciones SET estatus = 'confirmada', confirmada_at = now() WHERE id = v_compra;

  INSERT INTO public.recepciones_refacciones (folio, compra_id, fecha, visto_bueno, notas, es_prueba)
  VALUES (public._siguiente_folio_compras('RC', true), v_compra, v_hoy - 28, true, 'Recepción de PRUEBA: faltaron 10 balatas', true)
  RETURNING id INTO v_rec;
  INSERT INTO public.recepcion_refaccion_lineas (recepcion_id, producto_id, esperado, cajas_cerradas, piezas_sueltas, contado, incidencia)
  VALUES (v_rec, public._prueba_producto('TST-001'), 500, 2, 90, 490, 'Caja abierta, faltan 10 piezas'),
         (v_rec, public._prueba_producto('TST-007'), 200, 2, 0, 200, NULL),
         (v_rec, public._prueba_producto('TST-002'), 30, 0, 30, 30, NULL);
  v_aj := public._crear_ajuste_inventario('linea_dorada', v_hoy - 28, 'incidencia_recepcion',
    'Recepción de la compra de PRUEBA (Contenedor PRUEBA 23)', 'recepcion', 'propuesta',
    jsonb_build_array(jsonb_build_object('producto_id', public._prueba_producto('TST-001'), 'delta', -10)), NULL, NULL, v_rec);
  UPDATE public.recepciones_refacciones SET ajuste_id = v_aj WHERE id = v_rec;
  PERFORM public._aplicar_ajuste_inventario(v_aj);

  -- Compra NO confirmada (para probar «Confirmar»)
  INSERT INTO public.compras_refacciones (folio, fecha, almacen, contenedor_ref, origen, notas, es_prueba)
  VALUES (public._siguiente_folio_compras('CR', true), v_hoy - 2, 'linea_dorada', 'Contenedor PRUEBA 24-B', 'manual',
          'Compra de PRUEBA sin confirmar (en tránsito)', true)
  RETURNING id INTO v_compra2;
  PERFORM public._escribir_lineas_compra_refacciones(v_compra2, jsonb_build_array(
    jsonb_build_object('producto_id', public._prueba_producto('TST-005'), 'cantidad', 60),
    jsonb_build_object('producto_id', public._prueba_producto('TST-013'), 'cantidad', 25),
    jsonb_build_object('producto_id', public._prueba_producto('TST-014'), 'cantidad', 15)));

  -- Remisiones en todos los estados ----------------------------------------
  r1 := public._prueba_remision(1, 1, '[{"codigo":"TST-001","cantidad":10},{"codigo":"TST-011","cantidad":4}]', 'Levantada: espera a Almacén');
  r2 := public._prueba_remision(5, 1, '[{"codigo":"TST-007","cantidad":8},{"codigo":"TST-010","cantidad":3}]', 'En Almacén, surtida a medias');
  PERFORM public._prueba_surtir(r2, 'TST-007');
  r3 := public._prueba_remision(8, 2, '[{"codigo":"TST-014","cantidad":2},{"codigo":"TST-023","cantidad":10}]', 'Con faltante y contingencia');
  UPDATE public.remision_refaccion_items SET cantidad_faltante = 2, estatus = 'faltante', nota_almacen = 'PRUEBA: no se encontró en anaquel'
   WHERE remision_id = r3 AND codigo_nuevo = 'TST-014';
  PERFORM public.recalcular_etapa_remision_refaccion(r3);
  r4 := public._prueba_remision(7, 1, '[{"codigo":"TST-004","cantidad":2},{"codigo":"TST-019","cantidad":2},{"codigo":"TST-020","cantidad":5}]', 'Mixta dorada y azul: dos órdenes');
  r5 := public._prueba_remision(2, 10, '[{"codigo":"TST-015","cantidad":10},{"codigo":"TST-017","cantidad":10}]', 'Pagada parcial');
  PERFORM public._prueba_surtir(r5);
  r6 := public._prueba_remision(3, 5, '[{"codigo":"TST-006","cantidad":2}]', 'Pagada con saldo a favor');
  PERFORM public._prueba_surtir(r6);
  r7 := public._prueba_remision(1, 6, '[{"codigo":"TST-016","cantidad":2},{"codigo":"TST-003","cantidad":3}]', 'Con corrección de descuento');
  PERFORM public._prueba_surtir(r7);
  r8 := public._prueba_remision(6, 15, '[{"codigo":"TST-002","cantidad":10},{"codigo":"TST-008","cantidad":5}]', 'Entregada y pagada');
  PERFORM public._prueba_surtir(r8);
  r9 := public._prueba_remision(1, 3, '[{"codigo":"TST-024","cantidad":4}]', 'Cancelada');
  UPDATE public.remision_refaccion_items SET cantidad_bloqueada = 0, estatus = 'cancelada' WHERE remision_id = r9;
  UPDATE public.remisiones_refacciones SET etapa = 'cancelada', area_actual = 'ventas', abierta = false,
         motivo_cancelacion = 'PRUEBA: el cliente desistió', cancelada_at = now() WHERE id = r9;
  r10 := public._prueba_remision(2, 8, '[{"codigo":"TST-018","cantidad":2},{"codigo":"TST-009","cantidad":3}]', 'Pagada con un depósito a varias remisiones');
  PERFORM public._prueba_surtir(r10);

  -- Corrección de descuento (queda en el historial con monto anterior y nuevo)
  PERFORM set_config('kit.motivo_correccion', 'PRUEBA: descuento autorizado por Dirección', true);
  UPDATE public.remisiones_refacciones SET descuento_pct = 10 WHERE id = r7;
  PERFORM set_config('kit.motivo_correccion', '', true);

  -- Pagos -------------------------------------------------------------------
  -- 1) Un depósito a varias remisiones (r8 y r10, con remanente a r5 parcial).
  pg1 := public._prueba_pago(6, 14, public.total_vigente_remision_refaccion(r8), 'transferencia', 'SPEI PRUEBA 0001');
  PERFORM public._prueba_aplicar(pg1, r8, public.total_vigente_remision_refaccion(r8));
  UPDATE public.remisiones_refacciones SET entregada_at = now(), etapa = 'entregada', area_actual = 'logistica' WHERE id = r8;
  pg2 := public._prueba_pago(2, 7, public.total_vigente_remision_refaccion(r10) + 10000, 'deposito', 'DEP PRUEBA 0002');
  PERFORM public._prueba_aplicar(pg2, r10, public.total_vigente_remision_refaccion(r10));
  PERFORM public._prueba_aplicar(pg2, r5, 10000);   -- 2) parcial: «a cuenta»
  -- 3) Pago en exceso → saldo a favor
  pg3 := public._prueba_pago(1, 5, public.total_vigente_remision_refaccion(r7) + 1500, 'transferencia', 'SPEI PRUEBA 0003');
  PERFORM public._prueba_aplicar(pg3, r7, public.total_vigente_remision_refaccion(r7));
  INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, pago_origen_id, notas, es_prueba)
  VALUES (public._siguiente_folio_compras('SF', true), public._prueba_cliente(1), 'pago_en_exceso', 1500, pg3, 'Remanente del pago de PRUEBA', true);
  -- 4) Revertido con motivo
  pg4 := public._prueba_pago(5, 3, 500, 'efectivo', 'VALE PRUEBA 0004');
  UPDATE public.cobranza_pagos SET estatus = 'revertido', revertido_at = now(),
         motivo_reversion = 'PRUEBA: se capturó al cliente equivocado' WHERE id = pg4;
  -- Cliente 3: saldo a favor vivo, una parte usada en r6.
  INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, notas, es_prueba)
  VALUES (public._siguiente_folio_compras('SF', true), public._prueba_cliente(3), 'otro', 3000, 'Bonificación de PRUEBA', true)
  RETURNING id INTO v_sf;
  INSERT INTO public.cobranza_aplicaciones (tipo, saldo_favor_id, remision_id, monto, notas, es_prueba)
  VALUES ('saldo_favor', v_sf, r6, public.total_vigente_remision_refaccion(r6), 'Pagado con saldo a favor (PRUEBA)', true);
  PERFORM public.cobranza_sincronizar_remision(r6);
  -- Cliente 4: pago anticipado sin compras.
  pg5 := public._prueba_pago(4, 20, 70000, 'transferencia', 'SPEI PRUEBA 0005');
  INSERT INTO public.cobranza_saldos_favor (folio, cliente_id, origen, monto, pago_origen_id, notas, es_prueba)
  VALUES (public._siguiente_folio_compras('SF', true), public._prueba_cliente(4), 'pago_anticipado', 70000, pg5, 'Anticipo de PRUEBA', true);

  -- Conteos físicos ---------------------------------------------------------
  -- Propuesta pendiente (Almacén contó 3 cables de clutch menos).
  PERFORM public._crear_ajuste_inventario('linea_dorada', v_hoy - 1, 'auditoria', NULL, 'conteo_fisico', 'propuesta',
    jsonb_build_array(jsonb_build_object('producto_id', public._prueba_producto('TST-011'),
      'cantidad_contada', greatest(public.saldo_refaccion_a_fecha(public._prueba_producto('TST-011'), v_hoy - 1) - 3, 0))),
    NULL, 'Conteo de PRUEBA pendiente de aprobar');
  -- Aprobado con fecha retroactiva (hace 20 días).
  v_aj := public._crear_ajuste_inventario('linea_dorada', v_hoy - 20, 'mal_conteo', NULL, 'conteo_fisico', 'propuesta',
    jsonb_build_array(jsonb_build_object('producto_id', public._prueba_producto('TST-010'),
      'cantidad_contada', public.saldo_refaccion_a_fecha(public._prueba_producto('TST-010'), v_hoy - 20) + 4)),
    NULL, 'Conteo de PRUEBA aprobado con fecha retroactiva');
  UPDATE public.ajustes_inventario SET comentario_revision = 'PRUEBA: aprobado por Compras' WHERE id = v_aj;
  PERFORM public._aplicar_ajuste_inventario(v_aj);
  -- Ajuste rápido por merma (motivo de la lista real), hace 10 días: una
  -- pieza dañada de TST-013.
  IF (SELECT saldo_minimo FROM public.saldo_minimo_desde(public._prueba_producto('TST-013'), v_hoy - 10)) >= 1 THEN
    v_aj := public._crear_ajuste_inventario('linea_dorada', v_hoy - 10, 'merma', NULL, 'ajuste_rapido', 'propuesta',
      jsonb_build_array(jsonb_build_object('producto_id', public._prueba_producto('TST-013'),
        'cantidad_contada', public.saldo_refaccion_a_fecha(public._prueba_producto('TST-013'), v_hoy - 10) - 1)),
      NULL, 'Merma de PRUEBA: una pieza dañada');
    PERFORM public._aplicar_ajuste_inventario(v_aj);
  END IF;

  PERFORM public.registrar_bitacora_compras('prueba', 'sembrar', NULL, NULL, NULL,
    jsonb_build_object('movimientos_historicos', v_hist), true);
  RETURN jsonb_build_object('sembrado', true, 'articulos', 25, 'clientes', 8, 'movimientos_historicos', v_hist,
                            'remisiones', 10, 'compras', 2);
END;
$$;
REVOKE ALL ON FUNCTION public.sembrar_datos_prueba_compras() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sembrar_datos_prueba_compras() TO authenticated;

-- ── Reinicio ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reiniciar_datos_prueba_compras(_confirmacion text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_borrados jsonb := '{}'::jsonb;
  v_n integer;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT (public.es_admin_global(auth.uid()) OR public.has_role(auth.uid(), 'admin'::public.app_role)) THEN
    RAISE EXCEPTION 'Sólo un administrador reinicia los datos de prueba';
  END IF;
  IF _confirmacion IS DISTINCT FROM 'REINICIAR DATOS DE PRUEBA' THEN
    RAISE EXCEPTION 'Escribe exactamente: REINICIAR DATOS DE PRUEBA';
  END IF;
  PERFORM set_config('kit.reiniciando_prueba', 'si', true);

  DELETE FROM public.cobranza_aplicaciones WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('aplicaciones', v_n);
  DELETE FROM public.cobranza_solicitudes_saldo WHERE es_prueba;
  DELETE FROM public.cobranza_saldos_favor WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('saldos_favor', v_n);
  DELETE FROM public.cobranza_pagos WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('pagos', v_n);
  DELETE FROM public.remision_refaccion_correcciones WHERE es_prueba
     OR remision_id IN (SELECT id FROM public.remisiones_refacciones WHERE es_prueba);
  DELETE FROM public.remisiones_refacciones WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('remisiones', v_n);
  UPDATE public.recepciones_refacciones SET ajuste_id = NULL WHERE es_prueba;
  DELETE FROM public.ajuste_inventario_lineas WHERE ajuste_id IN (SELECT id FROM public.ajustes_inventario WHERE es_prueba);
  DELETE FROM public.ajustes_inventario WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('ajustes', v_n);
  DELETE FROM public.recepciones_refacciones WHERE es_prueba;
  DELETE FROM public.compras_refacciones WHERE es_prueba AND compra_origen_id IS NOT NULL;
  DELETE FROM public.compras_refacciones WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('compras', v_n);
  DELETE FROM public.almacen_refacciones_movimientos WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('movimientos', v_n);
  DELETE FROM public.almacen_refacciones_productos WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('articulos', v_n);
  UPDATE public.almacen_refacciones_unidades SET fusionada_en = NULL WHERE es_prueba;
  DELETE FROM public.almacen_refacciones_unidades u WHERE u.es_prueba
     AND NOT EXISTS (SELECT 1 FROM public.almacen_refacciones_producto_compat pc WHERE pc.unidad_id = u.id);
  DELETE FROM public.avisos WHERE datos->>'ruta' = '/cobranza' AND (datos ? 'pago_id')
     AND (datos->>'pago_id')::uuid NOT IN (SELECT id FROM public.cobranza_pagos);
  DELETE FROM public.clientes WHERE es_prueba; GET DIAGNOSTICS v_n = ROW_COUNT; v_borrados := v_borrados || jsonb_build_object('clientes', v_n);
  DELETE FROM public.inventario_almacenes WHERE es_prueba;
  -- Lo que existe a partir de 20261007000001 (motivos, unidades y avisos
  -- dados de alta en prueba).
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
              AND table_name = 'inventario_motivos_ajuste' AND column_name = 'es_prueba') THEN
    EXECUTE 'DELETE FROM public.inventario_motivos_ajuste m WHERE m.es_prueba
               AND NOT EXISTS (SELECT 1 FROM public.ajustes_inventario a WHERE a.motivo_clave = m.clave)
               AND NOT EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos x WHERE x.motivo_clave = m.clave)';
    EXECUTE 'DELETE FROM public.inventario_unidades_venta u WHERE u.es_prueba
               AND NOT EXISTS (SELECT 1 FROM public.almacen_refacciones_productos p WHERE p.unidad_venta = u.clave)';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
              AND table_name = 'avisos' AND column_name = 'es_prueba') THEN
    EXECUTE 'DELETE FROM public.avisos WHERE es_prueba';
  END IF;
  DELETE FROM public.bitacora_compras_inventario WHERE es_prueba AND modulo <> 'prueba';
  DELETE FROM public.compras_folios WHERE es_prueba;

  PERFORM public.registrar_bitacora_compras('prueba', 'reiniciar', NULL, NULL, NULL, v_borrados, true);
  RETURN jsonb_build_object('borrado', v_borrados, 'siembra', public.sembrar_datos_prueba_compras());
END;
$$;
REVOKE ALL ON FUNCTION public.reiniciar_datos_prueba_compras(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reiniciar_datos_prueba_compras(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
