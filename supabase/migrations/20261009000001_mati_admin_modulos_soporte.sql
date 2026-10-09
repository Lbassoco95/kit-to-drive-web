-- ============================================================================
-- MATI Admin ↔ Kit-to-Drive: módulos encendibles, soporte y bitácora del puente
--
-- Agrega SOLO tablas nuevas; no toca ninguna tabla, función ni política
-- existente. Es idempotente (se puede correr más de una vez).
--
--   app_modulos        — qué módulos del front están encendidos. Todos nacen
--                        ENCENDIDOS: aplicar este script no cambia nada hasta
--                        que alguien apague uno desde MATI Admin.
--   soporte_tickets    — tickets que levantan los usuarios desde la app.
--   soporte_mensajes   — conversación de cada ticket.
--   bridge_bitacora    — quién hizo qué a través de mati-admin-bridge.
--
-- OJO: apagar un módulo sólo lo oculta/bloquea en la interfaz. NO es una
-- barrera de seguridad: los permisos reales siguen siendo RLS por área/nivel.
-- ============================================================================

-- ── Módulos ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.app_modulos (
  clave           text PRIMARY KEY,
  nombre          text NOT NULL,
  activo          boolean NOT NULL DEFAULT true,
  -- Módulos que no se pueden apagar (apagarlos dejaría a todos sin acceso).
  protegido       boolean NOT NULL DEFAULT false,
  actualizado_at  timestamptz NOT NULL DEFAULT now(),
  actualizado_por text
);

INSERT INTO public.app_modulos (clave, nombre, protegido) VALUES
  ('dashboard',              'Inicio',                         true),
  ('usuarios',               'Usuarios',                       true),
  ('configuracion',          'Configuración',                  true),
  ('tareas',                 'Tareas',                         false),
  ('produccion',             'Producción',                     false),
  ('inventario',             'Inventario',                     false),
  ('reportesTurno',          'Reportes de turno',              false),
  ('remisiones',             'Remisiones',                     false),
  ('entregas',               'Entregas',                       false),
  ('misMotocarros',          'Mis motocarros',                 false),
  ('clientes',               'Clientes',                       false),
  ('crm',                    'CRM',                            false),
  ('crmEquipo',              'CRM · equipo',                   false),
  ('finanzas',               'Finanzas',                       false),
  ('credito',                'Crédito',                        false),
  ('proveedores',            'Proveedores',                    false),
  ('importar',               'Importar',                       false),
  ('bitacora',               'Bitácora',                       false),
  ('compras',                'Compras',                        false),
  ('inventarioFisico',       'Ajustes de inventario',          false),
  ('kardex',                 'Kardex',                         false),
  ('cobranza',               'Cobranza',                       false),
  ('reportesCompras',        'Reportes de compras',            false),
  ('almacenRefacciones',     'Almacén de refacciones',         false),
  ('remisionesRefacciones',  'Remisiones de refacciones',      false)
ON CONFLICT (clave) DO NOTHING;

ALTER TABLE public.app_modulos ENABLE ROW LEVEL SECURITY;

-- Los usuarios activos LEEN el estado de los módulos; sólo el puente (service
-- role) escribe.
DROP POLICY IF EXISTS "leer modulos activos" ON public.app_modulos;
CREATE POLICY "leer modulos activos" ON public.app_modulos
  FOR SELECT TO authenticated
  USING (public.usuario_activo(auth.uid()));

REVOKE ALL ON public.app_modulos FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.app_modulos FROM authenticated;

-- ── Soporte ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.soporte_tickets (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asunto             text NOT NULL CHECK (char_length(asunto) BETWEEN 3 AND 200),
  descripcion        text CHECK (descripcion IS NULL OR char_length(descripcion) <= 5000),
  estado             text NOT NULL DEFAULT 'abierto'
                     CHECK (estado IN ('abierto', 'en_progreso', 'resuelto', 'cerrado')),
  prioridad          text NOT NULL DEFAULT 'media'
                     CHECK (prioridad IN ('baja', 'media', 'alta', 'urgente')),
  modulo             text,
  creado_por         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  creado_por_nombre  text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_soporte_tickets_estado ON public.soporte_tickets (estado, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_soporte_tickets_creado_por ON public.soporte_tickets (creado_por);

CREATE TABLE IF NOT EXISTS public.soporte_mensajes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id     uuid NOT NULL REFERENCES public.soporte_tickets(id) ON DELETE CASCADE,
  autor_tipo    text NOT NULL CHECK (autor_tipo IN ('usuario', 'soporte')),
  autor_id      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  autor_nombre  text,
  mensaje       text NOT NULL CHECK (char_length(mensaje) BETWEEN 1 AND 5000),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_soporte_mensajes_ticket ON public.soporte_mensajes (ticket_id, created_at);

ALTER TABLE public.soporte_tickets  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.soporte_mensajes ENABLE ROW LEVEL SECURITY;

-- Cada quien ve SUS tickets; el admin global (Dirección) ve todos.
DROP POLICY IF EXISTS "ver tickets propios" ON public.soporte_tickets;
CREATE POLICY "ver tickets propios" ON public.soporte_tickets
  FOR SELECT TO authenticated
  USING (creado_por = auth.uid() OR public.es_admin_global(auth.uid()));

DROP POLICY IF EXISTS "crear ticket propio" ON public.soporte_tickets;
CREATE POLICY "crear ticket propio" ON public.soporte_tickets
  FOR INSERT TO authenticated
  WITH CHECK (creado_por = auth.uid() AND public.usuario_activo(auth.uid())
              AND estado = 'abierto');

DROP POLICY IF EXISTS "ver mensajes de mis tickets" ON public.soporte_mensajes;
CREATE POLICY "ver mensajes de mis tickets" ON public.soporte_mensajes
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.soporte_tickets t
                  WHERE t.id = soporte_mensajes.ticket_id
                    AND (t.creado_por = auth.uid() OR public.es_admin_global(auth.uid()))));

-- El usuario sólo puede responder en SU ticket y como 'usuario'. Las
-- respuestas de soporte las escribe el puente con service role.
DROP POLICY IF EXISTS "responder en mi ticket" ON public.soporte_mensajes;
CREATE POLICY "responder en mi ticket" ON public.soporte_mensajes
  FOR INSERT TO authenticated
  WITH CHECK (autor_tipo = 'usuario'
              AND autor_id = auth.uid()
              AND EXISTS (SELECT 1 FROM public.soporte_tickets t
                           WHERE t.id = soporte_mensajes.ticket_id
                             AND t.creado_por = auth.uid()));

REVOKE ALL ON public.soporte_tickets, public.soporte_mensajes FROM anon;
REVOKE UPDATE, DELETE, TRUNCATE ON public.soporte_tickets, public.soporte_mensajes FROM authenticated;

-- ── Bitácora del puente ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.bridge_bitacora (
  id       bigserial PRIMARY KEY,
  at       timestamptz NOT NULL DEFAULT now(),
  accion   text NOT NULL,
  objetivo text,
  detalle  jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_bridge_bitacora_at ON public.bridge_bitacora (at DESC);

-- Sin políticas: sólo el service role escribe y lee.
ALTER TABLE public.bridge_bitacora ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bridge_bitacora FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.bridge_bitacora_id_seq FROM anon, authenticated;
