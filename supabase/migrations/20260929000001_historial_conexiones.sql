CREATE TABLE IF NOT EXISTS public.historial_conexiones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sesion_id text NOT NULL,
  conectado_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (usuario_id, sesion_id)
);

CREATE INDEX IF NOT EXISTS idx_historial_conexiones_usuario_fecha
  ON public.historial_conexiones (usuario_id, conectado_at DESC);
CREATE INDEX IF NOT EXISTS idx_historial_conexiones_fecha
  ON public.historial_conexiones (conectado_at DESC);

ALTER TABLE public.historial_conexiones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "direccion lee historial conexiones" ON public.historial_conexiones;
CREATE POLICY "direccion lee historial conexiones"
  ON public.historial_conexiones
  FOR SELECT TO authenticated
  USING (
    public.es_area(auth.uid(), 'direccion'::public.user_area)
    OR public.es_admin_global(auth.uid())
    OR public.has_role(auth.uid(), 'admin'::public.app_role)
  );

CREATE OR REPLACE FUNCTION public.registrar_conexion()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_usuario_id uuid := auth.uid();
  v_sesion_id text := COALESCE(
    auth.jwt() ->> 'session_id',
    auth.jwt() ->> 'jti',
    concat(auth.uid()::text, ':', auth.jwt() ->> 'iat')
  );
BEGIN
  IF v_usuario_id IS NULL THEN
    RAISE EXCEPTION 'Se requiere una sesión autenticada';
  END IF;

  INSERT INTO public.historial_conexiones (usuario_id, sesion_id)
  VALUES (v_usuario_id, v_sesion_id)
  ON CONFLICT (usuario_id, sesion_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_conexion() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_conexion() TO authenticated, service_role;
