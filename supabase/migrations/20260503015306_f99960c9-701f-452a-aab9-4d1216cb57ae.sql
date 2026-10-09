
-- Roles enum y tabla separada (anti-escalación)
CREATE TYPE public.app_role AS ENUM ('admin','fabrica','logistica','ventas');
CREATE TYPE public.estatus_armado AS ENUM ('PENDIENTE','EN_PROCESO','ARMADO','LISTO','ATRASADO');
CREATE TYPE public.estatus_entrega AS ENUM ('NO_APLICA','PROGRAMADA','EN_RUTA','ENTREGADA');
CREATE TYPE public.estatus_remision AS ENUM ('NUEVA','PARCIAL','COMPLETA','CANCELADA');

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS app_role LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT role FROM public.user_roles WHERE user_id = auth.uid() ORDER BY 
    CASE role WHEN 'admin' THEN 1 WHEN 'fabrica' THEN 2 WHEN 'logistica' THEN 3 WHEN 'ventas' THEN 4 END
  LIMIT 1
$$;

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre_completo TEXT NOT NULL DEFAULT '',
  codigo_vendedor TEXT UNIQUE,
  activo BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.clientes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo_erp TEXT NOT NULL UNIQUE,
  nombre_comercial TEXT,
  telefono TEXT,
  direccion TEXT,
  activo BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.contenedores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  folio_contenedor TEXT NOT NULL UNIQUE,
  fecha_arribo DATE,
  total_unidades INTEGER NOT NULL DEFAULT 0,
  modelo_default TEXT,
  notas TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.contenedores ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.remisiones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  folio_remision TEXT NOT NULL UNIQUE,
  vendedor_id UUID REFERENCES public.profiles(id),
  cliente_id UUID REFERENCES public.clientes(id),
  fecha_remision DATE,
  total_unidades_solicitadas INTEGER NOT NULL DEFAULT 1,
  modelo_solicitado TEXT,
  color_solicitado TEXT,
  notas TEXT,
  documento_url TEXT,
  estatus estatus_remision NOT NULL DEFAULT 'NUEVA',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.remisiones ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.motocarros (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contenedor_id UUID REFERENCES public.contenedores(id),
  orden_armado INTEGER NOT NULL UNIQUE,
  modelo TEXT NOT NULL DEFAULT '200cc 2025',
  color TEXT NOT NULL DEFAULT 'BLANCO',
  chasis_asignado TEXT UNIQUE,
  ns_chasis TEXT UNIQUE,
  ns_motor TEXT UNIQUE,
  fecha_estimada_armado DATE,
  fecha_real_armado DATE,
  estatus_armado estatus_armado NOT NULL DEFAULT 'PENDIENTE',
  observaciones_paro TEXT,
  remision_id UUID REFERENCES public.remisiones(id) ON DELETE SET NULL,
  fecha_estimada_entrega DATE,
  fecha_real_entrega DATE,
  estatus_entrega estatus_entrega NOT NULL DEFAULT 'NO_APLICA',
  evidencia_entrega_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.motocarros ENABLE ROW LEVEL SECURITY;
CREATE INDEX idx_motocarros_remision ON public.motocarros(remision_id);
CREATE INDEX idx_motocarros_estatus ON public.motocarros(estatus_armado);

CREATE TABLE public.bitacora_eventos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID REFERENCES auth.users(id),
  modulo TEXT,
  accion TEXT,
  entidad_tipo TEXT,
  entidad_id UUID,
  datos_antes JSONB,
  datos_despues JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.bitacora_eventos ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.config_general (
  id INTEGER PRIMARY KEY DEFAULT 1,
  capacidad_diaria INTEGER NOT NULL DEFAULT 4,
  plazo_max_credito_dias INTEGER NOT NULL DEFAULT 60,
  empresa_nombre TEXT NOT NULL DEFAULT 'Grupo Dazon',
  empresa_logo_url TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (id = 1)
);
ALTER TABLE public.config_general ENABLE ROW LEVEL SECURITY;
INSERT INTO public.config_general (id) VALUES (1);

-- Trigger para crear profile automáticamente
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, nombre_completo)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'nombre_completo', NEW.email));
  RETURN NEW;
END; $$;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_clientes_updated BEFORE UPDATE ON public.clientes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_motocarros_updated BEFORE UPDATE ON public.motocarros FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_remisiones_updated BEFORE UPDATE ON public.remisiones FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============ RLS POLICIES ============

-- user_roles: solo admin gestiona, todos pueden leer su propio rol
CREATE POLICY "leer roles propios" ON public.user_roles FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "admin gestiona roles" ON public.user_roles FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- profiles
CREATE POLICY "leer profiles autenticados" ON public.profiles FOR SELECT TO authenticated USING (true);
CREATE POLICY "actualizar mi profile" ON public.profiles FOR UPDATE TO authenticated USING (id = auth.uid() OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin inserta profiles" ON public.profiles FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR id = auth.uid());

-- clientes
CREATE POLICY "leer clientes" ON public.clientes FOR SELECT TO authenticated USING (true);
CREATE POLICY "escribir clientes admin/fabrica/ventas" ON public.clientes FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica') OR public.has_role(auth.uid(),'ventas'));
CREATE POLICY "actualizar clientes admin/fabrica" ON public.clientes FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "borrar clientes admin" ON public.clientes FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- contenedores
CREATE POLICY "leer contenedores" ON public.contenedores FOR SELECT TO authenticated USING (true);
CREATE POLICY "escribir contenedores admin/fabrica" ON public.contenedores FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "actualizar contenedores admin/fabrica" ON public.contenedores FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
CREATE POLICY "borrar contenedores admin" ON public.contenedores FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- remisiones
CREATE POLICY "leer remisiones por rol" ON public.remisiones FOR SELECT TO authenticated USING (
  public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica') OR public.has_role(auth.uid(),'logistica')
  OR vendedor_id = auth.uid()
);
CREATE POLICY "crear remisiones" ON public.remisiones FOR INSERT TO authenticated WITH CHECK (
  public.has_role(auth.uid(),'admin') OR (public.has_role(auth.uid(),'ventas') AND vendedor_id = auth.uid())
);
CREATE POLICY "actualizar remisiones" ON public.remisiones FOR UPDATE TO authenticated USING (
  public.has_role(auth.uid(),'admin') OR vendedor_id = auth.uid()
);
CREATE POLICY "borrar remisiones admin" ON public.remisiones FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- motocarros
CREATE POLICY "leer motocarros por rol" ON public.motocarros FOR SELECT TO authenticated USING (
  public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica') OR public.has_role(auth.uid(),'logistica')
  OR (remision_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = remision_id AND r.vendedor_id = auth.uid()))
);
CREATE POLICY "crear motocarros admin/fabrica" ON public.motocarros FOR INSERT TO authenticated WITH CHECK (
  public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica')
);
CREATE POLICY "actualizar motocarros operativos" ON public.motocarros FOR UPDATE TO authenticated USING (
  public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica') OR public.has_role(auth.uid(),'logistica')
);
CREATE POLICY "borrar motocarros admin" ON public.motocarros FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- bitacora
CREATE POLICY "leer bitacora admin" ON public.bitacora_eventos FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));
CREATE POLICY "insertar bitacora autenticados" ON public.bitacora_eventos FOR INSERT TO authenticated WITH CHECK (usuario_id = auth.uid());

-- config_general
CREATE POLICY "leer config" ON public.config_general FOR SELECT TO authenticated USING (true);
CREATE POLICY "actualizar config admin" ON public.config_general FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin'));
