-- ============================================================================
-- Una vez que Fábrica empezó a armar, la unidad se pide — no se quita
-- Fecha: 2026-09-04
--
-- Qué estaba pasando
-- ------------------
-- 20260903000001 dejó que Comercial soltara cualquier unidad que no estuviera
-- entregada o en ruta. El piso quedó muy abajo: una unidad EN_PROCESO ya tiene
-- trabajo encima de Fábrica, y quitársela desde la pantalla de remisiones tira
-- ese trabajo sin que nadie se entere hasta que ya pasó.
--
-- La regla real de la operación: el armado empieza y ahí se cierra la puerta.
--
-- Qué queda
-- ---------
--  1. `ajustar_unidades_remision()` sólo libera lo que sigue en PENDIENTE. Lo
--     que ya entró a armado NO lo suelta: levanta una **solicitud** a Fábrica
--     con esas unidades, y Fábrica contesta.
--  2. `avisos` aprende a llevar solicitudes: `requiere_respuesta`, `estado`,
--     `respuesta`, quién y cuándo contestó, y `accion` — qué hay que hacer si
--     se acepta. Sigue siendo una sola bandeja: nadie tiene que aprender otra
--     pantalla.
--  3. `responder_solicitud()`: Fábrica acepta o rechaza. Si acepta, la unidad
--     se libera ahí mismo; en ambos casos la respuesta le regresa a quien la
--     pidió.
--
-- Por qué PENDIENTE y no «no entregada»: PENDIENTE es lo único que la base
-- guarda como «todavía no se toca» (ATRASADO nunca se escribe — se calcula en
-- pantalla para lo vencido). EN_PROCESO, ARMADO y LISTO son trabajo hecho.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.avisos') IS NULL THEN
    _faltan := _faltan || 'tabla avisos (corre antes 20260903000001_avisos_entre_areas.sql)'::text;
  END IF;
  IF to_regprocedure('public.recibe_avisos_de(public.user_area,uuid)') IS NULL THEN
    _faltan := _faltan || 'recibe_avisos_de()'::text;
  END IF;
  IF to_regprocedure('public.puede_editar_remision(uuid,uuid)') IS NULL THEN
    _faltan := _faltan || 'puede_editar_remision()'::text;
  END IF;

  IF array_length(_faltan,1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %.', array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;


-- ============================================================================
-- BLOQUE 1 · Un aviso puede pedir respuesta
-- ============================================================================

ALTER TABLE public.avisos
  ADD COLUMN IF NOT EXISTS requiere_respuesta BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS estado             TEXT    NOT NULL DEFAULT 'pendiente',
  ADD COLUMN IF NOT EXISTS respuesta          TEXT,
  ADD COLUMN IF NOT EXISTS respondido_por     UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS respondido_at      TIMESTAMPTZ,
  -- A quién le regresa la respuesta (quien levantó la solicitud).
  ADD COLUMN IF NOT EXISTS usuario_destino    UUID REFERENCES auth.users(id),
  -- Qué hacer si se acepta: {"tipo":"liberar_unidades","motocarros":[uuid,...]}
  ADD COLUMN IF NOT EXISTS accion             JSONB;

DO $estado$
BEGIN
  ALTER TABLE public.avisos DROP CONSTRAINT IF EXISTS avisos_estado_valido;
  ALTER TABLE public.avisos ADD CONSTRAINT avisos_estado_valido
    CHECK (estado IN ('pendiente','visto','aceptada','rechazada'));
END $estado$;

-- Los avisos que ya se habían acusado con la versión anterior.
UPDATE public.avisos SET estado = 'visto' WHERE visto_at IS NOT NULL AND estado = 'pendiente';

CREATE INDEX IF NOT EXISTS idx_avisos_por_resolver
  ON public.avisos (area_destino, created_at DESC) WHERE estado = 'pendiente';
CREATE INDEX IF NOT EXISTS idx_avisos_usuario_destino
  ON public.avisos (usuario_destino, created_at DESC) WHERE estado = 'pendiente';

-- La respuesta también le llega a quien la pidió, aunque no sea de su área.
DROP POLICY IF EXISTS "leer avisos de mi area" ON public.avisos;
CREATE POLICY "leer avisos de mi area" ON public.avisos
  FOR SELECT TO authenticated
  USING (
    public.recibe_avisos_de(area_destino)
    OR creado_por = auth.uid()
    OR usuario_destino = auth.uid()
  );

-- Y puede darla por vista, aunque el área destinataria sea otra.
DROP POLICY IF EXISTS "dar por visto" ON public.avisos;
CREATE POLICY "dar por visto" ON public.avisos
  FOR UPDATE TO authenticated
  USING (public.recibe_avisos_de(area_destino) OR usuario_destino = auth.uid())
  WITH CHECK (public.recibe_avisos_de(area_destino) OR usuario_destino = auth.uid());

/**
 * Un aviso se acusa y se contesta, pero no se reescribe. Lo editable es el
 * acuse (`visto_*`) y la respuesta (`estado`, `respuesta`, `respondido_*`);
 * todo lo demás queda como se mandó.
 *
 * Aceptar o rechazar NO se hace por aquí: eso pasa por
 * `responder_solicitud()`, que además ejecuta la acción. Este trigger sólo
 * evita que un UPDATE suelto cambie el contenido — por eso permite `estado`,
 * pero la función es la única que lo mueve a 'aceptada'/'rechazada' junto con
 * la liberación de las unidades.
 */
CREATE OR REPLACE FUNCTION public.trg_avisos_solo_acuse()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.area_destino       := OLD.area_destino;
  NEW.tipo               := OLD.tipo;
  NEW.titulo             := OLD.titulo;
  NEW.cuerpo             := OLD.cuerpo;
  NEW.remision_id        := OLD.remision_id;
  NEW.folio_remision     := OLD.folio_remision;
  NEW.datos              := OLD.datos;
  NEW.creado_por         := OLD.creado_por;
  NEW.nombre_creador     := OLD.nombre_creador;
  NEW.created_at         := OLD.created_at;
  NEW.requiere_respuesta := OLD.requiere_respuesta;
  NEW.usuario_destino    := OLD.usuario_destino;
  NEW.accion             := OLD.accion;
  RETURN NEW;
END;
$$;


-- ============================================================================
-- BLOQUE 2 · Liberar sólo lo que no ha empezado; lo demás, se pide
-- ============================================================================

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
  _r           public.remisiones%ROWTYPE;
  _asignadas   integer;
  _sobran      integer;
  _liberadas   jsonb := '[]'::jsonb;
  _porPedir    jsonb := '[]'::jsonb;
  _ids_pedir   uuid[] := ARRAY[]::uuid[];
  _solicitud   uuid;
  _quien       text;
  _detalle     text;
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
  _sobran := _asignadas - _total_objetivo;

  IF _sobran <= 0 THEN
    RETURN jsonb_build_object('liberadas', 0, 'unidades', '[]'::jsonb,
                              'solicitadas', 0, 'por_pedir', '[]'::jsonb, 'solicitud_id', NULL);
  END IF;

  SELECT COALESCE(p.nombre_completo, 'Comercial') INTO _quien
    FROM public.profiles p WHERE p.id = auth.uid();

  -- ── 1. Lo que todavía no se toca se suelta solo ──────────────────────────
  -- Se toman las de mayor orden de armado: son las últimas de la fila.
  WITH candidatas AS (
    SELECT id, orden_armado, ns_chasis, chasis_asignado,
           ROW_NUMBER() OVER (ORDER BY orden_armado DESC NULLS LAST) AS prioridad
      FROM public.motocarros
     WHERE remision_id = _remision_id
       AND estatus_armado = 'PENDIENTE'
       AND COALESCE(estatus_entrega::text,'NO_APLICA') NOT IN ('ENTREGADA','EN_RUTA')
  ), sueltas AS (
    UPDATE public.motocarros m
       SET remision_id = NULL, estatus_entrega = 'NO_APLICA'
      FROM candidatas c
     WHERE m.id = c.id AND c.prioridad <= _sobran
     RETURNING m.id, c.orden_armado, c.ns_chasis, c.chasis_asignado
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'orden_armado', s.orden_armado,
           'ns_chasis',    COALESCE(s.ns_chasis, s.chasis_asignado)
         ) ORDER BY s.orden_armado), '[]'::jsonb)
    INTO _liberadas
    FROM sueltas s;

  -- ── 2. Lo que ya entró a armado se pide, no se quita ─────────────────────
  _sobran := _sobran - jsonb_array_length(_liberadas);

  IF _sobran > 0 THEN
    WITH enArmado AS (
      SELECT id, orden_armado, ns_chasis, chasis_asignado, estatus_armado,
             ROW_NUMBER() OVER (
               ORDER BY CASE estatus_armado
                          WHEN 'EN_PROCESO' THEN 1
                          WHEN 'ATRASADO'   THEN 2
                          WHEN 'ARMADO'     THEN 3
                          WHEN 'LISTO'      THEN 4
                          ELSE 5
                        END,
                        orden_armado DESC NULLS LAST
             ) AS prioridad
        FROM public.motocarros
       WHERE remision_id = _remision_id
         AND estatus_armado <> 'PENDIENTE'
         AND COALESCE(estatus_entrega::text,'NO_APLICA') NOT IN ('ENTREGADA','EN_RUTA')
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'motocarro_id',   e.id,
             'orden_armado',   e.orden_armado,
             'ns_chasis',      COALESCE(e.ns_chasis, e.chasis_asignado),
             'estatus_armado', e.estatus_armado
           ) ORDER BY e.prioridad), '[]'::jsonb),
           COALESCE(array_agg(e.id ORDER BY e.prioridad), ARRAY[]::uuid[])
      INTO _porPedir, _ids_pedir
      FROM enArmado e
     WHERE e.prioridad <= _sobran;
  END IF;

  -- ── 3. El estatus de la remisión, con lo que quedó asignado ──────────────
  UPDATE public.remisiones r
     SET estatus = CASE
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) = 0
         THEN 'NUEVA'::estatus_remision
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) >= GREATEST(_total_objetivo, 1)
         THEN 'COMPLETA'::estatus_remision
       ELSE 'PARCIAL'::estatus_remision
     END
   WHERE r.id = _remision_id AND r.estatus <> 'CANCELADA';

  -- ── 4. Avisar lo que se soltó ────────────────────────────────────────────
  IF jsonb_array_length(_liberadas) > 0 THEN
    _detalle := format('%s bajó de %s a %s unidades. Se liberaron %s que aún no entraban a armado: %s.%s',
      COALESCE(_r.folio_remision,'La remisión'), _asignadas, _total_objetivo,
      jsonb_array_length(_liberadas),
      (SELECT string_agg(COALESCE(u->>'ns_chasis','#'||(u->>'orden_armado')), ', ')
         FROM jsonb_array_elements(_liberadas) u),
      CASE WHEN COALESCE(btrim(_motivo),'') = '' THEN '' ELSE ' Motivo: '||btrim(_motivo) END);

    INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, remision_id, folio_remision,
                               datos, creado_por, nombre_creador)
    SELECT a, 'unidades_liberadas',
           format('%s liberó %s unidad(es)', COALESCE(_r.folio_remision,'Una remisión'), jsonb_array_length(_liberadas)),
           _detalle, _remision_id, _r.folio_remision,
           jsonb_build_object('antes',_asignadas,'despues',_total_objetivo,'unidades',_liberadas),
           auth.uid(), _quien
      FROM unnest(ARRAY['fabrica','almacen_logistica']::public.user_area[]) AS a;
  END IF;

  -- ── 5. Y pedir lo que ya no se puede quitar ──────────────────────────────
  IF jsonb_array_length(_porPedir) > 0 THEN
    _detalle := format('%s pide soltar %s unidad(es) que ya están en armado: %s.%s Si aceptas, vuelven al inventario; si no, la remisión se queda como está.',
      COALESCE(_r.folio_remision,'Una remisión'), jsonb_array_length(_porPedir),
      (SELECT string_agg(
                COALESCE(u->>'ns_chasis','#'||(u->>'orden_armado')) || ' (' || (u->>'estatus_armado') || ')', ', ')
         FROM jsonb_array_elements(_porPedir) u),
      CASE WHEN COALESCE(btrim(_motivo),'') = '' THEN '' ELSE ' Motivo: '||btrim(_motivo)||'.' END);

    INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, remision_id, folio_remision,
                               datos, creado_por, nombre_creador,
                               requiere_respuesta, estado, accion)
    VALUES ('fabrica', 'solicitud_liberar',
            format('%s pide soltar %s unidad(es) en armado',
                   COALESCE(_r.folio_remision,'Una remisión'), jsonb_array_length(_porPedir)),
            _detalle, _remision_id, _r.folio_remision,
            jsonb_build_object('antes',_asignadas,'despues',_total_objetivo,'unidades',_porPedir),
            auth.uid(), _quien,
            true, 'pendiente',
            jsonb_build_object('tipo','liberar_unidades','motocarros', to_jsonb(_ids_pedir)))
    RETURNING id INTO _solicitud;
  END IF;

  RETURN jsonb_build_object(
    'liberadas',    jsonb_array_length(_liberadas),
    'unidades',     _liberadas,
    'solicitadas',  jsonb_array_length(_porPedir),
    'por_pedir',    _porPedir,
    'solicitud_id', _solicitud
  );
END;
$$;

COMMENT ON FUNCTION public.ajustar_unidades_remision(uuid, integer, text) IS
  'Baja el total de una remisión: suelta las unidades que siguen en PENDIENTE y, por las que ya entraron a armado, levanta una solicitud a Fábrica. Avisa a Fábrica y Logística de lo liberado.';


-- ============================================================================
-- BLOQUE 3 · Fábrica contesta
-- ============================================================================

/**
 * Acepta o rechaza una solicitud. Si acepta y la solicitud era para soltar
 * unidades, las suelta aquí mismo — así no queda un «sí» sin efecto.
 *
 * La respuesta le regresa a quien la pidió como un aviso suyo, para que no
 * tenga que estar revisando.
 */
CREATE OR REPLACE FUNCTION public.responder_solicitud(
  _aviso_id  uuid,
  _aceptar   boolean,
  _respuesta text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _a         public.avisos%ROWTYPE;
  _ids       uuid[];
  _liberadas jsonb := '[]'::jsonb;
  _quien     text;
BEGIN
  SELECT * INTO _a FROM public.avisos WHERE id = _aviso_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'La solicitud no existe'; END IF;
  IF NOT _a.requiere_respuesta THEN RAISE EXCEPTION 'Ese aviso no es una solicitud'; END IF;
  IF _a.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Esa solicitud ya fue contestada (%)', _a.estado;
  END IF;
  IF NOT public.recibe_avisos_de(_a.area_destino) THEN
    RAISE EXCEPTION 'Sólo % puede contestar esta solicitud', _a.area_destino;
  END IF;

  SELECT COALESCE(p.nombre_completo, 'Fábrica') INTO _quien
    FROM public.profiles p WHERE p.id = auth.uid();

  IF _aceptar AND COALESCE(_a.accion->>'tipo','') = 'liberar_unidades' THEN
    SELECT COALESCE(array_agg((v)::uuid), ARRAY[]::uuid[]) INTO _ids
      FROM jsonb_array_elements_text(COALESCE(_a.accion->'motocarros','[]'::jsonb)) v;

    -- Se vuelve a comprobar el estado: entre la petición y el sí, la unidad
    -- pudo haberse entregado o haber cambiado de remisión.
    WITH sueltas AS (
      UPDATE public.motocarros m
         SET remision_id = NULL, estatus_entrega = 'NO_APLICA'
       WHERE m.id = ANY(_ids)
         AND m.remision_id = _a.remision_id
         AND COALESCE(m.estatus_entrega::text,'NO_APLICA') NOT IN ('ENTREGADA','EN_RUTA')
       RETURNING m.orden_armado, m.ns_chasis, m.chasis_asignado
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'orden_armado', s.orden_armado,
             'ns_chasis',    COALESCE(s.ns_chasis, s.chasis_asignado)
           ) ORDER BY s.orden_armado), '[]'::jsonb)
      INTO _liberadas FROM sueltas s;

    UPDATE public.remisiones r
       SET estatus = CASE
         WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) = 0
           THEN 'NUEVA'::estatus_remision
         WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id)
              >= GREATEST(COALESCE(r.total_unidades_solicitadas,1),1)
           THEN 'COMPLETA'::estatus_remision
         ELSE 'PARCIAL'::estatus_remision
       END
     WHERE r.id = _a.remision_id AND r.estatus <> 'CANCELADA';
  END IF;

  UPDATE public.avisos
     SET estado         = CASE WHEN _aceptar THEN 'aceptada' ELSE 'rechazada' END,
         respuesta      = NULLIF(btrim(COALESCE(_respuesta,'')), ''),
         respondido_por = auth.uid(),
         respondido_at  = now(),
         visto_por      = auth.uid(),
         visto_at       = now()
   WHERE id = _aviso_id;

  -- La respuesta de vuelta, dirigida a quien la pidió.
  INSERT INTO public.avisos (area_destino, tipo, titulo, cuerpo, remision_id, folio_remision,
                             datos, creado_por, nombre_creador, usuario_destino, estado)
  VALUES ('comercial',
          CASE WHEN _aceptar THEN 'solicitud_aceptada' ELSE 'solicitud_rechazada' END,
          format('Fábrica %s soltar %s unidad(es) de %s',
                 CASE WHEN _aceptar THEN 'aceptó' ELSE 'no aceptó' END,
                 jsonb_array_length(COALESCE(_a.datos->'unidades','[]'::jsonb)),
                 COALESCE(_a.folio_remision,'la remisión')),
          CASE WHEN _aceptar
               THEN format('Se liberaron %s unidad(es) y volvieron al inventario.', jsonb_array_length(_liberadas))
               ELSE 'Las unidades siguen asignadas a la remisión.' END
          || CASE WHEN COALESCE(btrim(_respuesta),'') = '' THEN '' ELSE ' ' || btrim(_respuesta) END,
          _a.remision_id, _a.folio_remision,
          jsonb_build_object('aceptada', _aceptar, 'liberadas', _liberadas),
          auth.uid(), _quien, _a.creado_por, 'pendiente');

  RETURN jsonb_build_object('aceptada', _aceptar, 'liberadas', jsonb_array_length(_liberadas));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.responder_solicitud(uuid, boolean, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.responder_solicitud(uuid, boolean, text) TO authenticated;


-- ============================================================================
-- BLOQUE 4 · Comprobación
-- ============================================================================

DO $postflight$
DECLARE _faltan text[] := ARRAY[]::text[]; _c text;
BEGIN
  FOREACH _c IN ARRAY ARRAY['requiere_respuesta','estado','respuesta','respondido_por','respondido_at','usuario_destino','accion'] LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='avisos' AND column_name=_c) THEN
      _faltan := _faltan || ('avisos.'||_c); END IF;
  END LOOP;

  IF to_regprocedure('public.responder_solicitud(uuid,boolean,text)') IS NULL THEN
    _faltan := _faltan || 'responder_solicitud()'::text; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                   AND tablename='avisos' AND policyname='leer avisos de mi area'
                   AND qual LIKE '%usuario_destino%') THEN
    _faltan := _faltan || 'la lectura no incluye usuario_destino'::text; END IF;

  IF array_length(_faltan,1) > 0 THEN
    RAISE EXCEPTION 'Quedó incompleto, se revierte. Falta: %.', array_to_string(_faltan, ' | ');
  END IF;
END $postflight$;

SELECT 'columna' AS que, c AS nombre, '✓' AS estado
  FROM unnest(ARRAY['requiere_respuesta','estado','respuesta','respondido_por','respondido_at','usuario_destino','accion']) AS c
UNION ALL
SELECT 'función', 'responder_solicitud', '✓'
UNION ALL
SELECT 'función', 'ajustar_unidades_remision (ahora sólo suelta PENDIENTE)', '✓'
ORDER BY 1, 2;
