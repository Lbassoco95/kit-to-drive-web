-- RPC: recibir_contenedor — crea contenedor + N motocarros con orden_armado consecutivo
CREATE OR REPLACE FUNCTION public.recibir_contenedor(
  _folio_contenedor text,
  _fecha_arribo date,
  _modelo text,
  _color text,
  _unidades jsonb  -- [{ns_chasis, ns_motor, chasis_asignado?}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _cont_id uuid;
  _next_orden int;
  _total int;
  _ids uuid[] := ARRAY[]::uuid[];
  _u jsonb;
  _i int := 0;
  _ns_ch text; _ns_mo text; _ch text;
  _new_id uuid;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede recibir contenedores';
  END IF;

  IF _folio_contenedor IS NULL OR length(trim(_folio_contenedor)) = 0 THEN
    RAISE EXCEPTION 'Folio de contenedor requerido';
  END IF;

  _total := jsonb_array_length(_unidades);
  IF _total = 0 THEN RAISE EXCEPTION 'Debe incluir al menos una unidad'; END IF;

  -- Validar duplicados internos
  IF (SELECT COUNT(*) FROM (
        SELECT (u->>'ns_chasis') AS v FROM jsonb_array_elements(_unidades) u
        WHERE NULLIF(trim(u->>'ns_chasis'),'') IS NOT NULL
      ) s WHERE v IN (SELECT v FROM (
        SELECT (u->>'ns_chasis') AS v FROM jsonb_array_elements(_unidades) u
        WHERE NULLIF(trim(u->>'ns_chasis'),'') IS NOT NULL
        GROUP BY 1 HAVING COUNT(*) > 1) d)) > 0 THEN
    RAISE EXCEPTION 'NS chasis duplicado dentro del packing list';
  END IF;

  -- Validar contra existentes
  IF EXISTS (
    SELECT 1 FROM motocarros m
    WHERE m.ns_chasis IS NOT NULL AND m.ns_chasis IN (
      SELECT NULLIF(trim(u->>'ns_chasis'),'') FROM jsonb_array_elements(_unidades) u
    )
  ) THEN RAISE EXCEPTION 'Algún NS chasis ya existe en el sistema'; END IF;

  IF EXISTS (
    SELECT 1 FROM motocarros m
    WHERE m.ns_motor IS NOT NULL AND m.ns_motor IN (
      SELECT NULLIF(trim(u->>'ns_motor'),'') FROM jsonb_array_elements(_unidades) u
    )
  ) THEN RAISE EXCEPTION 'Algún NS motor ya existe en el sistema'; END IF;

  INSERT INTO contenedores (folio_contenedor, fecha_arribo, modelo_default, total_unidades)
  VALUES (trim(_folio_contenedor), _fecha_arribo, _modelo, _total)
  RETURNING id INTO _cont_id;

  SELECT COALESCE(MAX(orden_armado),0) INTO _next_orden FROM motocarros;

  FOR _u IN SELECT * FROM jsonb_array_elements(_unidades) LOOP
    _i := _i + 1;
    _ns_ch := NULLIF(trim(_u->>'ns_chasis'),'');
    _ns_mo := NULLIF(trim(_u->>'ns_motor'),'');
    _ch := NULLIF(trim(_u->>'chasis_asignado'),'');
    INSERT INTO motocarros (modelo, color, ns_chasis, ns_motor, chasis_asignado, contenedor_id, orden_armado, estatus_armado)
    VALUES (COALESCE(_modelo,'200cc 2025'), upper(COALESCE(_color,'BLANCO')), _ns_ch, _ns_mo, _ch, _cont_id, _next_orden + _i, 'PENDIENTE')
    RETURNING id INTO _new_id;
    _ids := array_append(_ids, _new_id);
  END LOOP;

  RETURN jsonb_build_object('contenedor_id', _cont_id, 'creados', _total, 'motocarro_ids', _ids);
END;
$$;