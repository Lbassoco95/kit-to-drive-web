-- Sprint 5: agregar email a profiles para que admin pueda verlo y buscarlo
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS email text;

-- Índice para búsqueda por email
CREATE INDEX IF NOT EXISTS idx_profiles_email ON public.profiles(email);

-- Comentario
COMMENT ON COLUMN public.profiles.email IS 'Email del usuario (copiado de auth.users para visibilidad en UI sin service_role)';
