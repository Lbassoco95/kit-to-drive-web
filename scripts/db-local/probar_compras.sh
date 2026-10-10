#!/usr/bin/env bash
# Base vacía → todas las migraciones → pruebas de Compras / Inventario / Cobranza.
#   PGHOST=/var/lib/postgresql PGPORT=5433 scripts/db-local/probar_compras.sh
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
DB="${1:-kit_pruebas_compras}"
export PGUSER="${PGUSER:-postgres}"
"$RAIZ/scripts/db-local/aplicar_migraciones.sh" "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$RAIZ/scripts/db-local/pruebas_compras.sql"
