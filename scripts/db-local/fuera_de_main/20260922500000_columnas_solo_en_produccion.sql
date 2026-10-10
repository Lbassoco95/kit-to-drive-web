-- Columnas que producción tiene y ninguna migración de `main` crea (ver
-- LEEME.md). La pantalla «Levantar remisión de refacciones» pide
-- `v_almacen_refacciones.foto_url`: sin ella el selector de piezas sale vacío.
-- Sólo para el arnés local; la vista la recrea 20260923000001 copiando las
-- columnas que ya tenga, así que basta con que exista en la tabla y la vista.
ALTER TABLE public.almacen_refacciones_productos
  ADD COLUMN IF NOT EXISTS foto_url text,
  ADD COLUMN IF NOT EXISTS descripcion_original text,
  ADD COLUMN IF NOT EXISTS caracteristicas text;
CREATE OR REPLACE VIEW public.v_almacen_refacciones WITH (security_invoker = true) AS
SELECT p.id, p.codigo_nuevo, p.codigo_antiguo, p.clave_completa, p.clave_simplificada, p.linea_catalogo, p.marca, p.categoria,
       p.descripcion, p.descripcion_corta, p.unidad_medida, p.piezas_por_caja, p.precio, p.stock, p.visible_venta, p.no_lista,
       p.fuente_archivo, p.created_at, p.updated_at,
       coalesce((SELECT count(*) FROM public.almacen_refacciones_producto_compat c WHERE c.producto_id = p.id), 0)::integer AS num_compatibilidades,
       p.descripcion_original, p.caracteristicas, p.foto_url
  FROM public.almacen_refacciones_productos p;
