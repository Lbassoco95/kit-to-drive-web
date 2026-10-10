-- ============================================================================
-- Altas de usuario por administrador: autorización explícita en vez de depender
-- del marcador en app_metadata.
--
-- Problema: el candado trg_reject_public_signups (BEFORE INSERT en auth.users)
-- solo dejaba pasar altas con created_via_admin / managed_by en
-- raw_app_meta_data. Supabase Auth ya no entrega esos datos a tiempo al crear
-- una cuenta por la API de administración, y toda alta legítima se rechazaba
-- con «Database error creating new user».
--
-- Solución: antes de crear la cuenta, la Edge Function (service_role) registra
-- el correo en `altas_autorizadas` por 3 minutos. El candado lo consume y deja
-- pasar SOLO ese correo. El registro público sigue rechazado.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.altas_autorizadas (
  email     text PRIMARY KEY,
  expira_at timestamptz NOT NULL DEFAULT now() + interval '3 minutes'
);
ALTER TABLE public.altas_autorizadas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.altas_autorizadas FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.altas_autorizadas TO service_role;

CREATE OR REPLACE FUNCTION public.reject_public_signups()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Vía anterior (se conserva por compatibilidad).
  IF coalesce(NEW.raw_app_meta_data->>'created_via_admin','') IN ('true','1')
     OR coalesce(NEW.raw_app_meta_data->>'managed_by','') IN ('admin-create-user','mati-admin','kit-to-drive-admin')
  THEN
    RETURN NEW;
  END IF;

  -- Vía actual: el administrador autorizó este correo hace menos de 3 minutos.
  IF EXISTS (SELECT 1 FROM public.altas_autorizadas a
              WHERE a.email = lower(coalesce(NEW.email, '')) AND a.expira_at > now()) THEN
    DELETE FROM public.altas_autorizadas WHERE email = lower(coalesce(NEW.email, ''));
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Signups públicos deshabilitados. Solicita acceso a un administrador.'
    USING ERRCODE = 'check_violation',
          DETAIL = 'app_metadata recibido: ' || coalesce(NEW.raw_app_meta_data::text, 'null');
END;
$function$;

-- Verificación: debe devolver la tabla, RLS activa y el candado con permiso.
SELECT
  to_regclass('public.altas_autorizadas') AS tabla,
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.altas_autorizadas'::regclass) AS rls,
  has_function_privilege('supabase_auth_admin', 'public.reject_public_signups()', 'execute') AS candado_ok,
  has_table_privilege('anon', 'public.altas_autorizadas', 'select') AS anon_ve_tabla;
