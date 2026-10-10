-- ============================================================================
-- Pruebas automáticas (base de datos) de Compras, Inventario y Cobranza.
-- Se corren contra un Postgres LOCAL con todas las migraciones aplicadas:
--
--   PGHOST=/var/lib/postgresql PGPORT=5433 scripts/db-local/probar_compras.sh
--
-- Cada prueba entra como un usuario (request.jwt.claim.sub + rol
-- authenticated, igual que PostgREST), corre en su propia transacción y se
-- revierte al final: no dependen unas de otras. Si una afirmación falla,
-- psql se detiene con el error y la corrida sale con código distinto de 0.
-- ============================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = notice;

-- ── Usuarios de prueba con su área y nivel ─────────────────────────────────
INSERT INTO auth.users (id, email, raw_app_meta_data)
SELECT id::uuid, email, '{"created_via_admin": "true"}'::jsonb FROM (VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'prueba.compras@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a2', 'prueba.almacen@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a3', 'prueba.finanzas@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a4', 'prueba.ventas@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a5', 'prueba.super@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000a6', 'prueba.logistica@dazon.demo'),
  ('00000000-0000-0000-0000-0000000000b1', 'martin.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b2', 'vendedor.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b3', 'almacen.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b4', 'admin.real@ejemplo.mx'),
  ('00000000-0000-0000-0000-0000000000b5', 'finanzas.real@ejemplo.mx')
) AS u(id, email)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.profiles (id, nombre_completo, activo, email)
SELECT id, split_part(email, '@', 1), true, email FROM auth.users
 WHERE id::text LIKE '00000000-0000-0000-0000-0000000000%'
ON CONFLICT (id) DO NOTHING;
DELETE FROM public.user_roles WHERE user_id::text LIKE '00000000-0000-0000-0000-0000000000%';
INSERT INTO public.user_roles (user_id, role, area, nivel) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'compras',   'compras',           'operador'),
  ('00000000-0000-0000-0000-0000000000a2', 'logistica', 'almacen_logistica', 'operador'),
  ('00000000-0000-0000-0000-0000000000a3', 'finanzas',  'administracion',    'operador'),
  ('00000000-0000-0000-0000-0000000000a4', 'ventas',    'comercial',         'operador'),
  ('00000000-0000-0000-0000-0000000000a5', 'admin',     'direccion',         'admin'),
  ('00000000-0000-0000-0000-0000000000a6', 'logistica', 'almacen_logistica', 'operador'),
  ('00000000-0000-0000-0000-0000000000b1', 'compras',   'compras',           'operador'),
  ('00000000-0000-0000-0000-0000000000b2', 'ventas',    'comercial',         'operador'),
  ('00000000-0000-0000-0000-0000000000b3', 'logistica', 'almacen_logistica', 'operador'),
  ('00000000-0000-0000-0000-0000000000b4', 'admin',     'direccion',         'admin'),
  ('00000000-0000-0000-0000-0000000000b5', 'finanzas',  'administracion',    'operador');
INSERT INTO public.almacen_refacciones_acceso (email, user_id, activo)
VALUES ('almacen.real@ejemplo.mx', '00000000-0000-0000-0000-0000000000b3', true)
ON CONFLICT (email) DO UPDATE SET user_id = EXCLUDED.user_id, activo = true;

-- Un artículo y un cliente REALES para probar los candados cruzados.
INSERT INTO public.clientes (codigo_erp, nombre_comercial) VALUES ('REAL-001', 'Cliente real de ejemplo')
ON CONFLICT (codigo_erp) DO NOTHING;
INSERT INTO public.almacen_refacciones_productos (codigo_nuevo, clave_completa, linea_catalogo, descripcion, precio, stock)
VALUES ('REAL-ART-1', 'REAL-ART-1', 'linea_dorada', 'Artículo real de ejemplo', 100, 0)
ON CONFLICT (codigo_nuevo) DO NOTHING;

SELECT public.reiniciar_datos_prueba_compras('REINICIAR DATOS DE PRUEBA') IS NOT NULL AS sembrado;

-- Ayudantes ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._t_como(_email text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users WHERE email = _email), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE OR REPLACE FUNCTION public._t_falla(_sql text, _patron text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~* _patron THEN
      RAISE EXCEPTION 'Falló con otro mensaje. Esperado /%/, llegó: %', _patron, SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'Debió fallar (esperado /%/): %', _patron, _sql;
END $$;
-- SECURITY DEFINER: devuelven el id aunque quien prueba no lo vea (así se
-- comprueba que conocer el id de un dato real tampoco basta).
CREATE OR REPLACE FUNCTION public._t_prod(_codigo text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.almacen_refacciones_productos WHERE codigo_nuevo = _codigo
$$;
CREATE OR REPLACE FUNCTION public._t_cli(_codigo text) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS $$
  SELECT id FROM public.clientes WHERE codigo_erp = _codigo
$$;
-- «Hoy» como lo ve la operación (México), no la fecha UTC del servidor.
CREATE OR REPLACE FUNCTION public._t_hoy() RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'America/Mexico_City')::date
$$;
GRANT EXECUTE ON FUNCTION public._t_como(text), public._t_falla(text, text), public._t_prod(text), public._t_cli(text), public._t_hoy() TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
\echo '1. Candado en ceros (hoy y en fechas posteriores a un ajuste retroactivo)'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE v_stock integer;
BEGIN
  -- Bajar a menos de cero con un ajuste por diferencia: no existe ese camino
  -- (se captura lo contado, nunca negativo).
  PERFORM public._t_falla($q$SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'mal_conteo', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-011'), 'cantidad_contada', -5)))$q$,
    'cantidad real contada|check');
  -- Retroactivo que deja negativo un día posterior: contó 0 hace 200 días y
  -- después hubo ventas.
  -- Contó X hace 200 días: hoy alcanzaría (llegó una compra después), pero
  -- un día intermedio quedaría en -1. El candado lo detecta y dice qué día.
  PERFORM public._t_falla(format($q$SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy() - 200, 'mal_conteo', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cantidad_contada', %s)))$q$,
    public.saldo_refaccion_a_fecha(public._t_prod('TST-001'), public._t_hoy() - 200)
      - (SELECT saldo_minimo FROM public.saldo_minimo_desde(public._t_prod('TST-001'), public._t_hoy() - 200)) - 1),
    'Candado en ceros: con fecha .* quedaría en -1 el día');
  ASSERT (SELECT saldo_minimo FROM public.saldo_minimo_desde(public._t_prod('TST-001'), public._t_hoy() - 200))
       < (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-001'), 'el caso sí es intermedio';
  SELECT stock INTO v_stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-001';
  ASSERT v_stock > 0, 'la existencia no debió moverse';
END $$;
-- Ningún camino viejo lo brinca tampoco: el CHECK de la tabla sigue ahí.
RESET ROLE;
DO $$ BEGIN
  PERFORM public._t_falla($q$UPDATE public.almacen_refacciones_productos SET stock = -1 WHERE codigo_nuevo = 'TST-021'$q$, 'negativo|check');
END $$;
ROLLBACK;

\echo '2. Candado de pertenencia'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  -- Ajuste en Línea azul de un artículo de Línea dorada.
  PERFORM public._t_falla($q$SELECT public.aplicar_ajuste_rapido('linea_azul', public._t_hoy(), 'mal_conteo', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cantidad_contada', 3)))$q$,
    'pertenencia');
  -- Compra a Línea azul: nunca recibe compras.
  PERFORM public._t_falla($q$SELECT public.crear_compra_refacciones('{"almacen":"linea_azul"}'::jsonb,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-019'), 'cantidad', 5)))$q$,
    'no recibe compras');
  -- Compra a Dorada con un artículo de Azul.
  PERFORM public._t_falla($q$SELECT public.crear_compra_refacciones('{"almacen":"linea_dorada"}'::jsonb,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-019'), 'cantidad', 5)))$q$,
    'pertenencia');
END $$;
RESET ROLE;
DO $$ BEGIN
  -- Un artículo con existencia no se cambia de línea (ni por importación).
  PERFORM public._t_falla($q$UPDATE public.almacen_refacciones_productos SET linea_catalogo = 'linea_azul' WHERE codigo_nuevo = 'TST-001'$q$,
    'un solo almacén');
END $$;
ROLLBACK;

\echo '3. Ajuste retroactivo: fija el saldo a esa fecha y recalcula lo posterior'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE
  v_p uuid := public._t_prod('TST-003');
  v_fecha date := (now() AT TIME ZONE 'America/Mexico_City')::date - 21;
  v_antes_fecha integer := public.saldo_refaccion_a_fecha(v_p, v_fecha);
  v_stock_antes integer := (SELECT stock FROM public.almacen_refacciones_productos WHERE id = v_p);
  v_res jsonb;
  v_k record;
BEGIN
  v_res := public.aplicar_ajuste_rapido('linea_dorada', v_fecha, 'mal_conteo', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad_contada', v_antes_fecha + 7)), NULL, 'Óscar contó hace 3 semanas');
  ASSERT public.saldo_refaccion_a_fecha(v_p, v_fecha) = v_antes_fecha + 7, 'el saldo a esa fecha debe ser lo contado';
  ASSERT (SELECT stock FROM public.almacen_refacciones_productos WHERE id = v_p) = v_stock_antes + 7, 'el saldo de hoy cambia por la diferencia';
  -- En el kárdex el ajuste aparece en su fecha efectiva, con su folio.
  SELECT * INTO v_k FROM public.kardex_refaccion(v_p, v_fecha, v_fecha) WHERE folio = v_res->>'folio';
  ASSERT v_k.fecha = v_fecha AND v_k.entrada = 7, 'el kárdex muestra el ajuste en su fecha';
  -- Bitácora con fecha efectiva y fecha de registro separadas.
  ASSERT EXISTS (SELECT 1 FROM public.ajustes_inventario a WHERE a.folio = v_res->>'folio'
                  AND a.fecha_efectiva = v_fecha AND a.created_at::date >= v_fecha + 1), 'fecha efectiva ≠ registro';
END $$;
ROLLBACK;

\echo '4. Remisión mixta dorada + azul: una remisión, dos órdenes de inventario'
BEGIN;
SELECT public._t_como('prueba.ventas@dazon.demo');
DO $$
DECLARE v jsonb; v_ordenes integer; v_rem uuid;
BEGIN
  v := public.crear_remision_refacciones(public._t_cli('TST-C05'), 'Mixta', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cantidad', 2),
                      jsonb_build_object('producto_id', public._t_prod('TST-020'), 'cantidad', 3)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado","forma_pago":"efectivo"}'::jsonb);
  v_rem := (v->>'id')::uuid;
  SELECT count(*) INTO v_ordenes FROM public.remision_refaccion_ordenes WHERE remision_id = v_rem;
  ASSERT v_ordenes = 2, format('se esperaban 2 órdenes y hay %s', v_ordenes);
  ASSERT (SELECT count(DISTINCT orden_id) FROM public.remision_refaccion_items WHERE remision_id = v_rem) = 2;
  ASSERT (SELECT folio FROM public.remisiones_refacciones WHERE id = v_rem) LIKE 'P-RF-%', 'la remisión de prueba usa la serie P-RF';
  -- Ventas no puede vender a un cliente real estando en modo prueba.
  PERFORM public._t_falla($q$SELECT public.crear_remision_refacciones(public._t_cli('REAL-001'), 'x', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cantidad', 1)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb)$q$, 'MODO PRUEBA');
END $$;
ROLLBACK;

\echo '4b. Candado cruzado: un cliente real no compra un artículo de prueba'
BEGIN;
SELECT public._t_como('vendedor.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.crear_remision_refacciones(public._t_cli('REAL-001'), 'x', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cantidad', 1)),
    '{"tipo_envio":"recoge","tipo_pago":"anticipado"}'::jsonb)$q$, 'No se mezclan datos de prueba');
END $$;
ROLLBACK;

\echo '5-8. Pago a varias remisiones, parcial, en exceso (saldo a favor) y reversión'
BEGIN;
SELECT public._t_como('prueba.finanzas@dazon.demo');
CREATE TEMP TABLE t_pago AS
SELECT (public.registrar_pago_cobranza(jsonb_build_object('cliente_id', public._t_cli('TST-C02'), 'monto', 31650,
         'forma', 'deposito', 'referencia', 'DEP 31650', 'evidencia_path', 'prueba/dep.pdf', 'validar', true, 'conciliado', true))->>'id')::uuid AS id;
GRANT SELECT ON t_pago TO authenticated;
DO $$ BEGIN
  -- Finanzas no aplica pagos.
  PERFORM public._t_falla(format('SELECT public.aplicar_pago_cobranza(%L, %L)', (SELECT id FROM t_pago), '[]'), 'Sólo Compras');
  -- Sin evidencia no se registra.
  PERFORM public._t_falla($q$SELECT public.registrar_pago_cobranza(jsonb_build_object('cliente_id', public._t_cli('TST-C02'), 'monto', 10))$q$, 'evidencia');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE
  v_pago uuid := (SELECT id FROM t_pago);
  r5 uuid := (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Pagada parcial');
  r10 uuid := (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Pagada con un depósito a varias remisiones');
  v_pend5 numeric := (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r5));
  v jsonb;
  v_sf_antes integer := (SELECT count(*) FROM public.cobranza_saldos_favor WHERE cliente_id = public._t_cli('TST-C02'));
BEGIN
  -- r10 ya está pagada: se rechaza aplicar más de lo que debe.
  PERFORM public._t_falla(format('SELECT public.aplicar_pago_cobranza(%L, %L)', v_pago,
    jsonb_build_array(jsonb_build_object('remision_id', r10, 'monto', 1))), 'le quedan');
  -- Parcial: 5,000 «a cuenta» de r5 → queda saldo pendiente visible.
  v := public.aplicar_pago_cobranza(v_pago, jsonb_build_array(jsonb_build_object('remision_id', r5, 'monto', 5000)), false);
  ASSERT (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r5)) = v_pend5 - 5000, 'parcial';
  -- El resto liquida r5 y el excedente se vuelve saldo a favor (pago en exceso).
  v := public.aplicar_pago_cobranza(v_pago, jsonb_build_array(jsonb_build_object('remision_id', r5, 'monto', v_pend5 - 5000)), true);
  ASSERT (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r5)) = 0, 'liquidada';
  ASSERT (SELECT pagado FROM public.remisiones_refacciones WHERE id = r5), 'marca de pagado';
  ASSERT (SELECT count(*) FROM public.cobranza_saldos_favor WHERE cliente_id = public._t_cli('TST-C02')) = v_sf_antes + 1, 'saldo a favor creado';
  ASSERT (SELECT origen FROM public.cobranza_saldos_favor WHERE pago_origen_id = v_pago) = 'pago_en_exceso';
  ASSERT public.disponible_pago_cobranza(v_pago) = 0;
  -- Varios pagos a una remisión y un pago a varias: trazabilidad en los dos sentidos.
  ASSERT (SELECT count(DISTINCT pago_id) FROM public.cobranza_aplicaciones WHERE remision_id = r5 AND revertida_at IS NULL) = 2;
  -- Revertir: con motivo; las aplicaciones quedan marcadas, nada se borra.
  PERFORM public._t_falla(format('SELECT public.revertir_pago_cobranza(%L, %L)', v_pago, ''), 'motivo');
  PERFORM public.revertir_pago_cobranza(v_pago, 'Se aplicó al cliente equivocado');
  ASSERT (SELECT estatus FROM public.cobranza_pagos WHERE id = v_pago) = 'revertido';
  ASSERT (SELECT count(*) FROM public.cobranza_aplicaciones WHERE pago_id = v_pago AND revertida_at IS NOT NULL) = 2;
  ASSERT (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r5)) = v_pend5, 'vuelve a deber lo de antes';
  ASSERT (SELECT cancelado_at IS NOT NULL FROM public.cobranza_saldos_favor WHERE pago_origen_id = v_pago);
  -- Nadie edita ni borra un pago aplicado (RLS: no hay política de escritura).
  UPDATE public.cobranza_pagos SET monto = 1 WHERE id = v_pago;
  ASSERT (SELECT monto FROM public.cobranza_pagos WHERE id = v_pago) = 31650, 'el UPDATE directo no debe tocar nada';
  DELETE FROM public.cobranza_pagos WHERE id = v_pago;
  ASSERT EXISTS (SELECT 1 FROM public.cobranza_pagos WHERE id = v_pago), 'el DELETE directo no debe borrar';
END $$;
RESET ROLE;
DO $$ BEGIN
  -- Ni siquiera el dueño de la base (trigger de inmutabilidad).
  PERFORM public._t_falla(format('UPDATE public.cobranza_pagos SET monto = 1 WHERE id = %L', (SELECT id FROM t_pago)), 'no se edita|revertido');
  PERFORM public._t_falla(format('DELETE FROM public.cobranza_pagos WHERE id = %L', (SELECT id FROM t_pago)), 'nada se borra');
  PERFORM public._t_falla('DELETE FROM public.cobranza_aplicaciones', 'nada se borra');
END $$;
ROLLBACK;

\echo '8b. Saldo a favor: se aplica a otra remisión y no cuenta como dinero nuevo'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE
  v_sf uuid := (SELECT id FROM public.cobranza_saldos_favor WHERE cliente_id = public._t_cli('TST-C01') AND origen = 'pago_en_exceso');
  r uuid := (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Levantada: espera a Almacén');
BEGIN
  -- Es cotización: Almacén no ha confirmado, no se le aplica nada.
  PERFORM public._t_falla(format('SELECT public.aplicar_saldo_favor(%L, %L, 100)', v_sf, r), 'cotización');
END $$;
RESET ROLE;
-- Almacén surte (confirma existencias y monto).
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.liberar_refaccion_remision(i.id, i.cantidad_bloqueada)
  FROM public.remision_refaccion_items i JOIN public.remisiones_refacciones r ON r.id = i.remision_id
 WHERE r.notas = 'Levantada: espera a Almacén' AND r.es_prueba;
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE
  v_sf uuid := (SELECT id FROM public.cobranza_saldos_favor WHERE cliente_id = public._t_cli('TST-C01') AND origen = 'pago_en_exceso');
  r uuid := (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Levantada: espera a Almacén');
  e record;
BEGIN
  PERFORM public.aplicar_saldo_favor(v_sf, r, 1000);
  SELECT * INTO e FROM public.estado_cobro_remision_refaccion(r);
  ASSERT e.cobrado_saldo_favor = 1000 AND e.cobrado_dinero = 0, 'pagado con saldo a favor, no dinero';
  ASSERT public.disponible_saldo_favor(v_sf) = 500;
END $$;
ROLLBACK;

\echo '9. Corregir remisión: recalcula monto, inventario y saldo a favor'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE
  r uuid := (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Entregada y pagada');
  i public.remision_refaccion_items%ROWTYPE;
  v_stock integer;
  v jsonb;
BEGIN
  SELECT * INTO i FROM public.remision_refaccion_items WHERE remision_id = r AND codigo_nuevo = 'TST-002';
  v_stock := (SELECT stock FROM public.almacen_refacciones_productos WHERE id = i.producto_id);
  -- Regresan 4 de 10 (devolución): baja el monto, sube la existencia y lo
  -- ya pagado de más queda como saldo a favor del cliente.
  v := public.corregir_remision_refaccion(r, jsonb_build_object('partidas', jsonb_build_array(
         jsonb_build_object('item_id', i.id, 'cantidad', 6))), 'El cliente devolvió 4 bolsas');
  ASSERT (v->>'monto_nuevo')::numeric = (v->>'monto_anterior')::numeric - 4 * 250, 'monto vigente';
  ASSERT public.total_vigente_remision_refaccion(r) = (v->>'monto_nuevo')::numeric, 'una sola fuente de verdad';
  ASSERT (SELECT stock FROM public.almacen_refacciones_productos WHERE id = i.producto_id) = v_stock + 4, 'inventario';
  ASSERT EXISTS (SELECT 1 FROM public.cobranza_saldos_favor WHERE remision_origen_id = r AND origen = 'remision_corregida' AND monto = 1000), 'saldo a favor';
  ASSERT (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r)) = 0;
  ASSERT EXISTS (SELECT 1 FROM public.remision_refaccion_correcciones
                  WHERE remision_id = r AND campo = 'piezas_cobrables' AND valor_anterior = '10' AND valor_nuevo = '6'
                    AND motivo LIKE '%devolvió%' AND usuario_id IS NOT NULL), 'historial de la corrección';
  ASSERT EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos WHERE documento_tipo = 'devolucion' AND documento_id = r), 'kárdex';
END $$;
RESET ROLE;
-- Finanzas sólo corrige descuentos; Ventas no corrige.
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$
DECLARE r uuid := (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Pagada parcial');
BEGIN
  PERFORM public.corregir_remision_refaccion(r, '{"descuento_pct": 5}'::jsonb, 'Descuento autorizado');
  ASSERT (SELECT descuento_pct FROM public.remisiones_refacciones WHERE id = r) = 5;
  PERFORM public._t_falla(format('SELECT public.corregir_remision_refaccion(%L, %L, %L)', r,
    jsonb_build_object('partidas', jsonb_build_array(jsonb_build_object('item_id',
      (SELECT id FROM public.remision_refaccion_items WHERE remision_id = r LIMIT 1), 'cantidad', 1))), 'x x x'), 'Compras');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.ventas@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.corregir_remision_refaccion(%L, %L, %L)',
    (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Pagada parcial'), '{"descuento_pct": 50}', 'yo quiero'), 'Sólo Compras');
END $$;
ROLLBACK;

\echo '9b. Revertir el pago de una remisión corregida cancela el saldo a favor que ya no existe'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE
  r uuid := (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Entregada y pagada');
  pago uuid := (SELECT pago_id FROM public.cobranza_aplicaciones WHERE remision_id = r AND tipo = 'pago' LIMIT 1);
  total0 numeric := public.total_vigente_remision_refaccion(r);
BEGIN
  PERFORM public.corregir_remision_refaccion(r, '{"descuento_pct": 10}'::jsonb, 'Descuento autorizado');
  ASSERT (SELECT count(*) FROM public.cobranza_saldos_favor WHERE remision_origen_id = r AND cancelado_at IS NULL) = 1, 'excedente → saldo a favor';
  PERFORM public.revertir_pago_cobranza(pago, 'Se capturó dos veces');
  ASSERT (SELECT count(*) FROM public.cobranza_saldos_favor WHERE remision_origen_id = r AND cancelado_at IS NULL) = 0, 'el saldo de corrección se cancela';
  ASSERT (SELECT saldo_pendiente FROM public.estado_cobro_remision_refaccion(r)) = round(total0 * 0.9, 2), 'debe el total corregido';
END $$;
ROLLBACK;

\echo '10. Compra confirmada vs. recepción con diferencia (la compra no se modifica)'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
CREATE TEMP TABLE t_compra AS
SELECT (public.crear_compra_refacciones(
  jsonb_build_object('almacen', 'linea_dorada', 'contenedor_ref', 'Contenedor PRUEBA 99', 'origen', 'packing_list', 'archivo_hash', 'hash-prueba-99'),
  jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-005'), 'cantidad', 500)),
  jsonb_build_array(jsonb_build_object('codigo', 'TST-999', 'descripcion', 'No existe')))->>'id')::uuid AS id;
GRANT SELECT ON t_compra TO authenticated;
DO $$
DECLARE
  c uuid := (SELECT id FROM t_compra);
  v_stock integer := (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-005');
BEGIN
  -- No confirmada: no mueve existencias. Duplicado: no se vuelve a importar.
  ASSERT (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-005') = v_stock;
  PERFORM public._t_falla($q$SELECT public.crear_compra_refacciones('{"almacen":"linea_dorada","archivo_hash":"hash-prueba-99"}'::jsonb,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-005'), 'cantidad', 1)))$q$, 'ya se importó');
  PERFORM public._t_falla($q$SELECT public.crear_compra_refacciones('{"almacen":"linea_dorada","contenedor_ref":"contenedor prueba 99"}'::jsonb,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-005'), 'cantidad', 1)))$q$, 'ya tiene la compra');
  -- Con un código por dar de alta no se confirma.
  PERFORM public._t_falla(format('SELECT public.confirmar_compra_refacciones(%L)', c), 'por dar de alta');
  PERFORM public.resolver_pendiente_compra_refacciones(
    (SELECT id FROM public.compra_refaccion_pendientes WHERE compra_id = c), NULL, NULL, 'Viene repetido en el archivo');
  PERFORM public.confirmar_compra_refacciones(c);
  ASSERT (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-005') = v_stock + 500, 'sube por lo esperado';
  -- Confirmada: ya no se edita.
  PERFORM public._t_falla(format('SELECT public.actualizar_compra_refacciones(%L, %L, NULL)', c, '{"notas":"x"}'), 'no se edita');
END $$;
RESET ROLE;
-- Almacén registra lo contado (2 cajas cerradas de 20 + 450 sueltas = 490):
-- queda como PROPUESTA; Compras la aprueba.
SELECT public._t_como('prueba.almacen@dazon.demo');
CREATE TEMP TABLE t_rec AS
SELECT public.registrar_recepcion_refacciones((SELECT id FROM t_compra), public._t_hoy(),
  jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-005'), 'cajas_cerradas', 2, 'piezas_sueltas', 450,
                                       'incidencia', 'Faltan 10'))) AS r;
GRANT SELECT ON t_rec TO authenticated;
DO $$ BEGIN
  ASSERT (SELECT (r->>'ajuste_aplicado')::boolean FROM t_rec) = false, 'Almacén no aplica ajustes';
  PERFORM public._t_falla(format('SELECT public.revisar_propuesta_ajuste(%L, true, %L)', (SELECT (r->>'ajuste_id')::uuid FROM t_rec), 'ok'),
    'Sólo Compras');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE v_stock integer := (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-005');
BEGIN
  PERFORM public.revisar_propuesta_ajuste((SELECT (r->>'ajuste_id')::uuid FROM t_rec), true, 'Visto bueno');
  ASSERT (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'TST-005') = v_stock - 10;
  ASSERT (SELECT sum(cantidad) FROM public.compra_refaccion_lineas WHERE compra_id = (SELECT id FROM t_compra)) = 500, 'la compra no cambia';
  ASSERT (SELECT diferencia FROM public.v_compra_refacciones_contenedor WHERE compra_id = (SELECT id FROM t_compra)) = -10;
  ASSERT (SELECT real_inventario FROM public.v_compra_refacciones_contenedor WHERE compra_id = (SELECT id FROM t_compra)) = 490;
  -- Kárdex: la entrada original (500) y el ajuste negativo (10) por separado.
  ASSERT (SELECT count(*) FROM public.kardex_refaccion(public._t_prod('TST-005'), public._t_hoy() - 1, public._t_hoy())
           WHERE (documento_tipo = 'compra' AND entrada = 500) OR (documento_tipo = 'recepcion' AND salida = 10)) = 2;
END $$;
ROLLBACK;

\echo '10b. Dividir una compra (una compra, un almacén)'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
SELECT public.guardar_almacen_inventario('linea_prueba_2', 'Línea PRUEBA 2', NULL, true, true);
RESET ROLE;
INSERT INTO public.almacen_refacciones_productos (codigo_nuevo, clave_completa, linea_catalogo, descripcion, precio, stock, es_prueba)
VALUES ('TST-L2', 'TST-L2', 'linea_prueba_2', 'Artículo PRUEBA de otra línea', 10, 0, true);
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE c uuid; n jsonb; l uuid;
BEGIN
  c := (public.crear_compra_refacciones('{"almacen":"linea_dorada"}'::jsonb,
          jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-007'), 'cantidad', 5)))->>'id')::uuid;
  -- La línea de otra almacén se agrega directo como si viniera del packing list.
  EXECUTE 'RESET ROLE';
  INSERT INTO public.compra_refaccion_lineas (compra_id, producto_id, codigo, cantidad) VALUES (c, public._t_prod('TST-L2'), 'TST-L2', 7) RETURNING id INTO l;
  EXECUTE 'SET LOCAL ROLE authenticated';
  n := public.dividir_compra_refacciones(c, ARRAY[l], 'linea_prueba_2');
  ASSERT (SELECT almacen FROM public.compras_refacciones WHERE id = (n->>'id')::uuid) = 'linea_prueba_2';
  ASSERT (SELECT count(*) FROM public.compra_refaccion_lineas WHERE compra_id = c) = 1;
  ASSERT (SELECT count(*) FROM public.compra_refaccion_lineas WHERE compra_id = (n->>'id')::uuid) = 1;
END $$;
ROLLBACK;

\echo '11. Seguridad por filas y por rol'
BEGIN;
SELECT public._t_como('prueba.ventas@dazon.demo');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.inventario_almacenes) = 0, 'Ventas no ve almacenes';
  ASSERT (SELECT count(*) FROM public.ajustes_inventario) = 0, 'Ventas no ve ajustes';
  ASSERT (SELECT count(*) FROM public.cobranza_pagos) = 0, 'Ventas no ve pagos';
  PERFORM public._t_falla($q$SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'mal_conteo', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cantidad_contada', 1)))$q$, 'Sólo Compras');
  PERFORM public._t_falla($q$SELECT public.alta_articulo_refaccion('{"codigo_nuevo":"TST-X","descripcion":"x"}')$q$, 'Sólo Compras');
  -- Ve el saldo a favor de su cliente (pero no lo aplica).
  ASSERT public.saldo_favor_disponible_cliente(public._t_cli('TST-C03')) = 1700;
  PERFORM public._t_falla(format('SELECT public.aplicar_saldo_favor(%L, %L, 1)',
    (SELECT id FROM public.cobranza_saldos_favor LIMIT 1), (SELECT id FROM public.remisiones_refacciones LIMIT 1)), 'permiso');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.inventario_almacenes) > 0, 'Almacén sí ve almacenes';
  PERFORM public._t_falla($q$SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'mal_conteo', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cantidad_contada', 1)))$q$, 'Sólo Compras');
  -- Sí puede proponer un conteo (cajas cerradas + sueltas).
  PERFORM public.proponer_conteo_fisico('linea_dorada', public._t_hoy(),
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'), 'cajas_cerradas', 3, 'piezas_sueltas', 12)));
  ASSERT EXISTS (SELECT 1 FROM public.ajuste_inventario_lineas l JOIN public.ajustes_inventario a ON a.id = l.ajuste_id
                  WHERE a.estatus = 'propuesta' AND l.cantidad_contada = 3 * 200 + 12), 'cajas × piezas por caja + sueltas';
  PERFORM public._t_falla(format('SELECT public.aplicar_pago_cobranza(%L, %L)', (SELECT id FROM public.cobranza_pagos LIMIT 1), '[]'), 'Sólo Compras');
END $$;
RESET ROLE;
-- Un usuario de prueba no toca datos reales.
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'mal_conteo', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad_contada', 5)))$q$, 'MODO PRUEBA');
END $$;
RESET ROLE;
-- Lo que un usuario de prueba da de alta en Clientes nace como prueba.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  INSERT INTO public.clientes (codigo_erp, nombre_comercial) VALUES ('TST-NUEVO', 'CLIENTE PRUEBA NUEVO');
  ASSERT (SELECT es_prueba FROM public.clientes WHERE codigo_erp = 'TST-NUEVO'), 'nace como prueba';
  -- Un cliente real no se toca: o lo frena el RLS (0 filas) o el candado.
  BEGIN
    UPDATE public.clientes SET telefono = '1' WHERE codigo_erp = 'REAL-001';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE '%MODO PRUEBA%', SQLERRM;
  END;
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT telefono FROM public.clientes WHERE codigo_erp = 'REAL-001') IS NULL, 'el cliente real no cambió';
END $$;
-- Compras real: aplica ajustes a datos reales, y no ve el filtro de prueba al revés.
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'auditoria', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad_contada', 5)));
  ASSERT (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'REAL-ART-1') = 5;
END $$;
ROLLBACK;

\echo '12. Reportes excluyen la prueba por defecto'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.resumen_rotacion_refacciones(public._t_hoy() - 365, public._t_hoy()) WHERE es_prueba), 'sin prueba';
  ASSERT (SELECT count(*) FROM public.resumen_rotacion_refacciones(public._t_hoy() - 365, public._t_hoy(), true) WHERE es_prueba) = 25, 'con prueba';
  ASSERT (SELECT sum(piezas_vendidas) FROM public.resumen_rotacion_refacciones(public._t_hoy() - 400, public._t_hoy(), true)
           WHERE codigo = 'TST-001') > (SELECT sum(piezas_vendidas) FROM public.resumen_rotacion_refacciones(public._t_hoy() - 400, public._t_hoy(), true)
           WHERE codigo = 'TST-020'), 'Pareto: TST-001 vende más que TST-020';
  ASSERT NOT EXISTS (SELECT 1 FROM public.saldos_atipicos_refacciones() a JOIN public.almacen_refacciones_productos p ON p.id = a.producto_id WHERE p.es_prueba);
END $$;
ROLLBACK;

\echo '13. Siembra idempotente y reinicio sólo de prueba'
BEGIN;
DO $$
DECLARE v_real integer := (SELECT count(*) FROM public.almacen_refacciones_productos WHERE NOT es_prueba);
BEGIN
  ASSERT (public.sembrar_datos_prueba_compras()->>'sembrado')::boolean = false, 'la segunda vez no siembra';
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_productos WHERE es_prueba) = 25;
  ASSERT (SELECT count(*) FROM public.clientes WHERE es_prueba) = 8;
  PERFORM public._t_falla($q$SELECT public.reiniciar_datos_prueba_compras('reiniciar')$q$, 'REINICIAR DATOS DE PRUEBA');
  PERFORM public.reiniciar_datos_prueba_compras('REINICIAR DATOS DE PRUEBA');
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_productos WHERE es_prueba) = 25;
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_productos WHERE NOT es_prueba) = v_real, 'lo real no se toca';
END $$;
ROLLBACK;

\echo '14. Unificar compatibilidades y búsqueda tolerante'
BEGIN;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$
DECLARE
  d uuid := (SELECT id FROM public.almacen_refacciones_unidades WHERE nombre = 'TST-FT-180');
  o1 uuid := (SELECT id FROM public.almacen_refacciones_unidades WHERE nombre = 'TST-FT180');
  o2 uuid := (SELECT id FROM public.almacen_refacciones_unidades WHERE nombre = 'TST-FT 180');
BEGIN
  ASSERT (SELECT count(*) FROM public.buscar_modelos_refacciones('tstft180')) = 3, 'encuentra las 3 variantes';
  PERFORM public.unificar_unidades_refacciones(d, ARRAY[o1, o2], 'TST-FT-180');
  ASSERT (SELECT count(*) FROM public.buscar_modelos_refacciones('TST FT180')) = 1, 'queda un solo modelo';
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_producto_compat WHERE unidad_id IN (o1, o2)) = 0;
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_producto_compat WHERE unidad_id = d) >= 9, 'los artículos se mudaron';
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_unidad_alias WHERE unidad_id = d) = 2, 'variantes como alias';
END $$;
RESET ROLE;
-- Si la importación vuelve a ligar la variante vieja, se redirige sola.
INSERT INTO public.almacen_refacciones_producto_compat (producto_id, unidad_id)
VALUES (public._t_prod('TST-010'), (SELECT id FROM public.almacen_refacciones_unidades WHERE nombre = 'TST-FT180'));
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.almacen_refacciones_producto_compat pc JOIN public.almacen_refacciones_unidades u ON u.id = pc.unidad_id
                      WHERE u.nombre = 'TST-FT180');
END $$;
ROLLBACK;

\echo '15. Lo existente sigue igual: remisión real, liberar, faltante, entrega'
BEGIN;
RESET ROLE;
UPDATE public.almacen_refacciones_productos SET stock = 20 WHERE codigo_nuevo = 'REAL-ART-1';
SELECT public._t_como('vendedor.real@ejemplo.mx');
CREATE TEMP TABLE t_real AS
SELECT (public.crear_remision_refacciones(public._t_cli('REAL-001'), 'Real', NULL,
  jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad', 5)),
  '{"tipo_envio":"recoge","tipo_pago":"contra_entrega","forma_pago":"efectivo"}'::jsonb)->>'id')::uuid AS id;
GRANT SELECT ON t_real TO authenticated;
DO $$ BEGIN
  ASSERT (SELECT folio FROM public.remisiones_refacciones WHERE id = (SELECT id FROM t_real)) ~ '^RF-\d{5}$', 'serie real RF-';
  ASSERT (SELECT es_prueba FROM public.remisiones_refacciones WHERE id = (SELECT id FROM t_real)) = false;
END $$;
RESET ROLE;
CREATE TEMP TABLE t_real_item AS
SELECT id FROM public.remision_refaccion_items WHERE remision_id = (SELECT id FROM t_real);
GRANT SELECT ON t_real_item TO authenticated;
-- Una cuenta de prueba (aunque sea administradora y conozca el id) no surte
-- ni entrega lo real: el candado alcanza también a las funciones existentes.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.liberar_refaccion_remision(%L, 5)', (SELECT id FROM t_real_item)), 'MODO PRUEBA');
END $$;
RESET ROLE;
-- El almacén real surte y entrega como siempre.
SELECT public._t_como('almacen.real@ejemplo.mx');
SELECT public.liberar_refaccion_remision((SELECT id FROM t_real_item), 5);
RESET ROLE;
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.entregar_remision_refaccion(%L)', (SELECT id FROM t_real)), 'MODO PRUEBA');
END $$;
RESET ROLE;
SELECT public._t_como('almacen.real@ejemplo.mx');
SELECT public.entregar_remision_refaccion((SELECT id FROM t_real));
DO $$ BEGIN
  ASSERT (SELECT stock FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'REAL-ART-1') = 15;
  ASSERT (SELECT etapa FROM public.remisiones_refacciones WHERE id = (SELECT id FROM t_real)) = 'entregada',
    'con entrega_exige_pago apagado, lo real se entrega como antes';
END $$;
ROLLBACK;

\echo '16. En prueba, Logística no cierra la entrega sin pago validado'
BEGIN;
SELECT public._t_como('prueba.super@dazon.demo');
-- CLIENTE PRUEBA 1 es de contado: Almacén surte, pero sin pago no se entrega.
SELECT public.liberar_refaccion_remision(i.id, i.cantidad_bloqueada)
  FROM public.remision_refaccion_items i JOIN public.remisiones_refacciones r ON r.id = i.remision_id
 WHERE r.notas = 'Levantada: espera a Almacén' AND r.es_prueba;
DO $$ BEGIN
  PERFORM public._t_falla(format('SELECT public.entregar_remision_refaccion(%L)',
    (SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Levantada: espera a Almacén')), 'pago validado');
  -- Con crédito (CLIENTE PRUEBA 2) sí, aunque deba.
  PERFORM public.entregar_remision_refaccion((SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Pagada parcial'));
  PERFORM public.entregar_remision_refaccion((SELECT id FROM public.remisiones_refacciones WHERE es_prueba AND notas = 'Pagada con un depósito a varias remisiones'));
END $$;
ROLLBACK;


\echo '17. Saldos a favor: sólo Compras (y el administrador) los aplica; Finanzas no'
BEGIN;
DO $$ BEGIN
  ASSERT (SELECT valor FROM public.compras_parametros WHERE clave = 'saldo_favor_aplican') = '["compras"]'::jsonb,
    'valor por defecto: sólo Compras';
END $$;
CREATE TEMP TABLE t_sf AS
SELECT s.id AS saldo_id, (SELECT r.id FROM public.remisiones_refacciones r
                           WHERE r.es_prueba AND r.notas = 'Levantada: espera a Almacén') AS remision_id
  FROM public.cobranza_saldos_favor s
 WHERE s.es_prueba AND s.origen = 'pago_en_exceso' AND s.cliente_id = public._t_cli('TST-C01');
GRANT SELECT ON t_sf TO authenticated;
-- Almacén confirma la remisión de CLIENTE PRUEBA 1 (si no, es cotización).
SELECT public._t_como('prueba.super@dazon.demo');
SELECT public.liberar_refaccion_remision(i.id, i.cantidad_bloqueada)
  FROM public.remision_refaccion_items i WHERE i.remision_id = (SELECT remision_id FROM t_sf);
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  ASSERT NOT public.puede_aplicar_saldo_favor(auth.uid()), 'Finanzas no aplica';
  ASSERT (SELECT count(*) FROM public.v_cobranza_saldos_favor WHERE es_prueba) > 0, 'Finanzas sí ve los saldos';
  PERFORM public._t_falla(format('SELECT public.aplicar_saldo_favor(%L, %L, 100)',
    (SELECT saldo_id FROM t_sf), (SELECT remision_id FROM t_sf)), 'No tienes permiso para aplicar saldos a favor');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.ventas@dazon.demo');
DO $$ BEGIN
  ASSERT public.saldo_favor_disponible_cliente(public._t_cli('TST-C01')) > 0, 'Ventas ve el saldo disponible de su cliente';
  PERFORM public._t_falla(format('SELECT public.aplicar_saldo_favor(%L, %L, 100)',
    (SELECT saldo_id FROM t_sf), (SELECT remision_id FROM t_sf)), 'No tienes permiso');
  PERFORM public.solicitar_saldo_favor((SELECT remision_id FROM t_sf), 100, 'PRUEBA: el cliente pide usar su saldo');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  ASSERT public.puede_aplicar_saldo_favor(auth.uid()), 'Compras aplica';
  PERFORM public.aplicar_saldo_favor((SELECT saldo_id FROM t_sf), (SELECT remision_id FROM t_sf), 100,
    (SELECT id FROM public.cobranza_solicitudes_saldo WHERE remision_id = (SELECT remision_id FROM t_sf) AND estatus = 'pendiente'));
  ASSERT (SELECT cobrado_saldo_favor FROM public.estado_cobro_remision_refaccion((SELECT remision_id FROM t_sf))) = 100;
END $$;
RESET ROLE;
-- Compras (real) no se da, ni le da a Finanzas, el permiso: sólo un administrador.
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$UPDATE public.compras_parametros SET valor = '["compras","finanzas"]' WHERE clave = 'saldo_favor_aplican'$q$,
    'Sólo un administrador');
  PERFORM public._t_falla($q$UPDATE public.compras_parametros SET valor = 'true' WHERE clave = 'entrega_exige_pago'$q$,
    'Sólo un administrador');
END $$;
RESET ROLE;
-- Una cuenta de prueba, aunque sea administradora, no cambia configuración real.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  ASSERT public.puede_aplicar_saldo_favor(auth.uid()), 'el administrador aplica';
  PERFORM public._t_falla($q$UPDATE public.compras_parametros SET valor = '["compras","finanzas"]' WHERE clave = 'saldo_favor_aplican'$q$,
    'MODO PRUEBA');
END $$;
RESET ROLE;
-- Es editable: un administrador real puede dárselo a Finanzas.
SELECT public._t_como('admin.real@ejemplo.mx');
UPDATE public.compras_parametros SET valor = '["compras","finanzas"]' WHERE clave = 'saldo_favor_aplican';
DO $$ BEGIN
  PERFORM public._t_falla($q$UPDATE public.compras_parametros SET valor = '["ventas"]' WHERE clave = 'saldo_favor_aplican'$q$,
    'lista con compras y/o finanzas');
END $$;
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  ASSERT public.puede_aplicar_saldo_favor(auth.uid()), 'con el parámetro cambiado, Finanzas ya aplica';
END $$;
ROLLBACK;

\echo '18. Motivos de ajuste: catálogo real, editable, un motivo usado no se borra'
BEGIN;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.inventario_motivos_ajuste
           WHERE NOT es_prueba AND activo AND clave IN ('mal_conteo', 'auditoria', 'incidencia_recepcion', 'merma', 'correccion_captura', 'otro')) = 6,
    'los 6 motivos aprobados son datos reales';
  ASSERT (SELECT clave FROM public.inventario_motivos_ajuste WHERE activo ORDER BY orden, clave LIMIT 1) = 'mal_conteo',
    '«Mal conteo» va primero';
  ASSERT (SELECT requiere_texto FROM public.inventario_motivos_ajuste WHERE clave = 'otro'), '«Otro» pide texto';
END $$;
-- Compras (real) agrega un motivo, lo renombra y lo usa.
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT public.guardar_motivo_ajuste('', 'Robo o extravío') = 'robo_o_extravio';
  ASSERT (SELECT NOT es_prueba AND activo FROM public.inventario_motivos_ajuste WHERE clave = 'robo_o_extravio');
  PERFORM public.guardar_motivo_ajuste('robo_o_extravio', 'Robo o extravío (con acta)');
  ASSERT (SELECT nombre FROM public.inventario_motivos_ajuste WHERE clave = 'robo_o_extravio') = 'Robo o extravío (con acta)';
  ASSERT (SELECT orden FROM public.inventario_motivos_ajuste WHERE clave = 'robo_o_extravio')
       > (SELECT orden FROM public.inventario_motivos_ajuste WHERE clave = 'mal_conteo'), 'el nuevo no se adelanta a «Mal conteo»';
  -- Desactivar y reactivar: nunca se borra.
  PERFORM public.guardar_motivo_ajuste('merma', 'Merma o daño', false, false);
  ASSERT NOT (SELECT activo FROM public.inventario_motivos_ajuste WHERE clave = 'merma');
  PERFORM public._t_falla($q$SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'merma', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad_contada', 0)))$q$,
    'motivo|no existe|activo');
  PERFORM public.guardar_motivo_ajuste('merma', 'Merma o daño', false, true);
END $$;
RESET ROLE;
-- Un motivo ya usado (la semilla usa «mal_conteo») no se borra ni cambia de clave, ni siquiera desde el SQL editor.
DO $$ BEGIN
  PERFORM public._t_falla($q$DELETE FROM public.inventario_motivos_ajuste WHERE clave = 'mal_conteo'$q$, 'ya se usó');
  PERFORM public._t_falla($q$UPDATE public.inventario_motivos_ajuste SET clave = 'mal_conteo2' WHERE clave = 'mal_conteo'$q$, 'no la clave');
END $$;
-- Ventas no edita motivos.
SELECT public._t_como('vendedor.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.guardar_motivo_ajuste('', 'Motivo de ventas')$q$, 'Sólo Compras');
END $$;
RESET ROLE;
-- Una cuenta de prueba agrega motivos de prueba; no toca los reales.
SELECT public._t_como('prueba.compras@dazon.demo');
DO $$ BEGIN
  PERFORM public.guardar_motivo_ajuste('', 'Motivo de PRUEBA');
  ASSERT (SELECT es_prueba FROM public.inventario_motivos_ajuste WHERE clave = 'motivo_de_prueba');
  PERFORM public._t_falla($q$SELECT public.guardar_motivo_ajuste('mal_conteo', 'Mal conteo (cambiado en prueba)')$q$, 'MODO PRUEBA');
  -- …y los usa en sus ajustes de prueba.
  PERFORM public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'motivo_de_prueba', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('TST-001'),
      'cantidad_contada', public.saldo_refaccion_a_fecha(public._t_prod('TST-001'), public._t_hoy()) + 1)));
END $$;
RESET ROLE;
-- Un ajuste real no puede usar un motivo de prueba.
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  PERFORM public._t_falla($q$SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'motivo_de_prueba', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad_contada', 0)))$q$,
    'es de prueba');
END $$;
RESET ROLE;
-- Reiniciar borra el motivo de prueba.
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT public.reiniciar_datos_prueba_compras('REINICIAR DATOS DE PRUEBA') IS NOT NULL;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.inventario_motivos_ajuste WHERE clave = 'motivo_de_prueba');
  ASSERT EXISTS (SELECT 1 FROM public.inventario_motivos_ajuste WHERE clave = 'robo_o_extravio'), 'el real se queda';
END $$;
ROLLBACK;

\echo '19. Las cuentas de prueba no ven ni tocan datos reales (todas las tablas y vistas)'
BEGIN;
-- Datos reales en varias tablas: remisión, compra, ajuste, aviso.
UPDATE public.almacen_refacciones_productos SET stock = 30 WHERE codigo_nuevo = 'REAL-ART-1';
SELECT public._t_como('vendedor.real@ejemplo.mx');
CREATE TEMP TABLE t_real19 AS
SELECT (public.crear_remision_refacciones(public._t_cli('REAL-001'), 'Real 19', NULL,
  jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad', 1)),
  '{"tipo_envio":"recoge","tipo_pago":"contra_entrega","forma_pago":"efectivo"}'::jsonb)->>'id')::uuid AS id;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
SELECT public.crear_compra_refacciones(
  jsonb_build_object('almacen', 'linea_dorada', 'almacen_confirmado', true, 'contenedor', 'REAL-CONT-19'),
  jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad', 10))) IS NOT NULL;
SELECT public.aplicar_ajuste_rapido('linea_dorada', public._t_hoy(), 'mal_conteo', NULL,
  jsonb_build_array(jsonb_build_object('producto_id', public._t_prod('REAL-ART-1'), 'cantidad_contada', 29))) IS NOT NULL;
RESET ROLE;
INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, creado_por)
VALUES ('compras', 'info', 'Aviso real', 'Aviso real de ejemplo', '00000000-0000-0000-0000-0000000000b1');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.clientes WHERE NOT es_prueba) > 0;
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_productos WHERE NOT es_prueba) > 0;
  ASSERT (SELECT count(*) FROM public.remision_refaccion_items i JOIN public.remisiones_refacciones r ON r.id = i.remision_id WHERE NOT r.es_prueba) > 0;
  ASSERT (SELECT count(*) FROM public.ajuste_inventario_lineas l JOIN public.ajustes_inventario a ON a.id = l.ajuste_id WHERE NOT a.es_prueba) > 0;
  ASSERT (SELECT count(*) FROM public.compra_refaccion_lineas l JOIN public.compras_refacciones c ON c.id = l.compra_id WHERE NOT c.es_prueba) > 0;
END $$;

-- Lo que una cuenta de prueba ve de más, tabla por tabla y vista por vista,
-- según su regla. Corre como esa cuenta; el padre se consulta sin filtros.
CREATE OR REPLACE FUNCTION public._t_padre_prueba(_tabla text, _id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $f$
DECLARE v boolean;
BEGIN
  EXECUTE format('SELECT es_prueba FROM public.%I WHERE id = $1', _tabla) INTO v USING _id;
  RETURN coalesce(v, false);
END $f$;
GRANT EXECUTE ON FUNCTION public._t_padre_prueba(text, uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public._t_tiene_col(_rel text, _col text) RETURNS boolean LANGUAGE sql AS $f$
  SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = _rel AND column_name = _col)
$f$;
GRANT EXECUTE ON FUNCTION public._t_tiene_col(text, text) TO authenticated;
CREATE OR REPLACE FUNCTION public._t_fugas() RETURNS TABLE (relacion text, regla text, filas_reales bigint)
LANGUAGE plpgsql AS $f$
DECLARE c record; r public.inventario_reglas_modo_prueba%ROWTYPE; v_sql text; v_regla text;
BEGIN
  FOR c IN
    SELECT k.relname, k.relkind,
           EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = k.oid AND a.attname = 'es_prueba' AND NOT a.attisdropped) AS tiene
      FROM pg_class k
     WHERE k.relnamespace = 'public'::regnamespace AND k.relkind IN ('r', 'v')
       AND has_table_privilege(k.oid, 'SELECT') AND k.relname NOT LIKE '\_%'
  LOOP
    SELECT * INTO r FROM public.inventario_reglas_modo_prueba WHERE tabla = c.relname;
    v_regla := CASE WHEN c.relkind = 'v' THEN 'vista' ELSE coalesce(r.lectura, 'nada') END;
    v_sql := CASE
      WHEN v_regla IN ('todo', 'especial') THEN NULL
      WHEN v_regla = 'vista' AND c.tiene THEN format('SELECT count(*) FROM public.%I WHERE NOT es_prueba', c.relname)
      -- Vistas sin es_prueba: cada fila se revisa contra su cliente o remisión.
      WHEN v_regla = 'vista' AND public._t_tiene_col(c.relname, 'cliente_id')
        THEN format('SELECT count(*) FROM public.%I WHERE NOT public._t_padre_prueba(''clientes'', cliente_id)', c.relname)
      WHEN v_regla = 'vista' AND public._t_tiene_col(c.relname, 'remision_id')
        THEN format('SELECT count(*) FROM public.%I WHERE NOT public._t_padre_prueba(''remisiones_refacciones'', remision_id)', c.relname)
      WHEN v_regla = 'vista' AND c.relname = 'v_clientes_credito'
        THEN 'SELECT count(*) FROM public.v_clientes_credito WHERE NOT public._t_padre_prueba(''clientes'', id)'
      WHEN v_regla = 'vista' THEN format('SELECT count(*) FROM public.%I', c.relname)
      WHEN v_regla = 'prueba' THEN format('SELECT count(*) FROM public.%I WHERE NOT es_prueba', c.relname)
      WHEN v_regla = 'padre' THEN format('SELECT count(*) FROM public.%I x WHERE NOT public._t_padre_prueba(%L, x.%I)', c.relname, r.padre_tabla, r.columna)
      WHEN v_regla = 'propio' THEN format('SELECT count(*) FROM public.%I WHERE %I IS DISTINCT FROM auth.uid()', c.relname, r.columna)
      WHEN v_regla = 'propio_o_prueba' THEN format('SELECT count(*) FROM public.%I WHERE %I IS DISTINCT FROM auth.uid() AND NOT public.es_usuario_prueba(%I)', c.relname, r.columna, r.columna)
      ELSE format('SELECT count(*) FROM public.%I', c.relname) END;
    IF v_sql IS NOT NULL THEN
      relacion := c.relname; regla := v_regla;
      BEGIN
        EXECUTE v_sql INTO filas_reales;
      EXCEPTION WHEN insufficient_privilege THEN
        filas_reales := 0;  -- tampoco la puede leer
      END;
      IF filas_reales > 0 THEN RETURN NEXT; END IF;
    END IF;
  END LOOP;
END $f$;
GRANT EXECUTE ON FUNCTION public._t_fugas() TO authenticated;
-- Vistas que sólo agregan catálogos visibles (no traen datos reales).
CREATE TEMP TABLE t_vistas_catalogo (relacion text);
INSERT INTO t_vistas_catalogo VALUES ('v_reporte_pipeline'), ('v_saldos_cuentas'), ('v_stock_modelo_color'), ('v_carga_ya_armados');
GRANT SELECT ON t_vistas_catalogo TO authenticated;

CREATE TEMP TABLE t_fugas (email text, relacion text, regla text, filas_reales bigint);
GRANT INSERT, SELECT ON t_fugas TO authenticated;
SELECT public._t_como('prueba.super@dazon.demo');
INSERT INTO t_fugas SELECT 'prueba.super@dazon.demo', f.* FROM public._t_fugas() f WHERE f.relacion NOT IN (SELECT relacion FROM t_vistas_catalogo);
RESET ROLE;
SELECT public._t_como('prueba.compras@dazon.demo');
INSERT INTO t_fugas SELECT 'prueba.compras@dazon.demo', f.* FROM public._t_fugas() f WHERE f.relacion NOT IN (SELECT relacion FROM t_vistas_catalogo);
RESET ROLE;
SELECT public._t_como('prueba.almacen@dazon.demo');
INSERT INTO t_fugas SELECT 'prueba.almacen@dazon.demo', f.* FROM public._t_fugas() f WHERE f.relacion NOT IN (SELECT relacion FROM t_vistas_catalogo);
RESET ROLE;
SELECT public._t_como('prueba.finanzas@dazon.demo');
INSERT INTO t_fugas SELECT 'prueba.finanzas@dazon.demo', f.* FROM public._t_fugas() f WHERE f.relacion NOT IN (SELECT relacion FROM t_vistas_catalogo);
RESET ROLE;
SELECT public._t_como('prueba.ventas@dazon.demo');
INSERT INTO t_fugas SELECT 'prueba.ventas@dazon.demo', f.* FROM public._t_fugas() f WHERE f.relacion NOT IN (SELECT relacion FROM t_vistas_catalogo);
RESET ROLE;
SELECT public._t_como('prueba.logistica@dazon.demo');
INSERT INTO t_fugas SELECT 'prueba.logistica@dazon.demo', f.* FROM public._t_fugas() f WHERE f.relacion NOT IN (SELECT relacion FROM t_vistas_catalogo);
RESET ROLE;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM t_fugas) THEN
    RAISE EXCEPTION 'Cuentas de prueba que ven datos reales: %',
      (SELECT string_agg(email || ' → ' || relacion || ' (' || regla || '): ' || filas_reales, '; ') FROM t_fugas);
  END IF;
END $$;
-- Las vistas de la lista anterior no exponen nada real a una cuenta de prueba.
SELECT public._t_como('prueba.super@dazon.demo');
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.v_saldos_cuentas), 'cuentas financieras reales';
  ASSERT (SELECT cargadas FROM public.v_carga_ya_armados) = 0, 'motocarros reales';
  -- Funciones de reporte (SECURITY DEFINER): sólo prueba, aunque no se pida.
  ASSERT NOT EXISTS (SELECT 1 FROM public.resumen_rotacion_refacciones(public._t_hoy() - 365, public._t_hoy()) WHERE NOT es_prueba);
  ASSERT NOT EXISTS (SELECT 1 FROM public.resumen_rotacion_refacciones(public._t_hoy() - 365, public._t_hoy(), true) WHERE NOT es_prueba);
  ASSERT NOT EXISTS (SELECT 1 FROM public.saldos_atipicos_refacciones(true) s
                      JOIN public.almacen_refacciones_productos p ON p.id = s.producto_id WHERE NOT p.es_prueba);
  ASSERT NOT EXISTS (SELECT 1 FROM public.ventas_mensuales_refacciones(public._t_hoy() - 365, public._t_hoy(), true)
                      WHERE NOT public._t_padre_prueba('almacen_refacciones_productos', producto_id));
  -- Conocer el id de un dato real tampoco basta.
  PERFORM public._t_falla(format('SELECT * FROM public.kardex_refaccion(%L)', public._t_prod('REAL-ART-1')), 'MODO PRUEBA');
  PERFORM public._t_falla(format('SELECT * FROM public.salidas_por_cliente_mes(%L, NULL, NULL)', public._t_prod('REAL-ART-1')), 'MODO PRUEBA');
  ASSERT NOT EXISTS (SELECT 1 FROM public.avisos WHERE titulo = 'Aviso real'), 'avisos reales';
  -- Escrituras directas o por funciones existentes sobre datos reales.
  -- Un UPDATE directo no la encuentra (0 filas); abajo se comprueba que no cambió.
  EXECUTE format('UPDATE public.remisiones_refacciones SET notas = %L WHERE id = %L', 'cambiada en prueba', (SELECT id FROM t_real19));
  PERFORM public._t_falla(format('SELECT public.marcar_pago_remision_refaccion(%L, true, %L)', (SELECT id FROM t_real19), 'Pagado en efectivo'), 'MODO PRUEBA');
  PERFORM public._t_falla($q$UPDATE public.user_roles SET nivel = 'admin' WHERE user_id = auth.uid()$q$, 'MODO PRUEBA');
  -- No se saca de la lista de prueba (sin política de borrado: 0 filas).
  DELETE FROM public.inventario_usuarios_prueba WHERE email = 'prueba.super@dazon.demo';
  ASSERT public.es_usuario_prueba(auth.uid()), 'sigue siendo cuenta de prueba';
  PERFORM public._t_falla($q$INSERT INTO public.config_general (capacidad_diaria) VALUES (1)$q$, 'MODO PRUEBA|violates|permission');
  -- Su propio perfil sí lo ve.
  ASSERT (SELECT count(*) FROM public.profiles WHERE id = auth.uid()) = 1;
  ASSERT (SELECT count(*) FROM public.user_roles WHERE user_id = auth.uid()) = 1;
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT notas FROM public.remisiones_refacciones WHERE id = (SELECT id FROM t_real19)) = 'Real 19', 'la remisión real no cambió';
END $$;
-- Archivos: sólo la carpeta prueba/ del bucket de evidencias.
INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('evidencias-compras', 'pagos/real.png', '00000000-0000-0000-0000-0000000000b1');
SELECT public._t_como('prueba.finanzas@dazon.demo');
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM storage.objects WHERE name = 'pagos/real.png'), 'no ve la evidencia real';
  PERFORM public._t_falla($q$INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('evidencias-compras', 'pagos/x.png', auth.uid())$q$, 'row-level security');
  INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('evidencias-compras', 'prueba/pagos/x.png', auth.uid());
  ASSERT EXISTS (SELECT 1 FROM storage.objects WHERE name = 'prueba/pagos/x.png');
END $$;
RESET ROLE;
-- Los usuarios reales siguen viendo lo suyo y no ven los avisos de prueba.
SELECT public._t_como('prueba.finanzas@dazon.demo');
SELECT public.registrar_pago_cobranza(jsonb_build_object('cliente_id', public._t_cli('TST-C02'), 'monto', 100, 'forma', 'efectivo',
  'evidencia_path', 'prueba/pagos/x.png', 'evidencia_tipo', 'vale_efectivo', 'validar', true)) IS NOT NULL;
RESET ROLE;
SELECT public._t_como('martin.real@ejemplo.mx');
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'REAL-ART-1');
  ASSERT EXISTS (SELECT 1 FROM storage.objects WHERE name = 'pagos/real.png');
  ASSERT EXISTS (SELECT 1 FROM public.avisos WHERE titulo = 'Aviso real');
  ASSERT NOT EXISTS (SELECT 1 FROM public.avisos WHERE es_prueba), 'los avisos de prueba no le llegan a Compras real';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.avisos WHERE es_prueba), 'el pago de prueba sí generó su aviso (de prueba)';
END $$;
ROLLBACK;

\echo 'TODAS LAS PRUEBAS DE BASE PASARON'
