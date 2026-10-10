# Migraciones que producción tiene y `main` no

`supabase/migrations/20260925193000_security_hardening_fase2.sql` (en `main`)
cambia políticas de `public.compras`, `public.compra_lineas`,
`public.documentos_inventario` y `public.documento_inventario_lineas`. Ninguna
migración de `main` crea esas tablas: las crea
`20260925190000_documento_recepcion_compra.sql`, de la rama
`cursor/documento-recepcion-inventario-be32`, que no se integró pero que, por
la migración de hardening, sabemos que se corrió en producción.

Sin ella, `security_hardening_fase2` truena en una base vacía. El arnés local
(`../aplicar_migraciones.sh`) la aplica en su orden para reproducir producción.
Son compras de **motocarros** (chasis/motor/parte/unidad) y no se tocan.

`20260922500000_columnas_solo_en_produccion.sql` agrega a la tabla y a la vista
de refacciones `foto_url`, `descripcion_original` y `caracteristicas`, que la
app pide y que existen en producción (lo dice el comentario de
20260923000001) pero que ningún script de `main` crea.
