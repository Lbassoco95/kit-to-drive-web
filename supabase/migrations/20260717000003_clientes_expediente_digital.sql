-- Migration: Expandir tabla clientes para expediente digital
-- Fecha: 2026-07-17

-- Datos de identidad
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS razon_social text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS rfc text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS email_cobranza text;

-- Contacto adicional
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS nombre_contacto text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS cargo_contacto text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS telefono_contacto text;

-- Dirección fiscal (separada de la de entrega)
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS calle text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS num_exterior text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS num_interior text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS colonia text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS municipio text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS estado text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS codigo_postal text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS pais text NOT NULL DEFAULT 'México';

-- Crédito / condiciones comerciales
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS limite_credito numeric(18,2);
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS dias_credito integer DEFAULT 0;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS moneda_credito text DEFAULT 'MXN';

-- Documentos digitales (URLs a Supabase Storage)
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS doc_constancia_sf_url text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS doc_comprobante_domicilio_url text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS doc_ine_representante_url text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS doc_acta_constitutiva_url text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS doc_poder_notarial_url text;

-- Control
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS vendedor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS notas text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS fecha_alta date DEFAULT CURRENT_DATE;

-- Actualizar RLS policies para clientes con nuevos roles
DROP POLICY IF EXISTS "leer clientes" ON public.clientes;
DROP POLICY IF EXISTS "escribir clientes admin/fabrica/ventas" ON public.clientes;
DROP POLICY IF EXISTS "actualizar clientes admin/fabrica" ON public.clientes;
DROP POLICY IF EXISTS "borrar clientes admin" ON public.clientes;
-- Faltaban las dos que este mismo archivo vuelve a crear más abajo: sin estos
-- DROP, la corrida fallaba con «policy "actualizar clientes" already exists» y
-- el SQL editor —que manda todo en una transacción— revertía también las
-- columnas del expediente que están arriba.
DROP POLICY IF EXISTS "crear clientes" ON public.clientes;
DROP POLICY IF EXISTS "actualizar clientes" ON public.clientes;

CREATE POLICY "leer clientes" ON public.clientes FOR SELECT TO authenticated USING (true);

CREATE POLICY "crear clientes" ON public.clientes FOR INSERT TO authenticated WITH CHECK (
  public.has_role(auth.uid(),'admin') OR 
  public.has_role(auth.uid(),'director_ventas') OR 
  public.has_role(auth.uid(),'coordinador_ventas') OR 
  public.has_role(auth.uid(),'ventas') OR 
  public.has_role(auth.uid(),'auxiliar_ventas')
);

CREATE POLICY "actualizar clientes" ON public.clientes FOR UPDATE TO authenticated USING (
  public.has_role(auth.uid(),'admin') OR 
  public.has_role(auth.uid(),'director_ventas') OR 
  public.has_role(auth.uid(),'coordinador_ventas') OR
  (vendedor_id = auth.uid() AND (public.has_role(auth.uid(),'ventas') OR public.has_role(auth.uid(),'auxiliar_ventas')))
);

CREATE POLICY "borrar clientes admin" ON public.clientes FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- Comentario: Crear bucket de Storage en Supabase Dashboard → Storage → New bucket: "clientes-docs", private
-- Ruta de documentos: clientes-docs/{cliente_id}/{tipo_doc}
