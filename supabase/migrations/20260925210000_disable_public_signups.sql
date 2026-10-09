-- Signups públicos OFF (enforcement en DB) + registro en diagnóstico.
-- GoTrue disable_signup del dashboard puede seguir en false sin Management API;
-- este trigger rechaza INSERT en auth.users salvo altas admin marcadas.

CREATE OR REPLACE FUNCTION public.reject_public_signups()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF coalesce(NEW.raw_app_meta_data->>'created_via_admin','') IN ('true','1')
     OR coalesce(NEW.raw_app_meta_data->>'managed_by','') IN ('admin-create-user','mati-admin','kit-to-drive-admin')
  THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Signups públicos deshabilitados. Solicita acceso a un administrador.'
    USING ERRCODE = 'check_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_reject_public_signups ON auth.users;
CREATE TRIGGER trg_reject_public_signups
  BEFORE INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_public_signups();

REVOKE ALL ON FUNCTION public.reject_public_signups() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reject_public_signups() TO supabase_auth_admin, postgres, service_role;
