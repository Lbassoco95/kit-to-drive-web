-- Reprocesar descripción corta + compatibilidades de refacciones
-- (reutiliza unidades normalizadas: FT-125, FT-125 DELIVERY, etc.)

CREATE OR REPLACE FUNCTION public.sincronizar_compat_refacciones(_items JSONB)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item JSONB;
  prod_id UUID;
  v_codigo TEXT;
  unidad_txt TEXT;
  unidad_norm TEXT;
  unidad_id UUID;
  procesados INTEGER := 0;
  links INTEGER := 0;
BEGIN
  IF coalesce(auth.role(), '') = 'anon' THEN
    RAISE EXCEPTION 'Sin acceso al almacén de refacciones';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT public.puede_ver_almacen_refacciones() THEN
    RAISE EXCEPTION 'Sin acceso al almacén de refacciones';
  END IF;

  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' THEN
    RAISE EXCEPTION 'Se espera un arreglo JSON';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(_items)
  LOOP
    v_codigo := nullif(trim(item->>'codigo_nuevo'), '');
    IF v_codigo IS NULL THEN CONTINUE; END IF;

    SELECT id INTO prod_id
    FROM public.almacen_refacciones_productos
    WHERE codigo_nuevo = v_codigo;
    IF prod_id IS NULL THEN CONTINUE; END IF;

    UPDATE public.almacen_refacciones_productos
    SET descripcion_corta = coalesce(nullif(trim(item->>'descripcion_corta'), ''), descripcion_corta),
        updated_at = now()
    WHERE id = prod_id;

    DELETE FROM public.almacen_refacciones_producto_compat WHERE producto_id = prod_id;

    IF item->'compatibilidades' IS NOT NULL AND jsonb_typeof(item->'compatibilidades') = 'array' THEN
      FOR unidad_txt IN
        SELECT nullif(trim(value), '')
        FROM jsonb_array_elements_text(item->'compatibilidades') AS t(value)
      LOOP
        IF unidad_txt IS NULL THEN CONTINUE; END IF;
        unidad_norm := lower(regexp_replace(unidad_txt, '\s+', ' ', 'g'));

        INSERT INTO public.almacen_refacciones_unidades (nombre, nombre_normalizado)
        VALUES (unidad_txt, unidad_norm)
        ON CONFLICT (nombre_normalizado) DO UPDATE SET
          nombre = EXCLUDED.nombre;

        SELECT id INTO unidad_id
        FROM public.almacen_refacciones_unidades
        WHERE nombre_normalizado = unidad_norm;

        INSERT INTO public.almacen_refacciones_producto_compat (producto_id, unidad_id, texto_origen)
        VALUES (prod_id, unidad_id, unidad_txt)
        ON CONFLICT DO NOTHING;
        links := links + 1;
      END LOOP;
    END IF;

    procesados := procesados + 1;
  END LOOP;

  RETURN jsonb_build_object('procesados', procesados, 'compatibilidades', links);
END;
$$;

REVOKE ALL ON FUNCTION public.sincronizar_compat_refacciones(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sincronizar_compat_refacciones(JSONB) TO authenticated;
