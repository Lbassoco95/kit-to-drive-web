-- Enum
ALTER TYPE app_role ADD VALUE IF NOT EXISTS 'director_ventas';
ALTER TYPE app_role ADD VALUE IF NOT EXISTS 'coordinador_ventas';
ALTER TYPE app_role ADD VALUE IF NOT EXISTS 'auxiliar_ventas';

-- Helpers para RLS
-- "puede_ver_equipo": coordinador, auxiliar y director ven todos los vendedores
-- "puede_editar": ventas/coordinador/auxiliar pueden insertar/actualizar
-- "puede_eliminar": solo coordinador y admin

-- Tabla oportunidades
CREATE TABLE public.crm_oportunidades (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id            uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  vendedor_id           uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  tipo                  text NOT NULL DEFAULT 'motocarro'
                          CHECK (tipo IN ('motocarro','refaccion','otro')),
  cantidad_estimada     int,
  monto_estimado        numeric(18,2),
  etapa                 text NOT NULL DEFAULT 'prospecto'
                          CHECK (etapa IN ('prospecto','contacto','cotizacion','negociacion','ganado','perdido')),
  fecha_estimada_cierre date,
  notas                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.crm_oportunidades ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER crm_oport_updated BEFORE UPDATE ON public.crm_oportunidades
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Tabla actividades
CREATE TABLE public.crm_actividades (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendedor_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  oportunidad_id uuid REFERENCES public.crm_oportunidades(id) ON DELETE SET NULL,
  cliente_id     uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  tipo           text NOT NULL DEFAULT 'visita'
                   CHECK (tipo IN ('visita','llamada','demo','seguimiento','cotizacion')),
  fecha          timestamptz NOT NULL DEFAULT now(),
  resultado      text,
  notas          text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.crm_actividades ENABLE ROW LEVEL SECURITY;

-- Tabla rutas
CREATE TABLE public.crm_rutas (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendedor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  fecha       date NOT NULL,
  notas       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.crm_rutas ENABLE ROW LEVEL SECURITY;

-- Tabla paradas
CREATE TABLE public.crm_ruta_paradas (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ruta_id        uuid NOT NULL REFERENCES public.crm_rutas(id) ON DELETE CASCADE,
  orden          int NOT NULL DEFAULT 1,
  cliente_id     uuid REFERENCES public.clientes(id) ON DELETE SET NULL,
  descripcion    text,
  hora_estimada  time,
  hora_real      time,
  completada     boolean NOT NULL DEFAULT false,
  notas          text
);
ALTER TABLE public.crm_ruta_paradas ENABLE ROW LEVEL SECURITY;

-- RLS oportunidades
CREATE POLICY "crm_oport_select" ON public.crm_oportunidades FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'director_ventas'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  vendedor_id = auth.uid()
);
CREATE POLICY "crm_oport_insert" ON public.crm_oportunidades FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  has_role(auth.uid(),'ventas'::app_role)
);
CREATE POLICY "crm_oport_update" ON public.crm_oportunidades FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  vendedor_id = auth.uid()
);
CREATE POLICY "crm_oport_delete" ON public.crm_oportunidades FOR DELETE USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role)
);

-- RLS actividades
CREATE POLICY "crm_act_select" ON public.crm_actividades FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'director_ventas'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  vendedor_id = auth.uid()
);
CREATE POLICY "crm_act_insert" ON public.crm_actividades FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  has_role(auth.uid(),'ventas'::app_role)
);
CREATE POLICY "crm_act_update" ON public.crm_actividades FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  vendedor_id = auth.uid()
);
CREATE POLICY "crm_act_delete" ON public.crm_actividades FOR DELETE USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role)
);

-- RLS rutas
CREATE POLICY "crm_rutas_select" ON public.crm_rutas FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'director_ventas'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  vendedor_id = auth.uid()
);
CREATE POLICY "crm_rutas_insert" ON public.crm_rutas FOR INSERT WITH CHECK (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  has_role(auth.uid(),'ventas'::app_role)
);
CREATE POLICY "crm_rutas_update" ON public.crm_rutas FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role) OR
  has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
  vendedor_id = auth.uid()
);
CREATE POLICY "crm_rutas_delete" ON public.crm_rutas FOR DELETE USING (
  has_role(auth.uid(),'admin'::app_role) OR
  has_role(auth.uid(),'coordinador_ventas'::app_role)
);

-- RLS paradas (hereda de ruta)
CREATE POLICY "crm_paradas_all" ON public.crm_ruta_paradas FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.crm_rutas r WHERE r.id = ruta_id AND (
      has_role(auth.uid(),'admin'::app_role) OR
      has_role(auth.uid(),'director_ventas'::app_role) OR
      has_role(auth.uid(),'coordinador_ventas'::app_role) OR
      has_role(auth.uid(),'auxiliar_ventas'::app_role) OR
      r.vendedor_id = auth.uid()
    )
  )
);
