-- =============================================================================
-- Hardening de seguridad (auditoría KTI to Drive — críticos/altos)
-- Idempotente / re-ejecutable.
-- =============================================================================

-- ── 0. Columna de cambio obligatorio de contraseña (no editable por el dueño) ─
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS debe_cambiar_password boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.profiles.debe_cambiar_password IS
  'TRUE hasta que el usuario cambie la contraseña vía flujo controlado (Edge Function). '
  'El propio usuario NO puede ponerla en false (trigger).';

-- ── 1. Impedir self-update de activo / email / flags privilegiados ───────────
CREATE OR REPLACE FUNCTION public.proteger_campos_privilegiados_profiles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  es_admin boolean;
BEGIN
  -- service_role / triggers internos (sin JWT) pueden todo
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  es_admin := public.es_admin_global(auth.uid())
           OR public.es_admin_area(auth.uid(), 'direccion'::public.user_area)
           OR EXISTS (
                SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid()
                   AND ur.nivel = 'admin'
                   AND public.usuario_activo(auth.uid())
              );

  -- Nadie (salvo admin activo) puede tocar su propio `activo` ni el de otros
  -- sin ser admin. Un usuario dado de baja NO puede reactivarse: es_admin_global
  -- ya corta por usuario_activo, así que un inactivo nunca pasa este chequeo.
  IF NEW.activo IS DISTINCT FROM OLD.activo THEN
    IF NOT es_admin THEN
      RAISE EXCEPTION 'No autorizado a cambiar profiles.activo';
    END IF;
  END IF;

  IF NEW.debe_cambiar_password IS DISTINCT FROM OLD.debe_cambiar_password THEN
    IF NOT es_admin THEN
      RAISE EXCEPTION 'No autorizado a cambiar profiles.debe_cambiar_password';
    END IF;
  END IF;

  IF NEW.email IS DISTINCT FROM OLD.email THEN
    IF NOT es_admin AND NEW.id = auth.uid() THEN
      RAISE EXCEPTION 'No autorizado a cambiar profiles.email';
    END IF;
    IF NOT es_admin AND NEW.id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'No autorizado a cambiar profiles.email de otro usuario';
    END IF;
  END IF;

  -- codigo_vendedor: solo admin (o service_role)
  IF NEW.codigo_vendedor IS DISTINCT FROM OLD.codigo_vendedor AND NOT es_admin THEN
    RAISE EXCEPTION 'No autorizado a cambiar profiles.codigo_vendedor';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger_profiles_privilegiados ON public.profiles;
CREATE TRIGGER trg_proteger_profiles_privilegiados
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.proteger_campos_privilegiados_profiles();

-- Políticas UPDATE de profiles: el dueño solo puede tocar nombre_completo;
-- admin (área) gestiona el resto. WITH CHECK impide auto-reactivación vía RLS.
DROP POLICY IF EXISTS "actualizar mi profile" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update_propio" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update_admin" ON public.profiles;

-- El dueño activo puede UPDATE su fila; el trigger rechaza cambios a
-- activo / debe_cambiar_password / email / codigo_vendedor.
-- Un usuario inactivo NO pasa USING (usuario_activo) → no puede reactivarse.
CREATE POLICY "profiles_update_propio" ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid() AND public.usuario_activo(auth.uid()))
  WITH CHECK (id = auth.uid());

CREATE POLICY "profiles_update_admin" ON public.profiles
  FOR UPDATE TO authenticated
  USING (
    public.es_admin_global(auth.uid())
    OR public.es_admin_area(auth.uid(), 'direccion'::public.user_area)
    OR EXISTS (
      SELECT 1 FROM public.user_roles ur
       WHERE ur.user_id = auth.uid()
         AND ur.nivel = 'admin'
         AND public.usuario_activo(auth.uid())
    )
  )
  WITH CHECK (
    public.es_admin_global(auth.uid())
    OR public.es_admin_area(auth.uid(), 'direccion'::public.user_area)
    OR EXISTS (
      SELECT 1 FROM public.user_roles ur
       WHERE ur.user_id = auth.uid()
         AND ur.nivel = 'admin'
         AND public.usuario_activo(auth.uid())
    )
  );

-- SELECT profiles: solo usuarios activos; no abre a JWT inválidos/anon.
DROP POLICY IF EXISTS "leer profiles autenticados" ON public.profiles;
DROP POLICY IF EXISTS "profiles_select_activos" ON public.profiles;
CREATE POLICY "profiles_select_activos" ON public.profiles
  FOR SELECT TO authenticated
  USING (
    id = auth.uid()
    OR public.usuario_activo(auth.uid())
  );

-- ── 2. bitacora_eliminaciones: solo admin lee; INSERT solo service_role ─────
DROP POLICY IF EXISTS "solo admin lee bitacora" ON public.bitacora_eliminaciones;
DROP POLICY IF EXISTS "sistema escribe bitacora" ON public.bitacora_eliminaciones;
DROP POLICY IF EXISTS "bitacora_elim_select_admin" ON public.bitacora_eliminaciones;
DROP POLICY IF EXISTS "bitacora_elim_insert_deny" ON public.bitacora_eliminaciones;

CREATE POLICY "bitacora_elim_select_admin" ON public.bitacora_eliminaciones
  FOR SELECT TO authenticated
  USING (
    public.es_admin_global(auth.uid())
    OR public.has_role(auth.uid(), 'admin'::app_role)
  );

-- Sin política INSERT para authenticated → denegado por defecto.
-- Los triggers SECURITY DEFINER insertan como dueño de la función (bypass RLS
-- si el owner es superuser/postgres; en Supabase los SECURITY DEFINER del
-- schema public suelen correr como postgres y bypasean RLS).
REVOKE INSERT, UPDATE, DELETE ON public.bitacora_eliminaciones FROM authenticated, anon;
GRANT SELECT ON public.bitacora_eliminaciones TO authenticated;

-- ── 3. proveedores: quitar SELECT universal ─────────────────────────────────
DROP POLICY IF EXISTS proveedores_select ON public.proveedores;
CREATE POLICY proveedores_select ON public.proveedores
  FOR SELECT TO authenticated
  USING (
    public.es_finanzas(auth.uid())
    OR public.es_compras(auth.uid())
    OR public.es_admin_global(auth.uid())
  );

-- ── 4. clientes: acotar SELECT a áreas operativas ───────────────────────────
DROP POLICY IF EXISTS "leer clientes" ON public.clientes;
CREATE POLICY "leer clientes" ON public.clientes
  FOR SELECT TO authenticated
  USING (
    public.es_admin_global(auth.uid())
    OR public.es_area(auth.uid(), 'comercial'::public.user_area)
    OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
    OR public.es_area(auth.uid(), 'almacen_logistica'::public.user_area)
    OR public.es_area(auth.uid(), 'administracion'::public.user_area)
    OR public.es_area(auth.uid(), 'compras'::public.user_area)
    OR public.es_area(auth.uid(), 'direccion'::public.user_area)
    OR public.has_role(auth.uid(), 'admin'::app_role)
    OR public.has_role(auth.uid(), 'ventas'::app_role)
    OR public.has_role(auth.uid(), 'fabrica'::app_role)
    OR public.has_role(auth.uid(), 'logistica'::app_role)
    OR public.has_role(auth.uid(), 'coordinador'::app_role)
    OR public.has_role(auth.uid(), 'finanzas'::app_role)
    OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
    OR public.has_role(auth.uid(), 'compras'::app_role)
  );

-- ── 5. Allowlist refacciones: escritura solo admin global ───────────────────
DROP POLICY IF EXISTS "ref_acceso_leer" ON public.almacen_refacciones_acceso;
CREATE POLICY "ref_acceso_leer" ON public.almacen_refacciones_acceso
  FOR SELECT TO authenticated
  USING (
    public.es_admin_global(auth.uid())
    OR user_id = auth.uid()
    OR lower(email) = lower(coalesce((SELECT email FROM auth.users WHERE id = auth.uid()), ''))
  );

DROP POLICY IF EXISTS "ref_acceso_escribir" ON public.almacen_refacciones_acceso;
CREATE POLICY "ref_acceso_escribir" ON public.almacen_refacciones_acceso
  FOR ALL TO authenticated
  USING (public.es_admin_global(auth.uid()))
  WITH CHECK (public.es_admin_global(auth.uid()));

-- ── 6. Storage: comentarios-fotos (least privilege) ─────────────────────────
UPDATE storage.buckets
   SET public = false,
       file_size_limit = 5242880,
       allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
 WHERE id = 'comentarios-fotos';

DROP POLICY IF EXISTS "subir foto comentario" ON storage.objects;
DROP POLICY IF EXISTS "leer foto comentario" ON storage.objects;
DROP POLICY IF EXISTS "borrar foto comentario admin" ON storage.objects;
DROP POLICY IF EXISTS "comentarios_fotos_insert" ON storage.objects;
DROP POLICY IF EXISTS "comentarios_fotos_select" ON storage.objects;
DROP POLICY IF EXISTS "comentarios_fotos_delete" ON storage.objects;

CREATE POLICY "comentarios_fotos_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'comentarios-fotos'
    AND public.usuario_activo(auth.uid())
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
      OR public.es_area(auth.uid(), 'almacen_logistica'::public.user_area)
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR public.has_role(auth.uid(), 'fabrica'::app_role)
      OR public.has_role(auth.uid(), 'logistica'::app_role)
      OR public.has_role(auth.uid(), 'ventas'::app_role)
      OR public.has_role(auth.uid(), 'coordinador'::app_role)
    )
  );

CREATE POLICY "comentarios_fotos_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'comentarios-fotos'
    AND public.usuario_activo(auth.uid())
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
      OR public.es_area(auth.uid(), 'almacen_logistica'::public.user_area)
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.es_area(auth.uid(), 'administracion'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR public.has_role(auth.uid(), 'fabrica'::app_role)
      OR public.has_role(auth.uid(), 'logistica'::app_role)
      OR public.has_role(auth.uid(), 'ventas'::app_role)
      OR public.has_role(auth.uid(), 'coordinador'::app_role)
      OR public.has_role(auth.uid(), 'finanzas'::app_role)
      OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
    )
  );

CREATE POLICY "comentarios_fotos_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'comentarios-fotos'
    AND (public.es_admin_global(auth.uid()) OR public.has_role(auth.uid(), 'admin'::app_role))
  );

-- ── 7. Storage: clientes-docs ───────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'clientes-docs',
  'clientes-docs',
  false,
  15728640,
  ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "clientes_docs_select" ON storage.objects;
DROP POLICY IF EXISTS "clientes_docs_insert" ON storage.objects;
DROP POLICY IF EXISTS "clientes_docs_update" ON storage.objects;
DROP POLICY IF EXISTS "clientes_docs_delete" ON storage.objects;

CREATE POLICY "clientes_docs_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'clientes-docs'
    AND public.usuario_activo(auth.uid())
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.es_area(auth.uid(), 'administracion'::public.user_area)
      OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR public.has_role(auth.uid(), 'ventas'::app_role)
      OR public.has_role(auth.uid(), 'coordinador'::app_role)
      OR public.has_role(auth.uid(), 'finanzas'::app_role)
      OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
    )
  );

CREATE POLICY "clientes_docs_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'clientes-docs'
    AND public.usuario_activo(auth.uid())
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.es_area(auth.uid(), 'administracion'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR public.has_role(auth.uid(), 'ventas'::app_role)
      OR public.has_role(auth.uid(), 'coordinador'::app_role)
    )
  );

CREATE POLICY "clientes_docs_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'clientes-docs'
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
    )
  );

CREATE POLICY "clientes_docs_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'clientes-docs'
    AND (public.es_admin_global(auth.uid()) OR public.has_role(auth.uid(), 'admin'::app_role))
  );

-- ── 8. Storage: actividades-evidencia ───────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'actividades-evidencia',
  'actividades-evidencia',
  false,
  10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "actividades_evidencia_select" ON storage.objects;
DROP POLICY IF EXISTS "actividades_evidencia_insert" ON storage.objects;
DROP POLICY IF EXISTS "actividades_evidencia_delete" ON storage.objects;

CREATE POLICY "actividades_evidencia_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'actividades-evidencia'
    AND public.usuario_activo(auth.uid())
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.es_area(auth.uid(), 'administracion'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR public.has_role(auth.uid(), 'ventas'::app_role)
      OR public.has_role(auth.uid(), 'coordinador'::app_role)
      OR public.has_role(auth.uid(), 'director_ventas'::app_role)
      -- dueño del prefijo user_id/...
      OR (storage.foldername(name))[1] = auth.uid()::text
    )
  );

CREATE POLICY "actividades_evidencia_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'actividades-evidencia'
    AND public.usuario_activo(auth.uid())
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR public.has_role(auth.uid(), 'ventas'::app_role)
      OR public.has_role(auth.uid(), 'coordinador'::app_role)
    )
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "actividades_evidencia_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'actividades-evidencia'
    AND (
      public.es_admin_global(auth.uid())
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR (storage.foldername(name))[1] = auth.uid()::text
    )
  );

-- ── 9. remisiones-docs: lectura por rol elevado O dueño de la remisión ──────
DROP POLICY IF EXISTS "leer docs remisiones operativos" ON storage.objects;
CREATE POLICY "leer docs remisiones operativos" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'remisiones-docs'
    AND public.usuario_activo(auth.uid())
    AND (
      public.es_admin_global(auth.uid())
      OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
      OR public.es_area(auth.uid(), 'almacen_logistica'::public.user_area)
      OR public.es_area(auth.uid(), 'administracion'::public.user_area)
      OR public.es_area(auth.uid(), 'direccion'::public.user_area)
      OR public.has_role(auth.uid(), 'admin'::app_role)
      OR public.has_role(auth.uid(), 'fabrica'::app_role)
      OR public.has_role(auth.uid(), 'logistica'::app_role)
      OR public.has_role(auth.uid(), 'coordinador'::app_role)
      OR public.has_role(auth.uid(), 'finanzas'::app_role)
      OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
      OR public.has_role(auth.uid(), 'director_ventas'::app_role)
      OR public.has_role(auth.uid(), 'coordinador_ventas'::app_role)
      -- Comercial/ventas: solo docs de remisiones propias (path = remision_id/…)
      OR (
        (public.es_area(auth.uid(), 'comercial'::public.user_area)
          OR public.has_role(auth.uid(), 'ventas'::app_role)
          OR public.has_role(auth.uid(), 'auxiliar_ventas'::app_role))
        AND EXISTS (
          SELECT 1 FROM public.remisiones r
           WHERE r.id::text = (storage.foldername(name))[1]
             AND r.vendedor_id = auth.uid()
        )
      )
    )
  );

-- ── 10. RPC: completar cambio de contraseña (solo limpia flag de perfil) ────
-- La Edge Function completa-password-change usa service_role; esta RPC queda
-- como respaldo para admins. El usuario final NO puede llamarla con éxito
-- porque el trigger exige admin para poner debe_cambiar_password=false…
-- En su lugar, la Edge Function usa service_role (auth.uid() null en SQL → OK).

CREATE OR REPLACE FUNCTION public.admin_clear_debe_cambiar_password(_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    public.es_admin_global(auth.uid())
    OR auth.uid() IS NULL  -- service_role / cron
  ) THEN
    RAISE EXCEPTION 'Solo admin o service_role';
  END IF;
  UPDATE public.profiles
     SET debe_cambiar_password = false
   WHERE id = _user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_clear_debe_cambiar_password(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clear_debe_cambiar_password(uuid) TO service_role;
