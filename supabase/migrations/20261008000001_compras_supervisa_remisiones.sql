-- ============================================================================
-- Compras (supervisor y administrador) ve, captura y corrige remisiones de motocarro
-- Fecha: 2026-10-08
--
-- Síntoma: Martin (supervisor de Compras) llenaba «Nueva remisión de motocarro»
-- y al guardar salía «new row violates row-level security policy for table
-- remisiones». El INSERT sólo lo aceptaban Comercial, el admin de Dirección y
-- la allowlist individual (`rol_comercial` devolvía 'ninguno' para Compras).
--
-- Regla nueva, por ÁREA × NIVEL (no por persona): el supervisor y el
-- administrador de Compras trabajan las remisiones de motocarro como un
-- supervisor de Comercial:
--   · ven TODAS las remisiones (y sus unidades y documentos);
--   · capturan remisiones nuevas;
--   · corrigen cualquiera (con motivo en remisiones_bitacora, igual que hoy).
-- El operador de Compras no cambia. Asignar chasis y entregar siguen siendo de
-- Fábrica / Logística.
--
-- Se resuelve dentro de `puede_editar_remision()` y `puede_capturar_remision()`,
-- así que cubre las políticas ya existentes de `remisiones` y `remision_items`
-- sin tocarlas. Lo demás son políticas ADITIVAS (sólo suman acceso).
--
-- Requiere 20260902000001, 20260929000002 y 20261001000002.
--
-- Para retirarlo: DROP de las 5 políticas «compras supervisa …» de abajo y
-- volver a correr el bloque 3 de 20261001000002 (funciones sin Compras).
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := '{}';
BEGIN
  IF to_regprocedure('public.puede_editar_todas_remisiones(uuid)') IS NULL THEN _faltan := _faltan || 'función puede_editar_todas_remisiones (20261001000002)'::text; END IF;
  IF to_regprocedure('public.puede_cargar_remisiones_anteriores(uuid)') IS NULL THEN _faltan := _faltan || 'función puede_cargar_remisiones_anteriores (20261001000002)'::text; END IF;
  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN _faltan := _faltan || 'función rol_comercial (20260902000001)'::text; END IF;
  IF to_regprocedure('public.usuario_activo(uuid)') IS NULL THEN _faltan := _faltan || 'función usuario_activo (20260824000003)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                  WHERE t.typname = 'user_area' AND e.enumlabel = 'compras') THEN
    _faltan := _faltan || 'área compras en user_area (20260922000003)'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %', array_to_string(_faltan, ', ');
  END IF;
END;
$preflight$;

-- ── 1. ¿Supervisa remisiones desde Compras? ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.compras_supervisa_remisiones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT _user_id IS NOT NULL
     AND public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = _user_id
          AND ur.area::text = 'compras'
          AND ur.nivel::text IN ('supervisor', 'admin')
     );
$$;

COMMENT ON FUNCTION public.compras_supervisa_remisiones(uuid) IS
  'Supervisor o administrador de Compras (activo): ve, captura y corrige remisiones de motocarro.';

-- ── 2. Funciones de permiso (cuerpo de 20261001000002 + Compras) ────────────
CREATE OR REPLACE FUNCTION public.puede_editar_remision(
  _remision_id uuid,
  _user_id     uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _rol text;
BEGIN
  IF _remision_id IS NULL THEN RETURN false; END IF;
  _rol := public.rol_comercial(_user_id);
  IF _rol IN ('global','supervisor') THEN RETURN true; END IF;
  IF public.compras_supervisa_remisiones(_user_id) THEN RETURN true; END IF;
  IF public.puede_editar_todas_remisiones(_user_id) THEN RETURN true; END IF;
  IF public.puede_cargar_remisiones_anteriores(_user_id) AND EXISTS (
       SELECT 1 FROM public.remisiones r
        WHERE r.id = _remision_id AND r.es_anterior
     ) THEN
    RETURN true;
  END IF;
  IF _rol <> 'operador' THEN RETURN false; END IF;
  -- El operador, sólo lo que él capturó.
  RETURN EXISTS (
    SELECT 1 FROM public.remisiones r
     WHERE r.id = _remision_id AND r.vendedor_id = _user_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.puede_capturar_remision(
  _vendedor_id uuid,
  _user_id     uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.compras_supervisa_remisiones(_user_id)
      OR CASE public.rol_comercial(_user_id)
           WHEN 'global'     THEN true
           WHEN 'supervisor' THEN true
           WHEN 'operador'   THEN _vendedor_id = _user_id
                                  OR public.puede_cargar_remisiones_anteriores(_user_id)
           ELSE false
         END;
$$;

COMMENT ON FUNCTION public.puede_editar_remision(uuid, uuid) IS
  'Quién puede corregir o complementar una remisión: administrador global, supervisor/administrador de Comercial y supervisor/administrador de Compras, todas; allowlist puede_editar_remisiones, todas; allowlist puede_cargar_anteriores, las marcadas es_anterior; el operador de Comercial, las que capturó.';
COMMENT ON FUNCTION public.puede_capturar_remision(uuid, uuid) IS
  'Quién puede capturar una remisión a nombre de un vendedor: supervisor para arriba de Comercial o de Compras, o el operador con puede_cargar_anteriores; el resto de operadores de Comercial, sólo al suyo.';

REVOKE ALL ON FUNCTION public.compras_supervisa_remisiones(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_editar_remision(uuid, uuid)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.puede_capturar_remision(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compras_supervisa_remisiones(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.puede_editar_remision(uuid, uuid)   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.puede_capturar_remision(uuid, uuid) TO authenticated, service_role;

-- ── 3. Lectura: todas las remisiones y las unidades ligadas ─────────────────
-- remision_items y remisiones_bitacora siguen a la visibilidad de la remisión.
DROP POLICY IF EXISTS "compras supervisa remisiones lectura" ON public.remisiones;
CREATE POLICY "compras supervisa remisiones lectura" ON public.remisiones
  FOR SELECT TO authenticated
  USING (public.compras_supervisa_remisiones(auth.uid()));

DROP POLICY IF EXISTS "compras supervisa motocarros de remisiones" ON public.motocarros;
CREATE POLICY "compras supervisa motocarros de remisiones" ON public.motocarros
  FOR SELECT TO authenticated
  USING (remision_id IS NOT NULL AND public.compras_supervisa_remisiones(auth.uid()));

-- ── 4. Captura: INSERT explícito (además del que ya pasa por puede_capturar) ─
DROP POLICY IF EXISTS "compras supervisa remisiones captura" ON public.remisiones;
CREATE POLICY "compras supervisa remisiones captura" ON public.remisiones
  FOR INSERT TO authenticated
  WITH CHECK (public.compras_supervisa_remisiones(auth.uid()));

-- ── 5. PDF de la remisión (bucket remisiones-docs) ──────────────────────────
DROP POLICY IF EXISTS "compras supervisa docs remisiones leer" ON storage.objects;
CREATE POLICY "compras supervisa docs remisiones leer" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'remisiones-docs' AND public.compras_supervisa_remisiones(auth.uid()));

DROP POLICY IF EXISTS "compras supervisa docs remisiones subir" ON storage.objects;
CREATE POLICY "compras supervisa docs remisiones subir" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'remisiones-docs' AND public.compras_supervisa_remisiones(auth.uid()));

NOTIFY pgrst, 'reload schema';

-- ── Verificación: quién queda con el permiso ────────────────────────────────
SELECT u.email, ur.area::text AS area, ur.nivel::text AS nivel,
       public.compras_supervisa_remisiones(u.id) AS supervisa_remisiones_desde_compras,
       public.puede_capturar_remision(u.id, u.id) AS puede_capturar
  FROM public.user_roles ur
  JOIN auth.users u ON u.id = ur.user_id
 WHERE ur.area::text = 'compras'
 ORDER BY ur.nivel::text, u.email;
