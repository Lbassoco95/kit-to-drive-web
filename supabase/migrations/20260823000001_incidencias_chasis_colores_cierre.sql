-- ============================================================================
-- KIT-4 · Tres cosas que no estaban cerrando el ciclo:
--   A) Colores: se cargaban pero no se registraban. Ahora el disponible /
--      comprometido / demanda por modelo comercial y color se calcula de los
--      datos reales, no de un contador que se desincroniza.
--   B) Cierre de proceso: una unidad no puede marcarse ARMADO / LISTO /
--      ENTREGADA sin que fábrica haya registrado NS chasis y NS motor.
--   C) Incidencias de chasis (p.ej. chasis sin soporte de radiador): se
--      levanta un reporte, el chasis NO se elimina ni se deshabilita solo;
--      pasa por revisión y termina en adaptación, garantía o no útil — con
--      el registro pegado al chasis y a la unidad para darle seguimiento.
--
-- Fecha: 2026-08-23
--
-- ADVERTENCIA: Igual que el resto del repo, este script es IDEMPOTENTE pero
-- está pensado para correrse directamente en el SQL editor de Supabase.
-- NO usar `supabase db push` / `db reset` / `migration up`.
-- ============================================================================


-- ============================================================================
-- BLOQUE 1 · Estatus de chasis: catálogo explícito
-- ============================================================================
-- Antes eran tres valores por convención ('disponible','configurado',
-- 'asignado') sin nada que lo garantizara. Las incidencias agregan tres más.
-- El CHECK entra NOT VALID: no revisa lo que ya está cargado (no podemos
-- saber qué escribió una importación vieja) pero sí todo lo que entre desde
-- ahora.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inventario_chasis_estatus_chk') THEN
    ALTER TABLE public.inventario_chasis
      ADD CONSTRAINT inventario_chasis_estatus_chk
      CHECK (estatus IN ('disponible','configurado','asignado','en_revision','garantia','no_util'))
      NOT VALID;
  END IF;
END $$;

COMMENT ON COLUMN public.inventario_chasis.estatus IS
  'disponible = pieza libre y sana · configurado/asignado = ya es parte de una unidad · '
  'en_revision = incidencia abierta que retiene la pieza · garantia = reclamada a fábrica · '
  'no_util = no se pudo adaptar. Un chasis NUNCA se borra: cambia de estatus.';


-- ============================================================================
-- BLOQUE 2 · Incidencias de chasis
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.incidencias_chasis (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio           text UNIQUE,
  chasis_id       uuid NOT NULL REFERENCES public.inventario_chasis(id) ON DELETE CASCADE,
  -- Snapshot: si la unidad se libera o el modelo se reclasifica, el reporte
  -- sigue diciendo de qué pieza hablaba.
  ns_chasis       text NOT NULL,
  modelo          text,
  color           text,
  motocarro_id    uuid REFERENCES public.motocarros(id) ON DELETE SET NULL,

  tipo_falla      text NOT NULL
                  CHECK (tipo_falla IN ('falta_parte','parte_danada','defecto_fabrica','documental','otro')),
  parte_afectada  text,                       -- p.ej. 'Soporte de radiador'
  descripcion     text NOT NULL,
  severidad       text NOT NULL DEFAULT 'mayor'
                  CHECK (severidad IN ('menor','mayor','critica')),

  -- abierta        → reportada, esperando revisión
  -- en_revision    → alguien la está revisando
  -- adaptacion     → se pudo adaptar; el chasis vuelve a servir (con registro)
  -- garantia       → se reclama a fábrica; el chasis queda identificado y fuera
  -- no_util        → no se pudo adaptar; NO se borra, sólo deja de contar
  -- descartada     → falsa alarma
  estatus         text NOT NULL DEFAULT 'abierta'
                  CHECK (estatus IN ('abierta','en_revision','adaptacion','garantia','no_util','descartada')),

  -- Levantar un reporte NO deshabilita el chasis. Sólo lo retiene si quien
  -- reporta lo marca explícitamente (o si la revisión lo decide).
  retiene_chasis  boolean NOT NULL DEFAULT false,

  resolucion      text,
  folio_garantia  text,
  evidencia_url   text,

  reportado_por   uuid REFERENCES auth.users(id),
  reportado_at    timestamptz NOT NULL DEFAULT now(),
  revisado_por    uuid REFERENCES auth.users(id),
  revisado_at     timestamptz,
  resuelto_por    uuid REFERENCES auth.users(id),
  resuelto_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_incidencias_chasis_chasis   ON public.incidencias_chasis (chasis_id);
CREATE INDEX IF NOT EXISTS idx_incidencias_chasis_estatus  ON public.incidencias_chasis (estatus);
CREATE INDEX IF NOT EXISTS idx_incidencias_chasis_moto     ON public.incidencias_chasis (motocarro_id);
CREATE INDEX IF NOT EXISTS idx_incidencias_chasis_ns       ON public.incidencias_chasis (ns_chasis);

-- Un chasis no puede tener dos reportes abiertos al mismo tiempo: se
-- actualiza el que ya existe (o se resuelve primero).
CREATE UNIQUE INDEX IF NOT EXISTS ux_incidencias_chasis_abierta
  ON public.incidencias_chasis (chasis_id)
  WHERE estatus IN ('abierta','en_revision');

ALTER TABLE public.incidencias_chasis ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "autenticados leen incidencias_chasis" ON public.incidencias_chasis;
CREATE POLICY "autenticados leen incidencias_chasis" ON public.incidencias_chasis
  FOR SELECT TO authenticated USING (true);
-- Sin INSERT/UPDATE/DELETE para authenticated: sólo escriben las RPC
-- (SECURITY DEFINER) para que estatus del chasis e incidencia no se separen.

-- Bitácora de la incidencia — el seguimiento que pidió operación.
CREATE TABLE IF NOT EXISTS public.incidencias_chasis_eventos (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incidencia_id    uuid NOT NULL REFERENCES public.incidencias_chasis(id) ON DELETE CASCADE,
  estatus_anterior text,
  estatus_nuevo    text NOT NULL,
  nota             text,
  actor            uuid REFERENCES auth.users(id),
  creado_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_incidencias_eventos_inc
  ON public.incidencias_chasis_eventos (incidencia_id, creado_at DESC);

ALTER TABLE public.incidencias_chasis_eventos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "autenticados leen incidencias_eventos" ON public.incidencias_chasis_eventos;
CREATE POLICY "autenticados leen incidencias_eventos" ON public.incidencias_chasis_eventos
  FOR SELECT TO authenticated USING (true);

DROP TRIGGER IF EXISTS trg_incidencias_chasis_updated ON public.incidencias_chasis;
CREATE TRIGGER trg_incidencias_chasis_updated BEFORE UPDATE ON public.incidencias_chasis
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Folio legible (INC-0001) — la secuencia arranca donde ya haya folios.
CREATE SEQUENCE IF NOT EXISTS public.incidencias_chasis_folio_seq;

CREATE OR REPLACE FUNCTION public._folio_incidencia() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public' AS $$
BEGIN
  IF NEW.folio IS NULL THEN
    NEW.folio := 'INC-' || lpad(nextval('public.incidencias_chasis_folio_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_incidencias_chasis_folio ON public.incidencias_chasis;
CREATE TRIGGER trg_incidencias_chasis_folio BEFORE INSERT ON public.incidencias_chasis
  FOR EACH ROW EXECUTE FUNCTION public._folio_incidencia();

SELECT setval('public.incidencias_chasis_folio_seq',
  GREATEST(1, COALESCE((SELECT max(NULLIF(regexp_replace(folio, '\D', '', 'g'), '')::bigint)
                          FROM public.incidencias_chasis), 0)));


-- ============================================================================
-- BLOQUE 3 · ¿El chasis está bloqueado?
-- ============================================================================
-- Regla de operación: levantar el reporte NO tumba el chasis. Lo saca de
-- circulación una de tres cosas: que quien reporta pida retenerlo, que se
-- reclame garantía, o que la revisión concluya que no es útil.

CREATE OR REPLACE FUNCTION public.chasis_bloqueado(_chasis_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.incidencias_chasis i
     WHERE i.chasis_id = _chasis_id
       AND ( i.estatus IN ('no_util','garantia')
          OR (i.estatus IN ('abierta','en_revision') AND i.retiene_chasis) )
  );
$$;

GRANT EXECUTE ON FUNCTION public.chasis_bloqueado(uuid) TO authenticated;

-- Deja inventario_chasis.estatus consistente con sus incidencias.
CREATE OR REPLACE FUNCTION public._sincronizar_estatus_chasis(_chasis_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _nuevo text; _tiene_unidad boolean;
BEGIN
  SELECT (motocarro_id IS NOT NULL) INTO _tiene_unidad
    FROM inventario_chasis WHERE id = _chasis_id;
  IF _tiene_unidad IS NULL THEN RETURN NULL; END IF;

  SELECT CASE
    WHEN bool_or(i.estatus = 'no_util')  THEN 'no_util'
    WHEN bool_or(i.estatus = 'garantia') THEN 'garantia'
    WHEN bool_or(i.estatus IN ('abierta','en_revision') AND i.retiene_chasis) THEN 'en_revision'
    ELSE NULL END
    INTO _nuevo
    FROM incidencias_chasis i WHERE i.chasis_id = _chasis_id;

  IF _nuevo IS NULL THEN
    _nuevo := CASE WHEN _tiene_unidad THEN 'configurado' ELSE 'disponible' END;
  END IF;

  UPDATE inventario_chasis SET estatus = _nuevo WHERE id = _chasis_id AND estatus <> _nuevo;
  RETURN _nuevo;
END; $$;

REVOKE ALL ON FUNCTION public._sincronizar_estatus_chasis(uuid) FROM PUBLIC, anon, authenticated;


-- ============================================================================
-- BLOQUE 4 · RPC de incidencias
-- ============================================================================

-- 4.1 · Levantar el reporte. El chasis puede seguir usándose salvo que se
-- pida retenerlo; si ya es parte de una unidad, el reporte queda pegado a la
-- unidad para que Producción lo vea.
CREATE OR REPLACE FUNCTION public.reportar_incidencia_chasis(
  _chasis_id      uuid,
  _tipo_falla     text,
  _descripcion    text,
  _parte_afectada text    DEFAULT NULL,
  _severidad      text    DEFAULT 'mayor',
  _retiene        boolean DEFAULT false,
  _evidencia_url  text    DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _ch record; _id uuid; _folio text; _estatus_chasis text;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)
          OR has_role(auth.uid(),'coordinador'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica/coordinador puede levantar reportes de chasis';
  END IF;
  IF _descripcion IS NULL OR length(trim(_descripcion)) < 5 THEN
    RAISE EXCEPTION 'Describe la falla (mínimo 5 caracteres)';
  END IF;

  SELECT * INTO _ch FROM inventario_chasis WHERE id = _chasis_id;
  IF _ch IS NULL THEN RAISE EXCEPTION 'Chasis no encontrado'; END IF;

  IF EXISTS (SELECT 1 FROM incidencias_chasis
              WHERE chasis_id = _chasis_id AND estatus IN ('abierta','en_revision')) THEN
    RAISE EXCEPTION 'El chasis % ya tiene un reporte abierto — resuélvelo o agrégale una nota',
      _ch.numero_chasis;
  END IF;

  INSERT INTO incidencias_chasis (
    chasis_id, ns_chasis, modelo, color, motocarro_id,
    tipo_falla, parte_afectada, descripcion, severidad,
    estatus, retiene_chasis, evidencia_url, reportado_por)
  VALUES (
    _chasis_id, _ch.numero_chasis, _ch.modelo, _ch.color, _ch.motocarro_id,
    _tipo_falla, NULLIF(trim(COALESCE(_parte_afectada,'')),''), trim(_descripcion),
    COALESCE(_severidad,'mayor'),
    'abierta', COALESCE(_retiene,false), _evidencia_url, auth.uid())
  RETURNING id, folio INTO _id, _folio;

  INSERT INTO incidencias_chasis_eventos (incidencia_id, estatus_anterior, estatus_nuevo, nota, actor)
  VALUES (_id, NULL, 'abierta', trim(_descripcion), auth.uid());

  _estatus_chasis := public._sincronizar_estatus_chasis(_chasis_id);
  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'incidencia_id', _id, 'folio', _folio,
    'ns_chasis', _ch.numero_chasis, 'estatus_chasis', _estatus_chasis,
    'retiene_chasis', COALESCE(_retiene,false), 'motocarro_id', _ch.motocarro_id);
END; $$;

GRANT EXECUTE ON FUNCTION public.reportar_incidencia_chasis(uuid,text,text,text,text,boolean,text) TO authenticated;

-- 4.2 · Tomar la incidencia para revisión (y decidir si se retiene la pieza).
CREATE OR REPLACE FUNCTION public.revisar_incidencia_chasis(
  _incidencia_id uuid, _nota text DEFAULT NULL, _retiene boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _i record; _estatus_chasis text;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede revisar incidencias';
  END IF;

  SELECT * INTO _i FROM incidencias_chasis WHERE id = _incidencia_id;
  IF _i IS NULL THEN RAISE EXCEPTION 'Incidencia no encontrada'; END IF;
  IF _i.estatus NOT IN ('abierta','en_revision') THEN
    RAISE EXCEPTION 'La incidencia % ya está resuelta (%)', _i.folio, _i.estatus;
  END IF;

  UPDATE incidencias_chasis
     SET estatus = 'en_revision',
         retiene_chasis = COALESCE(_retiene, retiene_chasis),
         revisado_por = auth.uid(), revisado_at = now()
   WHERE id = _incidencia_id;

  INSERT INTO incidencias_chasis_eventos (incidencia_id, estatus_anterior, estatus_nuevo, nota, actor)
  VALUES (_incidencia_id, _i.estatus, 'en_revision', _nota, auth.uid());

  _estatus_chasis := public._sincronizar_estatus_chasis(_i.chasis_id);
  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'folio', _i.folio, 'estatus_chasis', _estatus_chasis);
END; $$;

GRANT EXECUTE ON FUNCTION public.revisar_incidencia_chasis(uuid,text,boolean) TO authenticated;

-- 4.3 · Cerrar la revisión.
--   adaptacion → se pudo adaptar: el chasis vuelve a servir y el registro se
--                queda pegado para darle seguimiento.
--   garantia   → se reclama a fábrica: el chasis queda identificado y fuera
--                del disponible, con folio de garantía.
--   no_util    → no se pudo adaptar: deja de contar, pero NO se borra.
--   descartada → falsa alarma.
CREATE OR REPLACE FUNCTION public.resolver_incidencia_chasis(
  _incidencia_id  uuid,
  _resultado      text,
  _resolucion     text,
  _folio_garantia text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _i record; _m record; _estatus_chasis text; _retiene boolean;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede resolver incidencias';
  END IF;
  IF _resultado NOT IN ('adaptacion','garantia','no_util','descartada') THEN
    RAISE EXCEPTION 'Resultado inválido: %', _resultado;
  END IF;
  IF _resolucion IS NULL OR length(trim(_resolucion)) < 5 THEN
    RAISE EXCEPTION 'Escribe qué se hizo (mínimo 5 caracteres)';
  END IF;
  IF _resultado = 'garantia' AND (_folio_garantia IS NULL OR length(trim(_folio_garantia)) = 0) THEN
    RAISE EXCEPTION 'Una garantía necesita folio o referencia del reclamo';
  END IF;

  SELECT * INTO _i FROM incidencias_chasis WHERE id = _incidencia_id;
  IF _i IS NULL THEN RAISE EXCEPTION 'Incidencia no encontrada'; END IF;

  -- Sacar de circulación una pieza que ya es parte de una unidad vendida no
  -- es una decisión de captura: primero hay que liberar o reasignar la unidad.
  IF _resultado IN ('no_util','garantia') AND _i.motocarro_id IS NOT NULL THEN
    SELECT * INTO _m FROM motocarros WHERE id = _i.motocarro_id;
    IF _m.remision_id IS NOT NULL THEN
      RAISE EXCEPTION 'El chasis % está en la unidad #% ya asignada a una remisión — libérala primero (Producción → Liberar unidad)',
        _i.ns_chasis, _m.orden_armado;
    END IF;
  END IF;

  _retiene := (_resultado IN ('no_util','garantia'));

  UPDATE incidencias_chasis
     SET estatus = _resultado,
         retiene_chasis = _retiene,
         resolucion = trim(_resolucion),
         folio_garantia = COALESCE(NULLIF(trim(COALESCE(_folio_garantia,'')),''), folio_garantia),
         resuelto_por = auth.uid(), resuelto_at = now()
   WHERE id = _incidencia_id;

  INSERT INTO incidencias_chasis_eventos (incidencia_id, estatus_anterior, estatus_nuevo, nota, actor)
  VALUES (_incidencia_id, _i.estatus, _resultado, trim(_resolucion), auth.uid());

  _estatus_chasis := public._sincronizar_estatus_chasis(_i.chasis_id);
  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'folio', _i.folio, 'resultado', _resultado,
    'ns_chasis', _i.ns_chasis, 'estatus_chasis', _estatus_chasis);
END; $$;

GRANT EXECUTE ON FUNCTION public.resolver_incidencia_chasis(uuid,text,text,text) TO authenticated;

-- 4.4 · Reabrir. Un chasis marcado no útil al que después le dan garantía —
-- o que sí se pudo adaptar — vuelve a revisión sin perder su historia.
CREATE OR REPLACE FUNCTION public.reabrir_incidencia_chasis(
  _incidencia_id uuid, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _i record; _estatus_chasis text;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede reabrir incidencias';
  END IF;
  IF _motivo IS NULL OR length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Se requiere un motivo (mínimo 5 caracteres)';
  END IF;

  SELECT * INTO _i FROM incidencias_chasis WHERE id = _incidencia_id;
  IF _i IS NULL THEN RAISE EXCEPTION 'Incidencia no encontrada'; END IF;
  IF _i.estatus IN ('abierta','en_revision') THEN
    RAISE EXCEPTION 'La incidencia % ya está abierta', _i.folio;
  END IF;
  IF EXISTS (SELECT 1 FROM incidencias_chasis
              WHERE chasis_id = _i.chasis_id AND estatus IN ('abierta','en_revision')) THEN
    RAISE EXCEPTION 'El chasis % ya tiene otro reporte abierto', _i.ns_chasis;
  END IF;

  UPDATE incidencias_chasis
     SET estatus = 'en_revision', retiene_chasis = true,
         resuelto_por = NULL, resuelto_at = NULL,
         revisado_por = auth.uid(), revisado_at = now()
   WHERE id = _incidencia_id;

  INSERT INTO incidencias_chasis_eventos (incidencia_id, estatus_anterior, estatus_nuevo, nota, actor)
  VALUES (_incidencia_id, _i.estatus, 'en_revision', trim(_motivo), auth.uid());

  _estatus_chasis := public._sincronizar_estatus_chasis(_i.chasis_id);
  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'folio', _i.folio, 'estatus_chasis', _estatus_chasis);
END; $$;

GRANT EXECUTE ON FUNCTION public.reabrir_incidencia_chasis(uuid,text) TO authenticated;


-- ============================================================================
-- BLOQUE 5 · Colores: dejar de llevar un contador y empezar a registrar
-- ============================================================================
-- El problema: inventario_colores era un contador que se incrementaba en la
-- importación y se decrementaba "a mano" en otros flujos, así que en cuanto
-- fábrica configuraba o liberaba una unidad, el número dejaba de ser cierto.
-- Ahora la tabla se recalcula de los datos reales (chasis + unidades) y se
-- amplía para decir lo que operación necesita ver: cuántas hay disponibles,
-- cuántas están comprometidas y cuántas están detenidas por una incidencia.

ALTER TABLE public.inventario_colores
  ADD COLUMN IF NOT EXISTS nombre_comercial        text,
  ADD COLUMN IF NOT EXISTS piezas_total            integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS piezas_en_revision      integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS piezas_garantia         integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS piezas_no_util          integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unidades_configuradas   integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unidades_libres         integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unidades_comprometidas  integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unidades_entregadas     integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS recalculado_at          timestamptz;

COMMENT ON COLUMN public.inventario_colores.cantidad_disponible IS
  'Chasis sanos sin unidad, por modelo de fábrica y color. Lo recalcula '
  'recalcular_inventario_colores() — no lo edites a mano.';

-- Recalcula todo desde los datos reales. Conserva umbral_alerta (es
-- configuración, no dato) y no borra filas: una combinación que se quedó en
-- cero sigue existiendo en cero para que se vea que se agotó.
CREATE OR REPLACE FUNCTION public.recalcular_inventario_colores()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _filas int;
BEGIN
  WITH ch AS (
    SELECT ic.modelo, upper(ic.color) AS color,
           count(*)                                                                     AS piezas_total,
           count(*) FILTER (WHERE ic.motocarro_id IS NULL AND ic.estatus = 'disponible') AS disponibles,
           count(*) FILTER (WHERE ic.estatus = 'en_revision')                            AS en_revision,
           count(*) FILTER (WHERE ic.estatus = 'garantia')                               AS garantia,
           count(*) FILTER (WHERE ic.estatus = 'no_util')                                AS no_util,
           count(*) FILTER (WHERE ic.motocarro_id IS NOT NULL)                           AS configuradas
      FROM inventario_chasis ic
     GROUP BY ic.modelo, upper(ic.color)
  ), un AS (
    -- "Libre" = vendible hoy: con los dos seriales y sin una incidencia que
    -- detenga su chasis.
    SELECT m.modelo, upper(m.color) AS color,
           count(*) FILTER (WHERE m.remision_id IS NULL
                              AND m.estatus_entrega <> 'ENTREGADA'
                              AND m.ns_chasis IS NOT NULL AND m.ns_motor IS NOT NULL
                              AND COALESCE(ic.estatus, 'disponible')
                                  NOT IN ('en_revision','garantia','no_util'))        AS libres,
           count(*) FILTER (WHERE m.remision_id IS NOT NULL
                              AND m.estatus_entrega <> 'ENTREGADA')                   AS comprometidas,
           count(*) FILTER (WHERE m.estatus_entrega = 'ENTREGADA')                    AS entregadas
      FROM motocarros m
      LEFT JOIN inventario_chasis ic ON ic.numero_chasis = m.ns_chasis
     GROUP BY m.modelo, upper(m.color)
  ), llaves AS (
    SELECT modelo, color FROM ch
    UNION
    SELECT modelo, color FROM un
  ), calc AS (
    SELECT k.modelo, k.color,
           COALESCE(ch.piezas_total,0)   AS piezas_total,
           COALESCE(ch.disponibles,0)    AS disponibles,
           COALESCE(ch.en_revision,0)    AS en_revision,
           COALESCE(ch.garantia,0)       AS garantia,
           COALESCE(ch.no_util,0)        AS no_util,
           COALESCE(ch.configuradas,0)   AS configuradas,
           COALESCE(un.libres,0)         AS libres,
           COALESCE(un.comprometidas,0)  AS comprometidas,
           COALESCE(un.entregadas,0)     AS entregadas,
           mp.nombre_comercial
      FROM llaves k
      LEFT JOIN ch ON ch.modelo = k.modelo AND ch.color = k.color
      LEFT JOIN un ON un.modelo = k.modelo AND un.color = k.color
      LEFT JOIN modelos_producto mp ON mp.modelo = k.modelo
  )
  INSERT INTO inventario_colores AS ic (
    modelo, color, nombre_comercial, cantidad_disponible, piezas_total,
    piezas_en_revision, piezas_garantia, piezas_no_util, unidades_configuradas,
    unidades_libres, unidades_comprometidas, unidades_entregadas,
    umbral_alerta, updated_at, recalculado_at)
  SELECT modelo, color, COALESCE(nombre_comercial, modelo), disponibles, piezas_total,
         en_revision, garantia, no_util, configuradas,
         libres, comprometidas, entregadas,
         3, now(), now()
    FROM calc
  ON CONFLICT (modelo, color) DO UPDATE SET
    nombre_comercial       = EXCLUDED.nombre_comercial,
    cantidad_disponible    = EXCLUDED.cantidad_disponible,
    piezas_total           = EXCLUDED.piezas_total,
    piezas_en_revision     = EXCLUDED.piezas_en_revision,
    piezas_garantia        = EXCLUDED.piezas_garantia,
    piezas_no_util         = EXCLUDED.piezas_no_util,
    unidades_configuradas  = EXCLUDED.unidades_configuradas,
    unidades_libres        = EXCLUDED.unidades_libres,
    unidades_comprometidas = EXCLUDED.unidades_comprometidas,
    unidades_entregadas    = EXCLUDED.unidades_entregadas,
    updated_at             = now(),
    recalculado_at         = now();

  GET DIAGNOSTICS _filas = ROW_COUNT;

  -- Combinaciones que ya no tienen nada: quedan en cero, no se borran.
  UPDATE inventario_colores SET
    cantidad_disponible = 0, piezas_total = 0, piezas_en_revision = 0,
    piezas_garantia = 0, piezas_no_util = 0, unidades_configuradas = 0,
    unidades_libres = 0, unidades_comprometidas = 0, unidades_entregadas = 0,
    updated_at = now(), recalculado_at = now()
  WHERE NOT EXISTS (SELECT 1 FROM inventario_chasis ic
                     WHERE ic.modelo = inventario_colores.modelo
                       AND upper(ic.color) = inventario_colores.color)
    AND NOT EXISTS (SELECT 1 FROM motocarros m
                     WHERE m.modelo = inventario_colores.modelo
                       AND upper(m.color) = inventario_colores.color)
    AND (cantidad_disponible <> 0 OR piezas_total <> 0 OR unidades_libres <> 0
         OR unidades_comprometidas <> 0 OR unidades_entregadas <> 0);

  RETURN jsonb_build_object('ok', true, 'combinaciones', _filas);
END; $$;

GRANT EXECUTE ON FUNCTION public.recalcular_inventario_colores() TO authenticated;

-- Las dos funciones viejas quedan como envoltura: cualquier flujo que las
-- siga llamando (importación, cierre de remisión) ahora recalcula en lugar de
-- sumar/restar a ciegas. Se conservan las firmas para no romper llamadas.
CREATE OR REPLACE FUNCTION public.incrementar_inventario_color(
  _modelo text, _color text, _cantidad integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM public.recalcular_inventario_colores();
END; $$;

CREATE OR REPLACE FUNCTION public.decrementar_inventario_color(
  _modelo text, _color text, _cantidad integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM public.recalcular_inventario_colores();
END; $$;

GRANT EXECUTE ON FUNCTION public.incrementar_inventario_color(text,text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decrementar_inventario_color(text,text,integer) TO authenticated;

-- Que nadie tenga que acordarse de recalcular: cualquier movimiento de
-- piezas o de unidades deja el conteo al día. Es a nivel sentencia (no fila)
-- para que una importación de 125 chasis no recalcule 125 veces por fila.
CREATE OR REPLACE FUNCTION public._trg_recalcular_colores() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM public.recalcular_inventario_colores();
  RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_colores_desde_chasis ON public.inventario_chasis;
CREATE TRIGGER trg_colores_desde_chasis
  AFTER INSERT OR UPDATE OR DELETE ON public.inventario_chasis
  FOR EACH STATEMENT EXECUTE FUNCTION public._trg_recalcular_colores();

DROP TRIGGER IF EXISTS trg_colores_desde_motocarros ON public.motocarros;
CREATE TRIGGER trg_colores_desde_motocarros
  AFTER INSERT OR UPDATE OR DELETE ON public.motocarros
  FOR EACH STATEMENT EXECUTE FUNCTION public._trg_recalcular_colores();

SELECT public.recalcular_inventario_colores();


-- ============================================================================
-- BLOQUE 6 · La foto que pide dirección: por color, qué hay y qué se debe
-- ============================================================================
-- Agrupada por NOMBRE COMERCIAL (lo que habla ventas y lo que dicen las
-- remisiones), no por código de fábrica: un DZ300Q7 y un legacy "300cc 2026"
-- son la misma cosa para quien vende.

-- DROP antes de CREATE: la vista fue cambiando de columnas entre versiones y
-- CREATE OR REPLACE VIEW no admite cambios de estructura.
DROP VIEW IF EXISTS public.v_stock_modelo_color;
CREATE VIEW public.v_stock_modelo_color AS
WITH ch AS (
  SELECT upper(COALESCE(mp.nombre_comercial, ic.modelo)) AS modelo,
         upper(ic.color) AS color,
         count(*) FILTER (WHERE ic.motocarro_id IS NULL AND ic.estatus = 'disponible') AS piezas_disponibles,
         count(*) FILTER (WHERE ic.estatus = 'en_revision')                            AS piezas_en_revision,
         count(*) FILTER (WHERE ic.estatus = 'garantia')                               AS piezas_garantia,
         count(*) FILTER (WHERE ic.estatus = 'no_util')                                AS piezas_no_util
    FROM inventario_chasis ic
    LEFT JOIN modelos_producto mp ON mp.modelo = ic.modelo
   GROUP BY 1, 2
), un AS (
  SELECT upper(COALESCE(mp.nombre_comercial, m.modelo)) AS modelo,
         upper(m.color) AS color,
         -- Libre = vendible hoy: con los dos seriales y sin incidencia que
         -- detenga su chasis.
         count(*) FILTER (WHERE m.remision_id IS NULL AND m.estatus_entrega <> 'ENTREGADA'
                            AND m.ns_chasis IS NOT NULL AND m.ns_motor IS NOT NULL
                            AND COALESCE(ic.estatus,'disponible')
                                NOT IN ('en_revision','garantia','no_util'))        AS unidades_libres,
         count(*) FILTER (WHERE m.remision_id IS NULL
                            AND (m.ns_chasis IS NULL OR m.ns_motor IS NULL))        AS unidades_sin_serial,
         count(*) FILTER (WHERE m.remision_id IS NULL AND m.estatus_entrega <> 'ENTREGADA'
                            AND COALESCE(ic.estatus,'disponible')
                                IN ('en_revision','garantia','no_util'))            AS unidades_detenidas,
         count(*) FILTER (WHERE m.remision_id IS NOT NULL
                            AND m.estatus_entrega <> 'ENTREGADA')                   AS unidades_comprometidas,
         count(*) FILTER (WHERE m.estatus_entrega = 'ENTREGADA')                    AS unidades_entregadas
    FROM motocarros m
    LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
    LEFT JOIN inventario_chasis ic ON ic.numero_chasis = m.ns_chasis
   GROUP BY 1, 2
), pedido AS (
  SELECT upper(COALESCE(NULLIF(trim(ri.modelo),''), 'SIN MODELO')) AS modelo,
         upper(COALESCE(NULLIF(trim(ri.color),''), 'SIN COLOR'))   AS color,
         sum(GREATEST(ri.cantidad, 0)) AS solicitadas
    FROM remision_items ri
    JOIN remisiones r ON r.id = ri.remision_id
   WHERE ri.tipo_servicio = 'motocarro'
     AND r.estatus IN ('NUEVA','PARCIAL')
   GROUP BY 1, 2
), asignado AS (
  SELECT upper(COALESCE(mp.nombre_comercial, m.modelo)) AS modelo,
         upper(m.color) AS color,
         count(*) AS asignadas
    FROM motocarros m
    JOIN remisiones r ON r.id = m.remision_id
    LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
   WHERE r.estatus IN ('NUEVA','PARCIAL')
   GROUP BY 1, 2
), llaves AS (
  SELECT modelo, color FROM ch
  UNION SELECT modelo, color FROM un
  UNION SELECT modelo, color FROM pedido
)
SELECT k.modelo                                     AS modelo_comercial,
       k.color,
       COALESCE(ch.piezas_disponibles, 0)           AS piezas_disponibles,
       COALESCE(ch.piezas_en_revision, 0)           AS piezas_en_revision,
       COALESCE(ch.piezas_garantia, 0)              AS piezas_garantia,
       COALESCE(ch.piezas_no_util, 0)               AS piezas_no_util,
       COALESCE(un.unidades_libres, 0)              AS unidades_libres,
       COALESCE(un.unidades_sin_serial, 0)          AS unidades_sin_serial,
       COALESCE(un.unidades_detenidas, 0)           AS unidades_detenidas,
       COALESCE(un.unidades_comprometidas, 0)       AS unidades_comprometidas,
       COALESCE(un.unidades_entregadas, 0)          AS unidades_entregadas,
       COALESCE(p.solicitadas, 0)                   AS solicitadas,
       COALESCE(a.asignadas, 0)                     AS asignadas,
       GREATEST(COALESCE(p.solicitadas,0) - COALESCE(a.asignadas,0), 0) AS demanda_pendiente,
       -- Lo que se puede prometer hoy con serial, menos lo que ya se debe.
       COALESCE(un.unidades_libres,0)
         - GREATEST(COALESCE(p.solicitadas,0) - COALESCE(a.asignadas,0), 0) AS holgura_con_serial,
       -- Contando además las piezas sanas que fábrica todavía puede configurar.
       COALESCE(un.unidades_libres,0) + COALESCE(ch.piezas_disponibles,0)
         - GREATEST(COALESCE(p.solicitadas,0) - COALESCE(a.asignadas,0), 0) AS holgura_con_piezas
  FROM llaves k
  LEFT JOIN ch      ON ch.modelo = k.modelo AND ch.color = k.color
  LEFT JOIN un      ON un.modelo = k.modelo AND un.color = k.color
  LEFT JOIN pedido  p ON p.modelo = k.modelo AND p.color = k.color
  LEFT JOIN asignado a ON a.modelo = k.modelo AND a.color = k.color;

REVOKE ALL ON public.v_stock_modelo_color FROM anon;
GRANT SELECT ON public.v_stock_modelo_color TO authenticated;

COMMENT ON VIEW public.v_stock_modelo_color IS
  'Por modelo comercial y color: piezas sanas, piezas detenidas por incidencia, '
  'unidades libres/comprometidas y demanda pendiente de remisiones NUEVA/PARCIAL.';


-- ============================================================================
-- BLOQUE 7 · El proceso no cierra sin NS chasis y NS motor
-- ============================================================================
-- Una unidad sin los dos seriales no existe para efectos de venta: no se
-- puede facturar, ni entregar, ni rastrear en garantía. Se valida en la base
-- (no sólo en la pantalla) en el momento de la transición, para no dejar
-- atrapadas las unidades legadas que ya están ARMADO sin serial: a ésas se
-- les puede seguir editando y el serial se les captura cuando se tenga.

CREATE OR REPLACE FUNCTION public.exigir_serial_para_cerrar() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE _faltan text[] := '{}';
BEGIN
  IF NULLIF(trim(COALESCE(NEW.ns_chasis,'')),'') IS NULL THEN
    _faltan := array_append(_faltan, 'NS chasis');
  END IF;
  IF NULLIF(trim(COALESCE(NEW.ns_motor,'')),'') IS NULL THEN
    _faltan := array_append(_faltan, 'NS motor');
  END IF;

  IF array_length(_faltan,1) IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.estatus_armado IN ('ARMADO','LISTO')
     AND (TG_OP = 'INSERT' OR OLD.estatus_armado IS DISTINCT FROM NEW.estatus_armado) THEN
    RAISE EXCEPTION 'La unidad #% no puede pasar a % sin registrar %: fábrica tiene que capturarlo primero.',
      NEW.orden_armado, NEW.estatus_armado, array_to_string(_faltan, ' y ');
  END IF;

  IF NEW.estatus_entrega = 'ENTREGADA'
     AND (TG_OP = 'INSERT' OR OLD.estatus_entrega IS DISTINCT FROM NEW.estatus_entrega) THEN
    RAISE EXCEPTION 'La unidad #% no puede marcarse ENTREGADA sin registrar %.',
      NEW.orden_armado, array_to_string(_faltan, ' y ');
  END IF;

  IF NEW.remision_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR OLD.remision_id IS DISTINCT FROM NEW.remision_id) THEN
    RAISE EXCEPTION 'La unidad #% no se puede asignar a una remisión sin registrar %.',
      NEW.orden_armado, array_to_string(_faltan, ' y ');
  END IF;

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_exigir_serial_para_cerrar ON public.motocarros;
CREATE TRIGGER trg_exigir_serial_para_cerrar
  BEFORE INSERT OR UPDATE ON public.motocarros
  FOR EACH ROW EXECUTE FUNCTION public.exigir_serial_para_cerrar();


-- ============================================================================
-- BLOQUE 8 · Configurar unidad: respeta incidencias y arrastra el reporte
-- ============================================================================
-- Dos cambios sobre la versión de KIT-3:
--   · un chasis retenido / en garantía / no útil no se puede configurar;
--   · si el chasis traía un reporte, la incidencia queda ligada a la unidad
--     para que Producción vea con qué viene esa unidad.

CREATE OR REPLACE FUNCTION public.configurar_unidad(
  _chasis_id uuid, _motor_id uuid, _orden integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _ch record; _mo record; _orden_final int; _moto_id uuid; _inc record;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede configurar unidades';
  END IF;

  SELECT * INTO _ch FROM inventario_chasis WHERE id = _chasis_id;
  IF _ch IS NULL THEN RAISE EXCEPTION 'Chasis no encontrado'; END IF;
  IF _ch.motocarro_id IS NOT NULL THEN
    RAISE EXCEPTION 'El chasis % ya está asignado a una unidad', _ch.numero_chasis;
  END IF;

  IF public.chasis_bloqueado(_chasis_id) THEN
    SELECT folio, estatus, parte_afectada INTO _inc
      FROM incidencias_chasis
     WHERE chasis_id = _chasis_id
       AND (estatus IN ('no_util','garantia')
            OR (estatus IN ('abierta','en_revision') AND retiene_chasis))
     ORDER BY reportado_at DESC LIMIT 1;
    RAISE EXCEPTION 'El chasis % está detenido por la incidencia % (%)%: resuélvela antes de configurarlo',
      _ch.numero_chasis, _inc.folio, _inc.estatus, COALESCE(' — ' || _inc.parte_afectada, '');
  END IF;

  SELECT * INTO _mo FROM inventario_motor WHERE id = _motor_id;
  IF _mo IS NULL THEN RAISE EXCEPTION 'Motor no encontrado'; END IF;
  IF _mo.motocarro_id IS NOT NULL THEN
    RAISE EXCEPTION 'El motor % ya está asignado a una unidad', _mo.numero_motor;
  END IF;

  _orden_final := COALESCE(_orden, (SELECT COALESCE(max(orden_armado),0)+1 FROM motocarros));
  IF EXISTS (SELECT 1 FROM motocarros WHERE orden_armado = _orden_final) THEN
    RAISE EXCEPTION 'El orden de armado % ya está ocupado', _orden_final;
  END IF;

  INSERT INTO motocarros (orden_armado, modelo, color, ns_chasis, ns_motor,
                          contenedor_id, estatus_armado, estatus_entrega)
  VALUES (_orden_final, _ch.modelo, _ch.color, _ch.numero_chasis, _mo.numero_motor,
          _ch.contenedor_id, 'PENDIENTE', 'NO_APLICA')
  RETURNING id INTO _moto_id;

  UPDATE inventario_chasis SET motocarro_id = _moto_id, estatus = 'configurado',
         fecha_configuracion = now() WHERE id = _chasis_id;
  UPDATE inventario_motor  SET motocarro_id = _moto_id, estatus = 'configurado',
         fecha_configuracion = now() WHERE id = _motor_id;

  -- El historial de la pieza viaja con la unidad (adaptaciones incluidas).
  UPDATE incidencias_chasis SET motocarro_id = _moto_id WHERE chasis_id = _chasis_id;

  UPDATE contenedores c SET total_unidades =
    (SELECT count(*) FROM inventario_chasis ic
      WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
  WHERE c.id = _ch.contenedor_id;

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'motocarro_id', _moto_id,
    'orden_armado', _orden_final, 'ns_chasis', _ch.numero_chasis,
    'ns_motor', _mo.numero_motor,
    'modelos_coinciden', (_ch.modelo = _mo.modelo),
    'incidencias_arrastradas', (SELECT count(*) FROM incidencias_chasis WHERE chasis_id = _chasis_id));
END; $$;

GRANT EXECUTE ON FUNCTION public.configurar_unidad(uuid, uuid, integer) TO authenticated;

-- Liberar la unidad devuelve las piezas al pool y desliga el reporte de la
-- unidad (pero no del chasis: ahí es donde vive la historia).
CREATE OR REPLACE FUNCTION public.desconfigurar_unidad(_motocarro_id uuid, _motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _m record; _chasis_ids uuid[];
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede liberar unidades';
  END IF;
  IF _motivo IS NULL OR length(trim(_motivo)) < 5 THEN
    RAISE EXCEPTION 'Se requiere un motivo';
  END IF;

  SELECT * INTO _m FROM motocarros WHERE id = _motocarro_id;
  IF _m IS NULL THEN RAISE EXCEPTION 'Unidad no encontrada'; END IF;
  IF _m.remision_id IS NOT NULL THEN
    RAISE EXCEPTION 'La unidad ya está asignada a una remisión; no se puede liberar';
  END IF;
  IF _m.estatus_armado <> 'PENDIENTE' THEN
    RAISE EXCEPTION 'La unidad ya entró a armado; no se puede liberar';
  END IF;

  SELECT COALESCE(array_agg(id), '{}') INTO _chasis_ids
    FROM inventario_chasis WHERE motocarro_id = _motocarro_id;

  UPDATE inventario_chasis SET motocarro_id = NULL, estatus = 'disponible',
         fecha_configuracion = NULL WHERE motocarro_id = _motocarro_id;
  UPDATE inventario_motor  SET motocarro_id = NULL, estatus = 'disponible',
         fecha_configuracion = NULL WHERE motocarro_id = _motocarro_id;

  DELETE FROM motocarros WHERE id = _motocarro_id;

  -- Reponer el estatus que le corresponde al chasis según sus incidencias:
  -- un chasis con garantía abierta no debe volver a 'disponible'.
  IF array_length(_chasis_ids,1) IS NOT NULL THEN
    PERFORM public._sincronizar_estatus_chasis(cid) FROM unnest(_chasis_ids) AS cid;
  END IF;

  UPDATE contenedores c SET total_unidades =
    (SELECT count(*) FROM inventario_chasis ic
      WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
  WHERE c.id = _m.contenedor_id;

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object('ok', true, 'liberada', _m.orden_armado);
END; $$;

GRANT EXECUTE ON FUNCTION public.desconfigurar_unidad(uuid, text) TO authenticated;


-- ============================================================================
-- BLOQUE 9 · La asignación respeta el pedido: modelo, color y serial
-- ============================================================================
-- Lo que estaba pasando: la bandeja llamaba a reintentar_asignar_remision,
-- que sólo miraba remisiones.color_solicitado (una columna que se llena
-- después de crear la remisión) e ignoraba por completo remision_items —
-- donde vive el pedido real ("300cc 2026 BLANCO ×5"). Resultado: se
-- asignaban unidades de otro color/modelo, o no se asignaba nada y nadie
-- sabía por qué.
--
-- Ahora se asigna línea por línea del pedido y se devuelve el detalle: qué
-- se pidió, qué se asignó, qué falta y cuántas quedan disponibles de ese
-- color. Y sólo entran unidades que se pueden vender de verdad: con NS
-- chasis y NS motor, y sin un chasis detenido por incidencia.

CREATE OR REPLACE FUNCTION public.asignar_remision_items(_remision_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _r record; _linea record; _n int; _total int := 0;
  _ya int; _faltan int; _disp int; _sin_serial int; _detenidas int;
  _detalle jsonb := '[]'::jsonb; _hay_items boolean;
BEGIN
  IF NOT (
    has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role) OR
    EXISTS (SELECT 1 FROM remisiones rr WHERE rr.id = _remision_id AND rr.vendedor_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'No autorizado para asignar unidades a esta remisión';
  END IF;

  SELECT * INTO _r FROM remisiones WHERE id = _remision_id;
  IF _r IS NULL THEN RAISE EXCEPTION 'Remisión no encontrada'; END IF;

  SELECT EXISTS (SELECT 1 FROM remision_items
                  WHERE remision_id = _remision_id AND tipo_servicio = 'motocarro')
    INTO _hay_items;

  FOR _linea IN
    -- Con configuración del pedido: una línea por modelo comercial + color.
    SELECT upper(COALESCE(NULLIF(trim(ri.modelo),''), '')) AS modelo,
           upper(COALESCE(NULLIF(trim(ri.color),''), ''))  AS color,
           sum(GREATEST(ri.cantidad,0))::int               AS cantidad
      FROM remision_items ri
     WHERE _hay_items AND ri.remision_id = _remision_id AND ri.tipo_servicio = 'motocarro'
     GROUP BY 1, 2
    UNION ALL
    -- Sin configuración: se cae a lo que traiga la remisión (comportamiento
    -- viejo), pero se avisa en el detalle que el pedido no está capturado.
    SELECT upper(COALESCE(NULLIF(trim(_r.modelo_solicitado),''), '')),
           upper(COALESCE(NULLIF(trim(_r.color_solicitado),''), '')),
           _r.total_unidades_solicitadas
     WHERE NOT _hay_items
  LOOP
    -- Lo que ya está asignado a esta remisión y cuadra con la línea.
    SELECT count(*) INTO _ya
      FROM motocarros m
      LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
     WHERE m.remision_id = _remision_id
       AND (_linea.color  = '' OR upper(m.color) = _linea.color)
       AND (_linea.modelo = '' OR upper(COALESCE(mp.nombre_comercial, m.modelo)) = _linea.modelo);

    _faltan := GREATEST(_linea.cantidad - _ya, 0);

    IF _faltan > 0 THEN
      WITH candidatos AS (
        SELECT m.id
          FROM motocarros m
          LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
          LEFT JOIN inventario_chasis ic ON ic.numero_chasis = m.ns_chasis
         WHERE m.remision_id IS NULL
           AND m.estatus_armado IN ('PENDIENTE','EN_PROCESO','ARMADO','LISTO')
           AND m.estatus_entrega <> 'ENTREGADA'
           -- El proceso no cierra sin serial: una unidad sin NS no se vende.
           AND NULLIF(trim(COALESCE(m.ns_chasis,'')),'') IS NOT NULL
           AND NULLIF(trim(COALESCE(m.ns_motor ,'')),'') IS NOT NULL
           -- Ni una unidad cuyo chasis está detenido por una incidencia.
           AND (ic.id IS NULL OR NOT public.chasis_bloqueado(ic.id))
           AND (_linea.color  = '' OR upper(m.color) = _linea.color)
           AND (_linea.modelo = '' OR upper(COALESCE(mp.nombre_comercial, m.modelo)) = _linea.modelo)
         ORDER BY m.orden_armado ASC
         LIMIT _faltan
         FOR UPDATE OF m SKIP LOCKED
      )
      UPDATE motocarros m
         SET remision_id = _remision_id,
             estatus_entrega = CASE WHEN m.estatus_entrega = 'NO_APLICA'
                                    THEN 'PROGRAMADA' ELSE m.estatus_entrega END
        FROM candidatos c
       WHERE m.id = c.id;

      GET DIAGNOSTICS _n = ROW_COUNT;
    ELSE
      _n := 0;
    END IF;

    _total := _total + _n;

    -- Qué queda para esa combinación, para poder explicar el faltante. Una
    -- unidad cuyo chasis está detenido por una incidencia no cuenta como
    -- disponible: se reporta aparte para que se sepa por qué falta.
    SELECT count(*) FILTER (WHERE NULLIF(trim(COALESCE(m.ns_chasis,'')),'') IS NOT NULL
                              AND NULLIF(trim(COALESCE(m.ns_motor ,'')),'') IS NOT NULL
                              AND (ic.id IS NULL OR NOT public.chasis_bloqueado(ic.id))),
           count(*) FILTER (WHERE NULLIF(trim(COALESCE(m.ns_chasis,'')),'') IS NULL
                               OR NULLIF(trim(COALESCE(m.ns_motor ,'')),'') IS NULL),
           count(*) FILTER (WHERE ic.id IS NOT NULL AND public.chasis_bloqueado(ic.id))
      INTO _disp, _sin_serial, _detenidas
      FROM motocarros m
      LEFT JOIN modelos_producto mp ON mp.modelo = m.modelo
      LEFT JOIN inventario_chasis ic ON ic.numero_chasis = m.ns_chasis
     WHERE m.remision_id IS NULL
       AND m.estatus_entrega <> 'ENTREGADA'
       AND (_linea.color  = '' OR upper(m.color) = _linea.color)
       AND (_linea.modelo = '' OR upper(COALESCE(mp.nombre_comercial, m.modelo)) = _linea.modelo);

    _detalle := _detalle || jsonb_build_object(
      'modelo', NULLIF(_linea.modelo,''), 'color', NULLIF(_linea.color,''),
      'solicitadas', _linea.cantidad, 'ya_asignadas', _ya,
      'asignadas_ahora', _n, 'faltan', GREATEST(_faltan - _n, 0),
      'disponibles_con_serial', _disp, 'unidades_sin_serial', _sin_serial,
      'unidades_detenidas', _detenidas,
      'piezas_por_configurar', (
        SELECT count(*) FROM inventario_chasis ic
        LEFT JOIN modelos_producto mp2 ON mp2.modelo = ic.modelo
         WHERE ic.motocarro_id IS NULL AND ic.estatus = 'disponible'
           AND (_linea.color  = '' OR upper(ic.color) = _linea.color)
           AND (_linea.modelo = '' OR upper(COALESCE(mp2.nombre_comercial, ic.modelo)) = _linea.modelo)
      ));
  END LOOP;

  UPDATE remisiones r
     SET estatus = CASE
       WHEN (SELECT count(*) FROM motocarros mm WHERE mm.remision_id = r.id) >= r.total_unidades_solicitadas
         THEN 'COMPLETA'::estatus_remision
       WHEN (SELECT count(*) FROM motocarros mm WHERE mm.remision_id = r.id) > 0
         THEN 'PARCIAL'::estatus_remision
       ELSE 'NUEVA'::estatus_remision END
   WHERE r.id = _remision_id;

  RETURN jsonb_build_object('ok', true, 'asignadas', _total,
    'pedido_capturado', _hay_items, 'detalle', _detalle);
END; $$;

GRANT EXECUTE ON FUNCTION public.asignar_remision_items(uuid) TO authenticated;

-- Las dos RPC viejas delegan en la nueva para que no queden dos criterios de
-- asignación vivos al mismo tiempo.
CREATE OR REPLACE FUNCTION public.reintentar_asignar_remision(_remision_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _r jsonb;
BEGIN
  _r := public.asignar_remision_items(_remision_id);
  RETURN COALESCE((_r->>'asignadas')::int, 0);
END; $$;

GRANT EXECUTE ON FUNCTION public.reintentar_asignar_remision(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.asignar_chasis_remision(
  _remision_id uuid, _cantidad integer, _color text DEFAULT NULL::text, _modelo text DEFAULT NULL::text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE asignados integer := 0;
BEGIN
  IF NOT (
    public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'fabrica') OR
    EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = _remision_id AND r.vendedor_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'No autorizado para asignar chasis a esta remisión';
  END IF;

  WITH candidatos AS (
    SELECT m.id
      FROM public.motocarros m
      LEFT JOIN public.modelos_producto mp ON mp.modelo = m.modelo
      LEFT JOIN public.inventario_chasis ic ON ic.numero_chasis = m.ns_chasis
     WHERE m.remision_id IS NULL
       AND m.estatus_armado IN ('PENDIENTE','EN_PROCESO','ARMADO','LISTO')
       AND m.estatus_entrega <> 'ENTREGADA'
       AND NULLIF(trim(COALESCE(m.ns_chasis,'')),'') IS NOT NULL
       AND NULLIF(trim(COALESCE(m.ns_motor ,'')),'') IS NOT NULL
       AND (ic.id IS NULL OR NOT public.chasis_bloqueado(ic.id))
       AND (_color  IS NULL OR upper(m.color) = upper(_color))
       AND (_modelo IS NULL OR upper(COALESCE(mp.nombre_comercial, m.modelo)) = upper(_modelo))
     ORDER BY m.orden_armado ASC
     LIMIT _cantidad
     FOR UPDATE OF m SKIP LOCKED
  )
  UPDATE public.motocarros m
     SET remision_id = _remision_id,
         estatus_entrega = CASE WHEN m.estatus_entrega = 'NO_APLICA'
                                THEN 'PROGRAMADA' ELSE m.estatus_entrega END
    FROM candidatos c
   WHERE m.id = c.id;

  GET DIAGNOSTICS asignados = ROW_COUNT;

  UPDATE public.remisiones r
     SET estatus = CASE
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) >= r.total_unidades_solicitadas
         THEN 'COMPLETA'::estatus_remision
       WHEN (SELECT COUNT(*) FROM public.motocarros mm WHERE mm.remision_id = r.id) > 0
         THEN 'PARCIAL'::estatus_remision
       ELSE 'NUEVA'::estatus_remision END
   WHERE r.id = _remision_id;

  RETURN asignados;
END; $$;

GRANT EXECUTE ON FUNCTION public.asignar_chasis_remision(uuid, integer, text, text) TO authenticated;


-- ============================================================================
-- BLOQUE 10 · No adivinar en el alta de la remisión
-- ============================================================================
-- El trigger de alta asignaba unidades ANTES de que existiera la
-- configuración del pedido (la app inserta la remisión y hasta después los
-- remision_items), así que amarraba unidades de cualquier color. Ahora sólo
-- auto-asigna cuando la remisión ya trae color/modelo explícito; si no, la
-- remisión nace en NUEVA y se asigna desde la bandeja cuando el pedido esté
-- capturado.

CREATE OR REPLACE FUNCTION public.auto_asignar_motocarros_remision()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _color text; _modelo text; _asignados int;
BEGIN
  _color  := NULLIF(upper(trim(COALESCE(NEW.color_solicitado,''))), '');
  _modelo := NULLIF(upper(trim(COALESCE(NEW.modelo_solicitado,''))), '');

  IF _color IS NULL AND _modelo IS NULL THEN
    RETURN NEW;  -- sin intención explícita no se amarra nada
  END IF;

  _asignados := public.asignar_chasis_remision(
    NEW.id, NEW.total_unidades_solicitadas, _color, _modelo);

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_auto_asignar_motocarros ON public.remisiones;
CREATE TRIGGER trg_auto_asignar_motocarros
  AFTER INSERT ON public.remisiones
  FOR EACH ROW EXECUTE FUNCTION public.auto_asignar_motocarros_remision();


-- ============================================================================
-- BLOQUE 11 · Cierre: dejar los estatus de chasis consistentes
-- ============================================================================
-- Todavía no hay incidencias cargadas, así que esto sólo endereza chasis cuyo
-- estatus no cuadra con si tienen unidad o no (p.ej. 'asignado' de una
-- importación vieja). Los estatus nuevos los maneja _sincronizar_estatus_chasis.

UPDATE public.inventario_chasis
   SET estatus = 'configurado'
 WHERE motocarro_id IS NOT NULL
   AND estatus NOT IN ('configurado','asignado','en_revision','garantia','no_util');

UPDATE public.inventario_chasis
   SET estatus = 'disponible'
 WHERE motocarro_id IS NULL
   AND estatus NOT IN ('disponible','en_revision','garantia','no_util');

SELECT public.recalcular_inventario_colores();

DO $$
DECLARE _ch int; _dis int; _un int; _col int;
BEGIN
  SELECT count(*) INTO _ch  FROM public.inventario_chasis;
  SELECT count(*) INTO _dis FROM public.inventario_chasis WHERE motocarro_id IS NULL AND estatus = 'disponible';
  SELECT count(*) INTO _un  FROM public.motocarros;
  SELECT count(*) INTO _col FROM public.inventario_colores;
  RAISE NOTICE 'KIT-4 aplicado · chasis: % (disponibles: %) · unidades: % · combinaciones modelo/color: %',
    _ch, _dis, _un, _col;
END $$;
