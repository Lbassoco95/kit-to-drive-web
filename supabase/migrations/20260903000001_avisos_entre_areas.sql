-- ============================================================================
-- Avisos entre áreas, y liberar unidades sin frenar a Comercial
-- Fecha: 2026-09-03
--
-- Qué estaba pasando
-- ------------------
-- Al abrir la edición de remisiones (20260902000001) se puso un candado: si la
-- remisión ya tenía chasis asignados, no se podía bajar el total. La idea era
-- no dejar unidades huérfanas, pero el efecto real es que Fábrica frena a
-- Ventas — y para Fábrica el cambio es indistinto: la unidad simplemente
-- regresa al inventario y se va a otra orden.
--
-- Lo que se necesita no es un candado, es un aviso.
--
-- Qué queda
-- ---------
--  1. `avisos`: mensajes de un área a otra, con acuse («visto»). No existía
--     ningún canal entre áreas; los pendientes se descubrían de casualidad.
--  2. `ajustar_unidades_remision()`: baja el total de una remisión liberando
--     las unidades sobrantes y dejando el aviso a Fábrica y a Logística. La
--     puede llamar quien puede editar la remisión — Comercial incluido —, no
--     sólo Fábrica como `desasignar_motocarro_de_remision`.
--
-- El único piso que queda: no se puede bajar por debajo de las unidades ya
-- ENTREGADAS o EN_RUTA. Eso no es burocracia, es que el motocarro ya se fue.
--
-- Qué se libera primero: lo menos avanzado. Una unidad que todavía no se arma
-- cuesta menos de devolver al inventario que una ya terminada.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.remisiones')  IS NULL THEN _faltan := _faltan || 'tabla remisiones'::text;  END IF;
  IF to_regclass('public.motocarros')  IS NULL THEN _faltan := _faltan || 'tabla motocarros'::text;  END IF;
  IF to_regtype('public.user_area')    IS NULL THEN _faltan := _faltan || 'tipo user_area'::text;    END IF;
  IF to_regprocedure('public.puede_editar_remision(uuid,uuid)') IS NULL THEN
    _faltan := _faltan || 'puede_editar_remision() (corre antes 20260902000001_operador_edita_remisiones.sql)'::text;
  END IF;

  IF array_length(_faltan,1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %.', array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;


-- ============================================================================
-- BLOQUE 1 · Avisos entre áreas
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.avisos (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_destino   public.user_area NOT NULL,
  tipo           TEXT NOT NULL DEFAULT 'general',
  titulo         TEXT NOT NULL,
  cuerpo         TEXT,
  -- A qué se refiere el aviso, para poder ir directo desde la bandeja.
  remision_id    UUID REFERENCES public.remisiones(id) ON DELETE CASCADE,
  folio_remision TEXT,
  datos          JSONB,
  creado_por     UUID REFERENCES auth.users(id),
  nombre_creador TEXT,
  -- Acuse: quién lo dio por visto y cuándo. NULL = pendiente.
  visto_por      UUID REFERENCES auth.users(id),
  visto_at       TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_avisos_pendientes
  ON public.avisos (area_destino, created_at DESC) WHERE visto_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_avisos_remision ON public.avisos (remision_id);

ALTER TABLE public.avisos ENABLE ROW LEVEL SECURITY;

-- Supabase otorga esto solo a las tablas nuevas de `public` (default
-- privileges), pero explícito no estorba y hace que el script se baste solo si
-- alguien lo corre en otra base. Quién ve qué lo decide el RLS de abajo.
GRANT SELECT, INSERT, UPDATE ON public.avisos TO authenticated;

/** ¿A este usuario le tocan los avisos de esta área? */
CREATE OR REPLACE FUNCTION public.recibe_avisos_de(_area public.user_area, _user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.user_roles ur
      LEFT JOIN public.profiles p ON p.id = ur.user_id
     WHERE ur.user_id = _user_id
       AND COALESCE(p.activo, true)
       AND (
         ur.area = _area
         -- Dirección ve todo, y el rol legado `admin` es su equivalente.
         OR ur.area = 'direccion'
         OR ur.role = 'admin'
       )
  );
$$;

REVOKE EXECUTE ON FUNCTION public.recibe_avisos_de(public.user_area, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.recibe_avisos_de(public.user_area, uuid) TO authenticated;

-- Leer: el área destinataria (más Dirección). Quien manda el aviso también lo
-- ve, para saber que salió.
DROP POLICY IF EXISTS "leer avisos de mi area" ON public.avisos;
CREATE POLICY "leer avisos de mi area" ON public.avisos
  FOR SELECT TO authenticated
  USING (public.recibe_avisos_de(area_destino) OR creado_por = auth.uid());

-- Escribir: cualquiera puede avisarle a otra área, pero firmando con su nombre.
DROP POLICY IF EXISTS "mandar aviso" ON public.avisos;
CREATE POLICY "mandar aviso" ON public.avisos
  FOR INSERT TO authenticated WITH CHECK (creado_por = auth.uid());

-- Dar por visto: sólo el área destinataria. El contenido no se puede cambiar
-- (la política sólo permite el UPDATE; el trigger de abajo congela el resto).
DROP POLICY IF EXISTS "dar por visto" ON public.avisos;
CREATE POLICY "dar por visto" ON public.avisos
  FOR UPDATE TO authenticated
  USING (public.recibe_avisos_de(area_destino))
  WITH CHECK (public.recibe_avisos_de(area_destino));

/**
 * Un aviso se acusa, no se edita: lo único que puede cambiar es `visto_por` y
 * `visto_at`. Sin esto, la política de UPDATE dejaría reescribir el texto de un
 * aviso incómodo.
 */
CREATE OR REPLACE FUNCTION public.trg_avisos_solo_acuse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.area_destino   := OLD.area_destino;
  NEW.tipo           := OLD.tipo;
  NEW.titulo         := OLD.titulo;
  NEW.cuerpo         := OLD.cuerpo;
  NEW.remision_id    := OLD.remision_id;
  NEW.folio_remision := OLD.folio_remision;
  NEW.datos          := OLD.datos;
  NEW.creado_por     := OLD.creado_por;
  NEW.nombre_creador := OLD.nombre_creador;
  NEW.created_at     := OLD.created_at;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_avisos_solo_acuse ON public.avisos;
CREATE TRIGGER trg_avisos_solo_acuse
  BEFORE UPDATE ON public.avisos
  FOR EACH ROW EXECUTE FUNCTION public.trg_avisos_solo_acuse();


-- ============================================================================
-- BLOQUE 2 · Bajar el total liberando unidades, no frenando a Comercial
-- ============================================================================

/**
 * Deja la remisión con `_total_objetivo` unidades asignadas, liberando las que
 * sobren, y avisa a Fábrica y a Logística.
 *
 * Devuelve un JSON con lo que hizo:
 *   { liberadas: n, unidades: [{orden_armado, ns_chasis, estatus_armado}], piso: n }
 *
 * SECURITY DEFINER porque toca `motocarros`, que Comercial no puede escribir —
 * el permiso lo decide `puede_editar_remision()`, no el rol de la tabla.
 */
CREATE OR REPLACE FUNCTION public.ajustar_unidades_remision(
  _remision_id     uuid,
  _total_objetivo  integer,
  _motivo          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _r          public.remisiones%ROWTYPE;
  _asignadas  integer;
  _piso       integer;
  _sobran     integer;
  _liberadas  jsonb := '[]'::jsonb;
  _detalle    text;
  _quien      text;
BEGIN
  IF _total_objetivo IS NULL OR _total_objetivo < 0 THEN
    RAISE EXCEPTION 'El total objetivo no es válido';
  END IF;

  SELECT * INTO _r FROM public.remisiones WHERE id = _remision_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Remisión no encontrada'; END IF;

  IF NOT public.puede_editar_remision(_remision_id) THEN
    RAISE EXCEPTION 'No tienes permiso para ajustar esta remisión';
  END IF;

  SELECT COUNT(*) INTO _asignadas FROM public.motocarros WHERE remision_id = _remision_id;

  -- Lo que ya salió del almacén no se puede devolver desde una pantalla.
  SELECT COUNT(*) INTO _piso
    FROM public.motocarros
   WHERE remision_id = _remision_id
     AND estatus_entrega IN ('ENTREGADA','EN_RUTA');

  IF _total_objetivo < _piso THEN
    RAISE EXCEPTION 'La remisión ya tiene % unidad(es) entregadas o en ruta: no se puede bajar a %.',
      _piso, _total_objetivo;
  END IF;

  _sobran := _asignadas - _total_objetivo;
  IF _sobran <= 0 THEN
    RETURN jsonb_build_object('liberadas', 0, 'unidades', '[]'::jsonb, 'piso', _piso);
  END IF;

  -- Se sueltan las menos avanzadas primero: devolver al inventario una unidad
  -- sin armar cuesta menos que una ya terminada.
  WITH candidatas AS (
    SELECT id, orden_armado, ns_chasis, chasis_asignado, estatus_armado,
           ROW_NUMBER() OVER (
             ORDER BY CASE estatus_armado
                        WHEN 'PENDIENTE'  THEN 1
                        WHEN 'ATRASADO'   THEN 2
                        WHEN 'EN_PROCESO' THEN 3
                        WHEN 'ARMADO'     THEN 4
                        WHEN 'LISTO'      THEN 5
                        ELSE 6
                      END,
                      orden_armado DESC NULLS LAST
           ) AS prioridad
      FROM public.motocarros
     WHERE remision_id = _remision_id
       AND COALESCE(estatus_entrega::text, 'NO_APLICA') NOT IN ('ENTREGADA','EN_RUTA')
  ), sueltas AS (
    UPDATE public.motocarros m
       SET remision_id = NULL,
           estatus_entrega = 'NO_APLICA'
      FROM candidatas c
     WHERE m.id = c.id AND c.prioridad <= _sobran
     RETURNING m.id, c.orden_armado, c.ns_chasis, c.chasis_asignado, c.estatus_armado
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'orden_armado',   s.orden_armado,
           'ns_chasis',      COALESCE(s.ns_chasis, s.chasis_asignado),
           'estatus_armado', s.estatus_armado
         ) ORDER BY s.orden_armado), '[]'::jsonb)
    INTO _liberadas
    FROM sueltas s;

  -- El estatus de la remisión se recalcula igual que en desasignar_motocarro.
  UPDATE public.remisiones r
     SET estatus = CASE
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) = 0
         THEN 'NUEVA'::estatus_remision
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) >= GREATEST(_total_objetivo, 1)
         THEN 'COMPLETA'::estatus_remision
       ELSE 'PARCIAL'::estatus_remision
     END
   WHERE r.id = _remision_id
     AND r.estatus <> 'CANCELADA';

  -- El aviso: a Fábrica y a Logística. Para Fábrica son unidades que vuelven a
  -- la fila; para Logística, entregas que se caen de la programación.
  SELECT COALESCE(p.nombre_completo, 'Comercial') INTO _quien
    FROM public.profiles p WHERE p.id = auth.uid();

  _detalle := format('%s bajó de %s a %s unidades. Se liberaron %s: %s.%s',
    COALESCE(_r.folio_remision, 'La remisión'),
    _asignadas, _total_objetivo, jsonb_array_length(_liberadas),
    COALESCE(NULLIF((
      SELECT string_agg(COALESCE(u->>'ns_chasis', '#' || (u->>'orden_armado')), ', ')
        FROM jsonb_array_elements(_liberadas) u
    ), ''), 'sin número de serie'),
    CASE WHEN _motivo IS NULL OR btrim(_motivo) = '' THEN '' ELSE ' Motivo: ' || btrim(_motivo) END
  );

  INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, remision_id, folio_remision,
                             datos, creado_por, nombre_creador)
  SELECT a, 'unidades_liberadas',
         format('%s liberó %s unidad(es)', COALESCE(_r.folio_remision,'Una remisión'), jsonb_array_length(_liberadas)),
         _detalle, _remision_id, _r.folio_remision,
         jsonb_build_object('antes', _asignadas, 'despues', _total_objetivo, 'unidades', _liberadas),
         auth.uid(), _quien
    FROM unnest(ARRAY['fabrica','almacen_logistica']::public.user_area[]) AS a;

  RETURN jsonb_build_object(
    'liberadas', jsonb_array_length(_liberadas),
    'unidades',  _liberadas,
    'piso',      _piso
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.ajustar_unidades_remision(uuid, integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.ajustar_unidades_remision(uuid, integer, text) TO authenticated;

COMMENT ON FUNCTION public.ajustar_unidades_remision(uuid, integer, text) IS
  'Baja el total de una remisión liberando las unidades sobrantes (las menos avanzadas primero) y avisando a Fábrica y Logística. No baja de las unidades ya entregadas o en ruta.';


-- ============================================================================
-- BLOQUE 3 · Comprobación
-- ============================================================================

DO $postflight$
DECLARE _faltan text[] := ARRAY[]::text[]; _p text;
BEGIN
  IF to_regclass('public.avisos') IS NULL THEN _faltan := _faltan || 'tabla avisos'::text; END IF;
  IF to_regprocedure('public.recibe_avisos_de(public.user_area,uuid)') IS NULL THEN
    _faltan := _faltan || 'recibe_avisos_de()'::text; END IF;
  IF to_regprocedure('public.ajustar_unidades_remision(uuid,integer,text)') IS NULL THEN
    _faltan := _faltan || 'ajustar_unidades_remision()'::text; END IF;

  FOREACH _p IN ARRAY ARRAY['leer avisos de mi area','mandar aviso','dar por visto'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename='avisos' AND policyname=_p) THEN
      _faltan := _faltan || _p; END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                  WHERE c.relname='avisos' AND t.tgname='trg_avisos_solo_acuse' AND NOT t.tgisinternal) THEN
    _faltan := _faltan || 'trigger trg_avisos_solo_acuse'::text; END IF;

  IF array_length(_faltan,1) > 0 THEN
    RAISE EXCEPTION 'Quedó incompleto, se revierte. Falta: %.', array_to_string(_faltan, ' | ');
  END IF;
END $postflight$;

-- Qué quedó (el editor de Supabase sólo muestra la última consulta).
SELECT 'tabla'   AS que, 'avisos' AS nombre,
       CASE WHEN to_regclass('public.avisos') IS NULL THEN '✗' ELSE '✓ creada' END AS estado
UNION ALL
SELECT 'función', f, CASE WHEN to_regprocedure('public.'||f) IS NULL THEN '✗' ELSE '✓ creada' END
  FROM unnest(ARRAY['recibe_avisos_de(public.user_area,uuid)','ajustar_unidades_remision(uuid,integer,text)']) AS f
UNION ALL
SELECT 'política', policyname, '✓ creada'
  FROM pg_policies WHERE schemaname='public' AND tablename='avisos'
ORDER BY 1, 2;
