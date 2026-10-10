#!/usr/bin/env bash
# Simula el esquema actual con datos, aplica las migraciones de Compras e
# Inventario (20261006*) y verifica que no se perdió ni cambió nada.
#   PGHOST=/var/lib/postgresql PGPORT=5433 scripts/db-local/probar_sobre_existente.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${1:-kit_sobre_existente}"
export PGUSER="${PGUSER:-postgres}"
NUEVAS="2026100[67]"

psql -v ON_ERROR_STOP=1 -q -d postgres -c "DROP DATABASE IF EXISTS \"$DB\";" -c "CREATE DATABASE \"$DB\";"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$RAIZ/scripts/db-local/supabase_stub.sql"
for f in $(ls "$RAIZ"/supabase/migrations/2*.sql "$RAIZ"/scripts/db-local/fuera_de_main/2*.sql | awk -F/ '{print $NF" "$0}' | sort | cut -d" " -f2); do
  case "$(basename "$f")" in $NUEVAS*) continue;; esac
  { grep -iE "^\s*ALTER TYPE .* ADD VALUE" "$f" || true; } | while read -r s; do psql -q -X -d "$DB" -c "${s%;};" >/dev/null 2>&1 || true; done
  psql -v ON_ERROR_STOP=1 -q -X --single-transaction -d "$DB" -f "$f" >/dev/null
done

# Datos «de producción»: artículos con existencia (cargada por lista de
# precios, sin kárdex), remisiones en curso y surtidas, movimientos.
psql -v ON_ERROR_STOP=1 -q -X -d "$DB" <<'SQL'
INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES
  ('10000000-0000-0000-0000-000000000001', 'polo@ejemplo.mx', '{"created_via_admin":"true"}');
INSERT INTO public.profiles (id, nombre_completo) VALUES ('10000000-0000-0000-0000-000000000001', 'Polo') ON CONFLICT DO NOTHING;
INSERT INTO public.user_roles (user_id, role, area, nivel) VALUES ('10000000-0000-0000-0000-000000000001', 'admin', 'direccion', 'admin');
INSERT INTO public.almacen_refacciones_acceso (email, user_id, activo) VALUES ('polo@ejemplo.mx', '10000000-0000-0000-0000-000000000001', true);
INSERT INTO public.clientes (codigo_erp, nombre_comercial) SELECT 'C' || g, 'Cliente ' || g FROM generate_series(1, 30) g;
SELECT public.importar_almacen_refacciones(jsonb_agg(jsonb_build_object(
  'codigo_nuevo', 'BAT-' || lpad(g::text, 3, '0'), 'descripcion', 'Batería ' || g || ' FT-150',
  'linea_catalogo', CASE WHEN g % 4 = 0 THEN 'linea_azul' ELSE 'linea_dorada' END,
  'precio', 100 + g, 'stock', 50 + g, 'compatibilidades', jsonb_build_array('FT-150', 'FT 150'))))
  FROM generate_series(1, 40) g;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', false);
DO $$
DECLARE r jsonb; i int;
BEGIN
  FOR i IN 1..12 LOOP
    r := public.crear_remision_refacciones((SELECT id FROM public.clientes WHERE codigo_erp = 'C' || i), 'Real ' || i, NULL,
      jsonb_build_array(jsonb_build_object('producto_id', (SELECT id FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'BAT-' || lpad(i::text, 3, '0')), 'cantidad', 3),
                        jsonb_build_object('producto_id', (SELECT id FROM public.almacen_refacciones_productos WHERE codigo_nuevo = 'BAT-' || lpad((i + 20)::text, 3, '0')), 'cantidad', 2)),
      '{"tipo_envio":"recoge","tipo_pago":"anticipado","forma_pago":"efectivo"}'::jsonb);
    IF i % 2 = 0 THEN
      PERFORM public.liberar_refaccion_remision(it.id, it.cantidad_bloqueada)
         FROM public.remision_refaccion_items it WHERE it.remision_id = (r->>'id')::uuid;
    END IF;
    IF i % 3 = 0 THEN PERFORM public.marcar_pago_remision_refaccion((r->>'id')::uuid, true, 'Pagado en efectivo'); END IF;
  END LOOP;
END $$;
SELECT set_config('request.jwt.claim.sub', '', false);
CREATE TABLE public._antes AS
SELECT 'producto:' || codigo_nuevo AS k, stock::text || '|' || linea_catalogo || '|' || coalesce(precio::text, '') AS v FROM public.almacen_refacciones_productos
UNION ALL SELECT 'remision:' || folio, etapa || '|' || pagado || '|' || abierta || '|' || cliente_id FROM public.remisiones_refacciones
UNION ALL SELECT 'item:' || id, cantidad || '|' || cantidad_bloqueada || '|' || cantidad_surtida || '|' || estatus || '|' || coalesce(precio_unitario::text, '') FROM public.remision_refaccion_items
UNION ALL SELECT 'mov:' || id, producto_id || '|' || tipo || '|' || cantidad FROM public.almacen_refacciones_movimientos
UNION ALL SELECT 'cliente:' || codigo_erp, coalesce(nombre_comercial, '') FROM public.clientes
UNION ALL SELECT 'compat:' || producto_id || unidad_id, '1' FROM public.almacen_refacciones_producto_compat;
SQL

for f in "$RAIZ"/supabase/migrations/$NUEVAS*.sql; do
  psql -v ON_ERROR_STOP=1 -q -X --single-transaction -d "$DB" -f "$f" >/dev/null && echo "ok     $(basename "$f")"
done
# Segunda pasada: idempotentes.
for f in "$RAIZ"/supabase/migrations/$NUEVAS*.sql; do
  psql -v ON_ERROR_STOP=1 -q -X --single-transaction -d "$DB" -f "$f" >/dev/null && echo "ok x2  $(basename "$f")"
done

psql -v ON_ERROR_STOP=1 -X -d "$DB" <<'SQL'
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', false);
CREATE TEMP TABLE despues AS
SELECT 'producto:' || codigo_nuevo AS k, stock::text || '|' || linea_catalogo || '|' || coalesce(precio::text, '') AS v FROM public.almacen_refacciones_productos
UNION ALL SELECT 'remision:' || folio, etapa || '|' || pagado || '|' || abierta || '|' || cliente_id FROM public.remisiones_refacciones
UNION ALL SELECT 'item:' || id, cantidad || '|' || cantidad_bloqueada || '|' || cantidad_surtida || '|' || estatus || '|' || coalesce(precio_unitario::text, '') FROM public.remision_refaccion_items
UNION ALL SELECT 'mov:' || id, producto_id || '|' || tipo || '|' || cantidad FROM public.almacen_refacciones_movimientos
UNION ALL SELECT 'cliente:' || codigo_erp, coalesce(nombre_comercial, '') FROM public.clientes
UNION ALL SELECT 'compat:' || producto_id || unidad_id, '1' FROM public.almacen_refacciones_producto_compat;
DO $$
DECLARE n_dif integer; n_antes integer;
BEGIN
  SELECT count(*) INTO n_antes FROM public._antes;
  SELECT count(*) INTO n_dif FROM (
    (SELECT * FROM public._antes EXCEPT SELECT * FROM despues)
    UNION ALL (SELECT * FROM despues EXCEPT SELECT * FROM public._antes)) x;
  IF n_dif > 0 THEN RAISE EXCEPTION 'Cambiaron % registros', n_dif; END IF;
  IF EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos WHERE fecha_efectiva IS NULL) THEN
    RAISE EXCEPTION 'Movimientos sin fecha efectiva';
  END IF;
  IF EXISTS (SELECT 1 FROM public.remision_refaccion_items WHERE orden_id IS NULL) THEN
    RAISE EXCEPTION 'Partidas sin orden';
  END IF;
  RAISE NOTICE 'SIN PÉRDIDA: % registros iguales antes y después; % órdenes de inventario creadas; % saldos atípicos reportados',
    n_antes, (SELECT count(*) FROM public.remision_refaccion_ordenes),
    (SELECT count(*) FROM public.saldos_atipicos_refacciones(true));
END $$;
SQL
