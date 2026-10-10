#!/usr/bin/env bash
# Aplica, en orden y cada una en su propia transacción (como el SQL editor de
# Supabase), todas las migraciones de supabase/migrations sobre una base local.
#
#   PGHOST=/var/lib/postgresql PGPORT=5433 scripts/db-local/aplicar_migraciones.sh kit_prueba
#
# Crea la base desde cero (DROP + CREATE). Sólo para pruebas locales.
set -euo pipefail
DB="${1:-kit_prueba}"
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
export PGUSER="${PGUSER:-postgres}"

psql -v ON_ERROR_STOP=1 -q -d postgres -c "DROP DATABASE IF EXISTS \"$DB\";" -c "CREATE DATABASE \"$DB\";"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$RAIZ/scripts/db-local/supabase_stub.sql"

fallas=0
# Las migraciones de main más las que producción tiene y main no (ver
# fuera_de_main/LEEME.md), todas en orden de fecha.
for f in $(ls "$RAIZ"/supabase/migrations/2*.sql "$RAIZ"/scripts/db-local/fuera_de_main/2*.sql | awk -F/ '{print $NF" "$0}' | sort | cut -d" " -f2); do
  # En el SQL editor los `ALTER TYPE ... ADD VALUE` se confirman antes de usar
  # el valor nuevo (Postgres no deja usarlo en la misma transacción). Aquí se
  # corren primero, fuera de la transacción del archivo. Son idempotentes.
  { grep -iE "^\s*ALTER TYPE .* ADD VALUE" "$f" || true; } | while read -r stmt; do
    stmt="${stmt%;}"
    case "$stmt" in *"IF NOT EXISTS"*) ;; *) stmt="$(echo "$stmt" | sed -E 's/ADD VALUE/ADD VALUE IF NOT EXISTS/I')";; esac
    psql -q -X -d "$DB" -c "$stmt;" >/dev/null 2>&1 || true
  done
  if ! salida=$(psql -v ON_ERROR_STOP=1 -q -X --single-transaction -d "$DB" -f "$f" 2>&1); then
    echo "FALLA  $(basename "$f")"
    echo "$salida" | grep -E "ERROR|LINE" | head -5 | sed 's/^/       /'
    fallas=$((fallas + 1))
  else
    echo "ok     $(basename "$f")"
  fi
done
echo "Migraciones con falla: $fallas"
[ "$fallas" -eq 0 ]
