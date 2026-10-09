-- El vendedor solo ve SU información · parte 2/3: clientes, comentarios, documentos y crédito
-- Ver 20261007000001 (parte 1) para el contexto completo. Correr en orden 1, 2, 3.

-- ── 4. clientes ────────────────────────────────────────────────────────────
-- Vendedor: los que tiene asignados + los de sus propias remisiones.
DROP POLICY IF EXISTS "leer clientes" ON public.clientes;
CREATE POLICY "leer clientes" ON public.clientes
FOR SELECT TO authenticated
USING (
  public.es_admin_global(auth.uid())
  OR public.ve_todo_comercial(auth.uid())
  OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
  OR public.es_area(auth.uid(), 'almacen_logistica'::public.user_area)
  OR public.es_area(auth.uid(), 'administracion'::public.user_area)
  OR public.es_area(auth.uid(), 'compras'::public.user_area)
  OR public.es_area(auth.uid(), 'direccion'::public.user_area)
  OR public.has_role(auth.uid(), 'admin'::app_role)
  OR public.has_role(auth.uid(), 'fabrica'::app_role)
  OR public.has_role(auth.uid(), 'logistica'::app_role)
  OR public.has_role(auth.uid(), 'coordinador'::app_role)
  OR public.has_role(auth.uid(), 'finanzas'::app_role)
  OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
  OR public.has_role(auth.uid(), 'compras'::app_role)
  OR (
    (public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.has_role(auth.uid(), 'ventas'::app_role))
    AND public.usuario_activo(auth.uid())
    AND (
      vendedor_id = auth.uid()
      OR EXISTS (SELECT 1 FROM public.remisiones r
                  WHERE r.cliente_id = clientes.id AND r.vendedor_id = auth.uid())
    )
  )
);

-- Comentarios y bitácora del cliente: solo si ves al cliente.
DROP POLICY IF EXISTS "Usuarios autenticados pueden ver comentarios" ON public.clientes_comentarios;
DROP POLICY IF EXISTS "clientes_comentarios_select" ON public.clientes_comentarios;
CREATE POLICY "clientes_comentarios_select" ON public.clientes_comentarios
FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = clientes_comentarios.cliente_id));

DROP POLICY IF EXISTS "Usuarios autenticados pueden ver bitácora" ON public.clientes_bitacora;
DROP POLICY IF EXISTS "clientes_bitacora_select" ON public.clientes_bitacora;
CREATE POLICY "clientes_bitacora_select" ON public.clientes_bitacora
FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = clientes_bitacora.cliente_id));

-- Documentos del cliente (storage, ruta = cliente_id/…)
DROP POLICY IF EXISTS "clientes_docs_select" ON storage.objects;
CREATE POLICY "clientes_docs_select" ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'clientes-docs'
  AND public.usuario_activo(auth.uid())
  AND (
    public.es_admin_global(auth.uid())
    OR public.ve_todo_comercial(auth.uid())
    OR public.es_area(auth.uid(), 'administracion'::public.user_area)
    OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
    OR public.has_role(auth.uid(), 'admin'::app_role)
    OR public.has_role(auth.uid(), 'coordinador'::app_role)
    OR public.has_role(auth.uid(), 'finanzas'::app_role)
    OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
    OR (
      (public.es_area(auth.uid(), 'comercial'::public.user_area)
        OR public.has_role(auth.uid(), 'ventas'::app_role))
      AND EXISTS (SELECT 1 FROM public.clientes c
                   WHERE c.id::text = (storage.foldername(name))[1])   -- RLS de clientes
    )
  )
);

-- ── 5. Crédito / cartera: solo de los clientes que ves ─────────────────────
ALTER VIEW public.v_clientes_credito SET (security_invoker = true);

DROP POLICY IF EXISTS cxc_select ON public.cuentas_por_cobrar;
CREATE POLICY cxc_select ON public.cuentas_por_cobrar
FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.clientes c WHERE c.id = cuentas_por_cobrar.cliente_id));

DROP POLICY IF EXISTS cxc_abonos_select ON public.cxc_abonos;
CREATE POLICY cxc_abonos_select ON public.cxc_abonos
FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.cuentas_por_cobrar x WHERE x.id = cxc_abonos.cxc_id));
