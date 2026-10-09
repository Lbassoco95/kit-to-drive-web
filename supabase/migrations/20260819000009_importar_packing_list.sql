-- RPC: importar_packing_list — imports packing list to inventario_partes
CREATE OR REPLACE FUNCTION public.importar_packing_list(
  _contenedor_id uuid,
  _partes jsonb  -- [{descripcion, modelo, cantidad_esperada}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _total int;
  _p jsonb;
  _new_id uuid;
  _ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede importar packing list';
  END IF;

  IF _contenedor_id IS NULL THEN
    RAISE EXCEPTION 'ID de contenedor requerido';
  END IF;

  _total := jsonb_array_length(_partes);
  IF _total = 0 THEN RAISE EXCEPTION 'Debe incluir al menos una parte'; END IF;

  -- Verify container exists
  IF NOT EXISTS (SELECT 1 FROM contenedores WHERE id = _contenedor_id) THEN
    RAISE EXCEPTION 'Contenedor no encontrado';
  END IF;

  -- Delete existing parts for this container to avoid duplicates
  DELETE FROM inventario_partes WHERE contenedor_id = _contenedor_id;

  -- Insert new parts
  FOR _p IN SELECT * FROM jsonb_array_elements(_partes) LOOP
    INSERT INTO inventario_partes (contenedor_id, descripcion, modelo, cantidad_esperada, cantidad_recibida)
    VALUES (
      _contenedor_id,
      NULLIF(trim(_p->>'descripcion'),''),
      NULLIF(trim(_p->>'modelo'),''),
      COALESCE((_p->>'cantidad_esperada')::int, 0),
      0
    )
    RETURNING id INTO _new_id;
    _ids := array_append(_ids, _new_id);
  END LOOP;

  RETURN jsonb_build_object('contenedor_id', _contenedor_id, 'creados', _total, 'parte_ids', _ids);
END;
$$;
