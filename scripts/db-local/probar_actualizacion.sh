#!/usr/bin/env bash
# Una base que ya tenía las migraciones 20261006* de una versión anterior del
# PR (por ejemplo, pegadas en una base de pruebas) recibe las actuales:
# deben correr limpias y aplicar las decisiones (saldo a favor sólo Compras,
# Línea dorada sin equivalencia supuesta con Ecount).
#   PGHOST=/var/lib/postgresql PGPORT=5433 scripts/db-local/probar_actualizacion.sh [ref_anterior]
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
REF="${1:-a6b8b91}"
DB="kit_actualizacion"
export PGUSER="${PGUSER:-postgres}"
VIEJAS="$(mktemp -d)"
trap 'rm -rf "$VIEJAS"' EXIT
for f in $(git -C "$RAIZ" ls-tree --name-only "$REF" supabase/migrations/ | grep '/20261006'); do
  git -C "$RAIZ" show "$REF:$f" > "$VIEJAS/$(basename "$f")"
done

psql -v ON_ERROR_STOP=1 -q -d postgres -c "DROP DATABASE IF EXISTS \"$DB\";" -c "CREATE DATABASE \"$DB\";"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$RAIZ/scripts/db-local/supabase_stub.sql" >/dev/null
for f in $(ls "$RAIZ"/supabase/migrations/2*.sql "$RAIZ"/scripts/db-local/fuera_de_main/2*.sql | awk -F/ '{print $NF" "$0}' | sort | cut -d" " -f2); do
  case "$(basename "$f")" in 2026100[67]*) continue;; esac
  { grep -iE "^\s*ALTER TYPE .* ADD VALUE" "$f" || true; } | while read -r s; do psql -q -X -d "$DB" -c "${s%;};" >/dev/null 2>&1 || true; done
  psql -v ON_ERROR_STOP=1 -q -X --single-transaction -d "$DB" -f "$f" >/dev/null
done
for f in "$VIEJAS"/*.sql; do
  psql -v ON_ERROR_STOP=1 -q -X --single-transaction -d "$DB" -f "$f" >/dev/null && echo "anterior ($REF)  $(basename "$f")"
done
psql -v ON_ERROR_STOP=1 -q -X -d "$DB" -c "SELECT public.sembrar_datos_prueba_compras();" >/dev/null
for f in "$RAIZ"/supabase/migrations/2026100[67]*.sql; do
  psql -v ON_ERROR_STOP=1 -q -X --single-transaction -d "$DB" -f "$f" >/dev/null 2>&1 && echo "actual           $(basename "$f")"
done
psql -v ON_ERROR_STOP=1 -X -d "$DB" <<'SQL'
DO $$ BEGIN
  ASSERT (SELECT valor FROM public.compras_parametros WHERE clave = 'saldo_favor_aplican') = '["compras"]'::jsonb,
    'saldo a favor: sólo Compras';
  ASSERT (SELECT descripcion FROM public.inventario_almacenes WHERE clave = 'linea_dorada') NOT LIKE '%Ecount%',
    'sin equivalencia supuesta con Ecount';
  ASSERT (SELECT count(*) FROM public.almacen_refacciones_productos WHERE es_prueba) = 25, 'la semilla sigue';
  ASSERT EXISTS (SELECT 1 FROM public.abc_leyenda_combinaciones WHERE combinacion = 'AC');
  RAISE NOTICE 'ACTUALIZACIÓN LIMPIA';
END $$;
SQL
