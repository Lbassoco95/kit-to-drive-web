#!/usr/bin/env python3
"""Empaca las migraciones de Compras e Inventario (2026100[67]*) en UN archivo
para el SQL Editor de Supabase.

El editor agrega por su cuenta «ALTER TABLE … ENABLE ROW LEVEL SECURITY»
cuando cree ver una tabla nueva, y confunde el «SELECT … INTO variable» de
las funciones PL/pgSQL con eso: mete la línea a mitad de la función y la
rompe. Empacado en base64 no lo puede leer; la base lo decodifica, revisa el
md5 (si llegó incompleto no aplica nada) y lo corre todo o nada.

    python3 scripts/db-local/empacar_migraciones_compras.py
"""
import base64
import glob
import hashlib
import os
import textwrap

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SALIDA = os.path.join(RAIZ, "supabase", "aplicar_compras_inventario_en_un_paso.sql")

archivos = sorted(glob.glob(os.path.join(RAIZ, "supabase", "migrations", "2026100[67]*.sql")))
sql = "".join(open(f, encoding="utf-8").read().rstrip("\n") + "\n\n" for f in archivos)
md5 = hashlib.md5(sql.encode()).hexdigest()
b64 = "\n".join(textwrap.wrap(base64.b64encode(sql.encode()).decode(), 76))
lista = "\n".join(f"--   {os.path.basename(f)}" for f in archivos)

with open(SALIDA, "w", encoding="utf-8") as fh:
    fh.write(f"""-- ============================================================================
-- Kit to Drive · Compras e Inventario · migraciones del PR #48 en UN paso
{lista}
-- Archivo GENERADO por scripts/db-local/empacar_migraciones_compras.py
-- (no se edita a mano). Van en base64 para que el SQL Editor de Supabase no
-- les meta líneas propias. Se aplican TODAS O NINGUNA.
-- md5 del SQL original: {md5}
-- ============================================================================
DO $kit_compras$
DECLARE v_sql text := convert_from(decode('
{b64}
', 'base64'), 'UTF8');
BEGIN
  IF md5(v_sql) <> '{md5}' THEN
    RAISE EXCEPTION 'El archivo llegó incompleto (md5 diferente). No se aplicó nada.';
  END IF;
  EXECUTE v_sql;
END $kit_compras$;

SELECT 'Migraciones de Compras e Inventario aplicadas' AS resultado,
       to_regclass('public.inventario_almacenes') IS NOT NULL AS m01,
       to_regclass('public.ajustes_inventario') IS NOT NULL AS m02,
       to_regclass('public.cobranza_pagos') IS NOT NULL AS m03,
       to_regprocedure('public.sembrar_datos_prueba_compras()') IS NOT NULL AS m04,
       to_regclass('public.inventario_reglas_modo_prueba') IS NOT NULL AS m05;
""")
print(SALIDA, md5)
