-- Permiso individual para asignar chasis y motor en remisiones sin cambiar de área.

CREATE TABLE IF NOT EXISTS public.remisiones_asignacion_acceso (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  activo BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.remisiones_asignacion_acceso ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS remisiones_asignacion_acceso_lectura ON public.remisiones_asignacion_acceso;
CREATE POLICY remisiones_asignacion_acceso_lectura
  ON public.remisiones_asignacion_acceso
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.es_admin_global(auth.uid()));

DROP POLICY IF EXISTS remisiones_asignacion_acceso_escritura ON public.remisiones_asignacion_acceso;
CREATE POLICY remisiones_asignacion_acceso_escritura
  ON public.remisiones_asignacion_acceso
  FOR ALL TO authenticated
  USING (public.es_admin_global(auth.uid()))
  WITH CHECK (public.es_admin_global(auth.uid()));

CREATE OR REPLACE FUNCTION public.puede_asignar_remisiones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.usuario_activo(_user_id)
    AND (
      public.es_admin_global(_user_id)
      OR public.es_area(_user_id, 'fabrica'::public.user_area)
      OR public.has_role(_user_id, 'admin'::public.app_role)
      OR public.has_role(_user_id, 'fabrica'::public.app_role)
      OR EXISTS (
        SELECT 1
        FROM public.remisiones_asignacion_acceso a
        WHERE a.user_id = _user_id AND a.activo
      )
    );
$$;

REVOKE ALL ON FUNCTION public.puede_asignar_remisiones(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puede_asignar_remisiones(UUID) TO authenticated, service_role;

INSERT INTO public.remisiones_asignacion_acceso (user_id, email, activo)
SELECT id, email, true
FROM auth.users
WHERE lower(email) = 'atenea@dazon.demo.com'
ON CONFLICT (user_id) DO UPDATE
SET email = EXCLUDED.email, activo = true, updated_at = now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.remisiones_asignacion_acceso
    WHERE lower(email) = 'atenea@dazon.demo.com' AND activo
  ) THEN
    RAISE EXCEPTION 'No existe el usuario atenea@dazon.demo.com en Auth; no se otorgó el permiso';
  END IF;
END;
$$;

DO $patch$
DECLARE
  _firma regprocedure;
  _def text;
  _nueva text;
  _firmas text[] := ARRAY[
    'public.asignar_motocarro_a_remision(uuid,uuid)',
    'public.desasignar_motocarro_de_remision(uuid)',
    'public.capturar_seriales_unidad(uuid,text,text)',
    'public.crear_motocarro_ya_armado(text,text,text,text,uuid)'
  ];
  _nombre text;
  _guard text;
BEGIN
  FOREACH _nombre IN ARRAY _firmas LOOP
    _firma := to_regprocedure(_nombre);
    IF _firma IS NULL THEN
      RAISE EXCEPTION 'No se modificó nada. Falta la función %', _nombre;
    END IF;

    SELECT pg_get_functiondef(_firma) INTO _def;
    IF position('puede_asignar_remisiones(auth.uid())' IN _def) > 0 THEN
      CONTINUE;
    END IF;

    _guard := CASE
      WHEN _nombre IN (
        'public.asignar_motocarro_a_remision(uuid,uuid)',
        'public.desasignar_motocarro_de_remision(uuid)'
      ) THEN E'IF NOT (\n    public.has_role(auth.uid(), \'admin\') OR\n    public.has_role(auth.uid(), \'fabrica\')\n  ) THEN'
      WHEN _nombre = 'public.capturar_seriales_unidad(uuid,text,text)'
        THEN 'IF NOT (has_role(auth.uid(),''admin''::app_role) OR has_role(auth.uid(),''fabrica''::app_role)) THEN'
      ELSE 'IF NOT (has_role(auth.uid(), ''admin''::app_role) OR has_role(auth.uid(), ''fabrica''::app_role)) THEN'
    END;
    _nueva := replace(_def, _guard, 'IF NOT public.puede_asignar_remisiones(auth.uid()) THEN');

    IF _nueva = _def THEN
      RAISE EXCEPTION 'No se encontró la validación de acceso esperada en %', _nombre;
    END IF;

    EXECUTE _nueva;
  END LOOP;
END;
$patch$;

NOTIFY pgrst, 'reload schema';
