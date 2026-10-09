-- RPC: importar_vins_inventario — imports VINs to inventario_chasis and updates inventario_colores
CREATE OR REPLACE FUNCTION public.importar_vins_inventario(
  _contenedor_id uuid,
  _folio_contenedor text,
  _modelo text,
  _vins jsonb  -- [{numero_chasis, color, modelo?}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _total int;
  _v jsonb;
  _new_id uuid;
  _ids uuid[] := ARRAY[]::uuid[];
  _num_chasis text;
  _col text;
  _mod text;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede importar VINs';
  END IF;

  IF _contenedor_id IS NULL THEN
    RAISE EXCEPTION 'ID de contenedor requerido';
  END IF;

  _total := jsonb_array_length(_vins);
  IF _total = 0 THEN RAISE EXCEPTION 'Debe incluir al menos un VIN'; END IF;

  -- Verify container exists
  IF NOT EXISTS (SELECT 1 FROM contenedores WHERE id = _contenedor_id) THEN
    RAISE EXCEPTION 'Contenedor no encontrado';
  END IF;

  -- Insert or update container folio if provided
  IF _folio_contenedor IS NOT NULL THEN
    UPDATE contenedores SET folio_contenedor = _folio_contenedor WHERE id = _contenedor_id;
  END IF;

  -- Process each VIN
  FOR _v IN SELECT * FROM jsonb_array_elements(_vins) LOOP
    _num_chasis := NULLIF(trim(_v->>'numero_chasis'),'');
    _col := COALESCE(NULLIF(trim(_v->>'color'),''), upper(NULLIF(trim(_v->>'color'),'')), 'BLANCO');
    _mod := COALESCE(NULLIF(trim(_v->>'modelo'),''), _modelo, '200cc 2025');

    IF _num_chasis IS NOT NULL THEN
      -- Insert into inventario_chasis
      INSERT INTO inventario_chasis (numero_chasis, contenedor_id, modelo, color, estatus)
      VALUES (_num_chasis, _contenedor_id, _mod, upper(_col), 'disponible')
      ON CONFLICT (numero_chasis) DO UPDATE SET
        contenedor_id = _contenedor_id,
        modelo = _mod,
        color = upper(_col),
        updated_at = now()
      RETURNING id INTO _new_id;
      
      _ids := array_append(_ids, _new_id);

      -- Update color inventory
      PERFORM public.incrementar_inventario_color(_mod, _col, 1);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('contenedor_id', _contenedor_id, 'creados', _total, 'chasis_ids', _ids);
END;
$$;
