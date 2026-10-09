-- Function to import motors from Excel into inventario_motor
CREATE OR REPLACE FUNCTION public.importar_motores_inventario(
  _folio_contenedor TEXT,
  _motores JSONB  -- array of {engine_number, modelo}
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  _motor JSONB;
  _total INTEGER := 0;
BEGIN
  FOR _motor IN SELECT * FROM jsonb_array_elements(_motores)
  LOOP
    IF (_motor->>'numero_motor') IS NOT NULL AND trim(_motor->>'numero_motor') != '' THEN
      INSERT INTO public.inventario_motor (numero_motor, modelo, contenedor_id, estatus, created_at)
      VALUES (trim(_motor->>'numero_motor'), trim(coalesce(_motor->>'modelo','')), _folio_contenedor, 'disponible', NOW())
      ON CONFLICT DO NOTHING;
      IF FOUND THEN _total := _total + 1; END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'total', _total);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION public.importar_motores_inventario(TEXT, JSONB) TO authenticated;
