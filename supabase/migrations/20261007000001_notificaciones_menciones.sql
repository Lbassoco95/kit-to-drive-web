-- ============================================================================
-- Notificaciones personales: menciones (@) en comentarios
-- Fecha: 2026-10-07
--
-- `avisos` es de área a área. Una mención es de persona a persona: sólo la ve
-- quien fue mencionado. Idempotente, para el SQL editor de Supabase.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.notificaciones (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_destino  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tipo             TEXT NOT NULL DEFAULT 'mencion',
  titulo           TEXT NOT NULL,
  cuerpo           TEXT,
  enlace           TEXT,
  creado_por       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  nombre_creador   TEXT,
  leido_at         TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notificaciones_usuario
  ON public.notificaciones (usuario_destino, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notificaciones_sin_leer
  ON public.notificaciones (usuario_destino) WHERE leido_at IS NULL;

ALTER TABLE public.notificaciones ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.notificaciones TO authenticated;

DROP POLICY IF EXISTS "leer mis notificaciones" ON public.notificaciones;
CREATE POLICY "leer mis notificaciones" ON public.notificaciones
  FOR SELECT TO authenticated USING (usuario_destino = auth.uid());

-- Cualquiera puede mencionar a otro, firmando con su propio usuario.
DROP POLICY IF EXISTS "mencionar usuario" ON public.notificaciones;
CREATE POLICY "mencionar usuario" ON public.notificaciones
  FOR INSERT TO authenticated WITH CHECK (creado_por = auth.uid());

DROP POLICY IF EXISTS "marcar mi notificacion leida" ON public.notificaciones;
CREATE POLICY "marcar mi notificacion leida" ON public.notificaciones
  FOR UPDATE TO authenticated
  USING (usuario_destino = auth.uid()) WITH CHECK (usuario_destino = auth.uid());

-- Sólo se puede cambiar `leido_at`; el contenido queda como se mandó.
CREATE OR REPLACE FUNCTION public.trg_notificaciones_solo_leida()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.usuario_destino := OLD.usuario_destino;
  NEW.tipo            := OLD.tipo;
  NEW.titulo          := OLD.titulo;
  NEW.cuerpo          := OLD.cuerpo;
  NEW.enlace          := OLD.enlace;
  NEW.creado_por      := OLD.creado_por;
  NEW.nombre_creador  := OLD.nombre_creador;
  NEW.created_at      := OLD.created_at;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_notificaciones_solo_leida ON public.notificaciones;
CREATE TRIGGER trg_notificaciones_solo_leida
  BEFORE UPDATE ON public.notificaciones
  FOR EACH ROW EXECUTE FUNCTION public.trg_notificaciones_solo_leida();

-- Para que la campana se actualice sola.
DO $rt$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.notificaciones;
EXCEPTION WHEN OTHERS THEN NULL;
END $rt$;
