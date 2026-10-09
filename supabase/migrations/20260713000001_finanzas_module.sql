-- ============================================================
-- Sprint Finanzas — Módulo de control de pagos e ingresos
-- 2026-07-13
-- ============================================================

-- 1. Extend app_role enum with finanzas roles
ALTER TYPE app_role ADD VALUE IF NOT EXISTS 'finanzas';
ALTER TYPE app_role ADD VALUE IF NOT EXISTS 'admin_financiero';

-- 2. Create pagos table
CREATE TABLE IF NOT EXISTS public.pagos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre_pago     text NOT NULL,
  beneficiario    text NOT NULL,
  monto           numeric(18,2) NOT NULL CHECK (monto >= 0),
  moneda          text NOT NULL DEFAULT 'MXN',
  tiene_factura   boolean NOT NULL DEFAULT false,
  factura_url     text,
  aprobado_por    text,
  descripcion     text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- 3. Auto-update updated_at
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pagos_set_updated_at ON public.pagos;
CREATE TRIGGER pagos_set_updated_at
  BEFORE UPDATE ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 4. RLS
ALTER TABLE public.pagos ENABLE ROW LEVEL SECURITY;

-- admin: full access
CREATE POLICY "pagos_admin_all" ON public.pagos
  FOR ALL USING (has_role(auth.uid(), 'admin'::app_role));

-- admin_financiero: full access
CREATE POLICY "pagos_admin_financiero_all" ON public.pagos
  FOR ALL USING (has_role(auth.uid(), 'admin_financiero'::app_role));

-- finanzas: select all + insert/update own
CREATE POLICY "pagos_finanzas_select" ON public.pagos
  FOR SELECT USING (has_role(auth.uid(), 'finanzas'::app_role));

CREATE POLICY "pagos_finanzas_insert" ON public.pagos
  FOR INSERT WITH CHECK (
    has_role(auth.uid(), 'finanzas'::app_role)
    AND created_by = auth.uid()
  );

CREATE POLICY "pagos_finanzas_update" ON public.pagos
  FOR UPDATE USING (
    has_role(auth.uid(), 'finanzas'::app_role)
    AND created_by = auth.uid()
  );

-- 5. Storage bucket for facturas
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'facturas',
  'facturas',
  false,
  10485760,  -- 10 MB
  ARRAY['application/pdf','image/jpeg','image/png','image/webp','image/heic','image/heif']
)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for facturas bucket
CREATE POLICY "facturas_upload_finanzas" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'facturas'
    AND (
      has_role(auth.uid(), 'finanzas'::app_role)
      OR has_role(auth.uid(), 'admin_financiero'::app_role)
      OR has_role(auth.uid(), 'admin'::app_role)
    )
  );

CREATE POLICY "facturas_select_finanzas" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'facturas'
    AND (
      has_role(auth.uid(), 'finanzas'::app_role)
      OR has_role(auth.uid(), 'admin_financiero'::app_role)
      OR has_role(auth.uid(), 'admin'::app_role)
    )
  );

CREATE POLICY "facturas_update_finanzas" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'facturas'
    AND (
      has_role(auth.uid(), 'admin_financiero'::app_role)
      OR has_role(auth.uid(), 'admin'::app_role)
    )
  );

CREATE POLICY "facturas_delete_finanzas" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'facturas'
    AND (
      has_role(auth.uid(), 'admin_financiero'::app_role)
      OR has_role(auth.uid(), 'admin'::app_role)
    )
  );
