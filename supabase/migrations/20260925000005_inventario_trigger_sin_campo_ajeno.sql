-- El trigger compartido leía NEW.cantidad_disponible también al actualizar
-- el stock de refacciones. Esa tabla no tiene la columna y Postgres aborta
-- la liberación. Cada inventario sólo revisa su propio campo.

CREATE OR REPLACE FUNCTION public.impedir_inventario_negativo()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_disp integer;
  v_modelo text;
  v_color text;
BEGIN
  IF TG_TABLE_NAME = 'almacen_refacciones_productos' THEN
    IF NEW.stock < 0 THEN
      RAISE EXCEPTION 'El inventario de refacciones no puede quedar en negativo (quedaría %)', NEW.stock;
    END IF;
  ELSIF TG_TABLE_NAME = 'inventario_colores' THEN
    v_disp := (to_jsonb(NEW)->>'cantidad_disponible')::integer;
    v_modelo := to_jsonb(NEW)->>'modelo';
    v_color := to_jsonb(NEW)->>'color';
    IF coalesce(v_disp, 0) < 0 THEN
      RAISE EXCEPTION 'El inventario de motocarros no puede quedar en negativo (quedaría % de % %)',
        v_disp, v_modelo, v_color;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
