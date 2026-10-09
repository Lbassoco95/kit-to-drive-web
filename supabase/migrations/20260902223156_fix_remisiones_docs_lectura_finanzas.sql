-- ============================================================
-- Fix: usuarios de Finanzas no pueden ver/descargar los PDFs
-- de remisiones almacenados en el bucket `remisiones-docs`.
-- ============================================================

-- Recrea la política de lectura incluyendo todos los roles operativos
-- que tienen visibilidad de remisiones, en especial finanzas/admin_financiero.
DROP POLICY IF EXISTS "leer docs remisiones operativos" ON storage.objects;

CREATE POLICY "leer docs remisiones operativos"
ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'remisiones-docs'
  AND (
    public.has_role(auth.uid(), 'admin'::app_role)
    OR public.has_role(auth.uid(), 'fabrica'::app_role)
    OR public.has_role(auth.uid(), 'logistica'::app_role)
    OR public.has_role(auth.uid(), 'coordinador'::app_role)
    OR public.has_role(auth.uid(), 'ventas'::app_role)
    OR public.has_role(auth.uid(), 'director_ventas'::app_role)
    OR public.has_role(auth.uid(), 'coordinador_ventas'::app_role)
    OR public.has_role(auth.uid(), 'auxiliar_ventas'::app_role)
    OR public.has_role(auth.uid(), 'finanzas'::app_role)
    OR public.has_role(auth.uid(), 'admin_financiero'::app_role)
  )
);
