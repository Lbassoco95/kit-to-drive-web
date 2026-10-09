-- ============================================================================
-- El operador puede corregir y complementar sus remisiones, dejando el motivo
-- Fecha: 2026-09-02
--
-- Qué estaba pasando
-- ------------------
-- Corregir una remisión ya capturada era, en la práctica, cosa del
-- administrador: `remision_items` nunca tuvo política de UPDATE (nadie podía
-- cambiar un renglón) y su DELETE pide el rol legado `admin`, o sea sólo el
-- administrador global. El encabezado sí lo puede editar su dueño
-- (`actualizar remisiones` cae a `vendedor_id = auth.uid()`), pero sin poder
-- tocar los renglones no se puede cambiar un modelo, un color, una cantidad,
-- ni agregar unidades a una remisión pasada — el «complemento» que pide
-- Comercial.
--
-- Qué queda
-- ---------
--  1. `public.puede_editar_remision(remision, usuario)`: la escalera de
--     Comercial en una sola función. Dirección con mando y el administrador
--     global pueden todo; supervisor y administrador de Comercial, todo lo de
--     su área; el operador, lo que él capturó. Quien está dado de baja
--     (`profiles.activo = false`) no pasa.
--  2. `remision_items` gana UPDATE y DELETE con esa escalera, y su INSERT pasa
--     a regirse por ella (antes dejaba fuera al supervisor y, a la vez, dejaba
--     que cualquier vendedor metiera renglones en la remisión de otro).
--  3. `remisiones` gana un UPDATE por la misma escalera, y un INSERT que le
--     devuelve al supervisor de Comercial la capacidad de capturar (hoy no
--     puede: `crear remisiones` sólo conoce los roles legados viejos).
--  4. `remision_items.orden_linea`: a qué línea del pedido pertenece cada
--     renglón. Antes la jerarquía «motocarro + sus servicios» vivía en el orden
--     de inserción, y al editar se desordenaba (una cabina agregada después
--     aparecía colgada de otra unidad). Se rellena para lo ya capturado con el
--     orden en que se insertó.
--  5. `remisiones_bitacora`: quién modificó qué remisión, cuándo y **por qué**.
--     El motivo es obligatorio en la tabla, no sólo en la pantalla.
--
-- Las políticas nuevas son ADITIVAS salvo una: en RLS lo permisivo se suma con
-- OR, así que agregar no le quita permisos a nadie. La excepción es el INSERT
-- de `remision_items`, que sí se reemplaza — ver el bloque 3, donde se explica
-- por qué la vieja dejaba de menos y de más a la vez.
--
-- Por qué no usa `es_area()` / `supervisa_area()`
-- ----------------------------------------------
-- La primera versión de este script los exigía en su preflight y se negó a
-- correr en producción: al menos uno de los dos no estaba. (El enum `user_area`
-- y las columnas `user_roles.area/nivel` sí; `es_area()` también, según el
-- diagnóstico — que hasta hoy sólo revisaba ESE helper de los ocho que crea
-- 20260823000005, y por eso reportaba el script como aplicado.) El bloque 6 de
-- aquí abajo imprime, al correr, cuáles hay y cuáles no.
--
-- Sea cual sea el estado, este arreglo ya no depende de ellos: `rol_comercial()`
-- lee `user_roles.area/nivel` directamente y, cuando vienen vacíos (usuario sin
-- migrar), deduce el par del rol legado igual que `desdeRolLegacy()` en la app.
-- Si los helpers están, o se agregan después, esto sigue siendo correcto: se
-- apoya en los mismos datos, no en las funciones.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.remisiones')     IS NULL THEN _faltan := _faltan || 'tabla remisiones'::text;     END IF;
  IF to_regclass('public.remision_items') IS NULL THEN _faltan := _faltan || 'tabla remision_items'::text; END IF;
  IF to_regclass('public.user_roles')     IS NULL THEN _faltan := _faltan || 'tabla user_roles'::text;     END IF;
  IF to_regclass('public.profiles')       IS NULL THEN _faltan := _faltan || 'tabla profiles'::text;       END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='user_roles' AND column_name='area') THEN
    _faltan := _faltan || 'columna user_roles.area (corre 20260823000005_usuarios_niveles_areas.sql)'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='user_roles' AND column_name='nivel') THEN
    _faltan := _faltan || 'columna user_roles.nivel (corre 20260823000005_usuarios_niveles_areas.sql)'::text;
  END IF;

  -- En UNA línea a propósito: el editor SQL de Supabase corta los mensajes
  -- largos y con saltos de línea, y entonces no se alcanza a leer QUÉ faltó.
  -- Si esto truena, corre supabase/revisar_antes_de_20260902000001.sql, que
  -- devuelve la misma revisión como tabla, objeto por objeto.
  IF array_length(_faltan,1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta: %. (Corre supabase/revisar_antes_de_20260902000001.sql para el detalle.)',
      array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;


-- ============================================================================
-- BLOQUE 1 · La escalera de Comercial, en un solo lugar
-- ============================================================================
-- SECURITY DEFINER a propósito: estas funciones leen `user_roles` y `profiles`,
-- que tienen su propio RLS. Sin esto, una política que las consultara vería la
-- tabla vacía y contestaría «no» a todo el mundo. Es el mismo patrón que
-- `has_role()`, que existe desde el primer día del proyecto.

/**
 * Qué tanto manda alguien en las remisiones de Comercial:
 *   'global'     — administrador global (admin de Dirección o rol legado admin)
 *   'supervisor' — supervisor o administrador de Comercial: todo lo de su área
 *   'operador'   — vendedor de Comercial: lo suyo
 *   'ninguno'    — no le toca (otra área, sin rol, o dado de baja)
 */
CREATE OR REPLACE FUNCTION public.rol_comercial(_user_id uuid DEFAULT auth.uid())
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _area   text;
  _nivel  text;
  _role   text;
  _activo boolean;
BEGIN
  IF _user_id IS NULL THEN RETURN 'ninguno'; END IF;

  SELECT ur.area::text, ur.nivel::text, ur.role::text, COALESCE(p.activo, true)
    INTO _area, _nivel, _role, _activo
    FROM public.user_roles ur
    LEFT JOIN public.profiles p ON p.id = ur.user_id
   WHERE ur.user_id = _user_id
   LIMIT 1;

  -- Sin fila de rol, o dado de baja: no entra.
  IF _area IS NULL AND _nivel IS NULL AND _role IS NULL THEN RETURN 'ninguno'; END IF;
  IF NOT COALESCE(_activo, true) THEN RETURN 'ninguno'; END IF;

  -- Usuario sin migrar a ÁREA × NIVEL: se deduce del rol legado, con la misma
  -- tabla de equivalencias que usa la aplicación (desdeRolLegacy).
  IF _area IS NULL OR _nivel IS NULL THEN
    CASE _role
      WHEN 'admin'              THEN _area := 'direccion'; _nivel := 'admin';
      WHEN 'director_ventas'    THEN _area := 'comercial'; _nivel := 'admin';
      WHEN 'coordinador_ventas' THEN _area := 'comercial'; _nivel := 'supervisor';
      WHEN 'coordinador'        THEN _area := 'comercial'; _nivel := 'supervisor';
      WHEN 'ventas'             THEN _area := 'comercial'; _nivel := 'operador';
      WHEN 'auxiliar_ventas'    THEN _area := 'comercial'; _nivel := 'operador';
      ELSE RETURN 'ninguno';
    END CASE;
  END IF;

  -- Administrador global: el admin de Dirección, y el rol legado 'admin', que
  -- es su equivalente en las bases que aún no migran.
  IF (_area = 'direccion' AND _nivel = 'admin') OR _role = 'admin' THEN RETURN 'global'; END IF;

  -- Fuera de Comercial nadie trabaja el pedido (Fábrica y Logística trabajan
  -- las unidades).
  IF _area <> 'comercial' THEN RETURN 'ninguno'; END IF;

  IF _nivel IN ('supervisor','admin') THEN RETURN 'supervisor'; END IF;
  RETURN 'operador';
END;
$$;

/** ¿Puede corregir o complementar ESTA remisión? */
CREATE OR REPLACE FUNCTION public.puede_editar_remision(
  _remision_id uuid,
  _user_id     uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _rol text;
BEGIN
  IF _remision_id IS NULL THEN RETURN false; END IF;
  _rol := public.rol_comercial(_user_id);
  IF _rol IN ('global','supervisor') THEN RETURN true; END IF;
  IF _rol <> 'operador' THEN RETURN false; END IF;
  -- El operador, sólo lo que él capturó.
  RETURN EXISTS (
    SELECT 1 FROM public.remisiones r
     WHERE r.id = _remision_id AND r.vendedor_id = _user_id
  );
END;
$$;

/** ¿Puede capturar una remisión a nombre de este vendedor? */
CREATE OR REPLACE FUNCTION public.puede_capturar_remision(
  _vendedor_id uuid,
  _user_id     uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE public.rol_comercial(_user_id)
           WHEN 'global'     THEN true
           WHEN 'supervisor' THEN true          -- cubre a quien sea de su área
           WHEN 'operador'   THEN _vendedor_id = _user_id
           ELSE false
         END;
$$;

COMMENT ON FUNCTION public.rol_comercial(uuid) IS
  'Escalera de Comercial: global | supervisor | operador | ninguno. Deduce el par (área, nivel) del rol legado cuando el usuario aún no está migrado, y deja fuera a quien está dado de baja.';
COMMENT ON FUNCTION public.puede_editar_remision(uuid, uuid) IS
  'Quién puede corregir o complementar una remisión: administrador global y supervisor/administrador de Comercial, todas las de su área; el operador, las que capturó.';
COMMENT ON FUNCTION public.puede_capturar_remision(uuid, uuid) IS
  'Quién puede capturar una remisión a nombre de un vendedor: supervisor para arriba, a nombre de quien sea de su área; el operador, sólo al suyo.';

REVOKE EXECUTE ON FUNCTION public.rol_comercial(uuid)                    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.puede_editar_remision(uuid, uuid)      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.puede_capturar_remision(uuid, uuid)    FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rol_comercial(uuid)                    TO authenticated;
GRANT  EXECUTE ON FUNCTION public.puede_editar_remision(uuid, uuid)      TO authenticated;
GRANT  EXECUTE ON FUNCTION public.puede_capturar_remision(uuid, uuid)    TO authenticated;


-- ============================================================================
-- BLOQUE 2 · A qué línea del pedido pertenece cada renglón
-- ============================================================================

ALTER TABLE public.remision_items
  ADD COLUMN IF NOT EXISTS orden_linea INTEGER;

COMMENT ON COLUMN public.remision_items.orden_linea IS
  'Línea del pedido a la que pertenece el renglón: el motocarro y sus servicios comparten número. El flete usa 999. NULL en remisiones capturadas antes de 2026-09-02, que se agrupan por posición.';

-- Rellenar lo ya capturado: cada renglón `motocarro` abre línea y los que se
-- insertaron después son suyos, que es exactamente como lo leía la pantalla.
WITH ordenado AS (
  SELECT id, remision_id, tipo_servicio,
         ROW_NUMBER() OVER (PARTITION BY remision_id ORDER BY created_at NULLS FIRST, id) AS pos
    FROM public.remision_items
   WHERE orden_linea IS NULL
), numerado AS (
  SELECT id,
         CASE WHEN tipo_servicio = 'flete' THEN 999
              ELSE COUNT(*) FILTER (WHERE tipo_servicio = 'motocarro')
                     OVER (PARTITION BY remision_id ORDER BY pos) - 1
         END AS linea
    FROM ordenado
)
UPDATE public.remision_items ri
   SET orden_linea = GREATEST(n.linea, 0)
  FROM numerado n
 WHERE ri.id = n.id
   AND ri.orden_linea IS NULL;

CREATE INDEX IF NOT EXISTS idx_remision_items_remision_linea
  ON public.remision_items (remision_id, orden_linea);


-- ============================================================================
-- BLOQUE 3 · Corregir los renglones de una remisión
-- ============================================================================
-- Políticas NUEVAS, con nombre propio. Las viejas se quedan como están: en RLS
-- lo permisivo se suma, así que esto sólo puede abrir, nunca cerrar.

-- Faltaba por completo: sin UPDATE nadie podía cambiar un modelo, un color ni
-- una cantidad ya capturados.
DROP POLICY IF EXISTS "remision_items_update_area" ON public.remision_items;
CREATE POLICY "remision_items_update_area" ON public.remision_items
  FOR UPDATE TO authenticated
  USING (public.puede_editar_remision(remision_id))
  WITH CHECK (public.puede_editar_remision(remision_id));

-- El DELETE que ya existía pide el rol legado `admin`. Quitar una unidad de la
-- remisión que capturaste es parte de corregirla.
DROP POLICY IF EXISTS "remision_items_delete_area" ON public.remision_items;
CREATE POLICY "remision_items_delete_area" ON public.remision_items
  FOR DELETE TO authenticated
  USING (public.puede_editar_remision(remision_id));

-- Complementar es agregar renglones. Aquí SÍ se reemplaza la política vieja —
-- es la única del archivo que no es aditiva — porque `remision_items_insert`
-- tiene dos versiones posibles en la base y ninguna sirve tal cual:
--   · La original (20260629000003) pide los roles legados `admin`, `ventas` o
--     `coordinador`: deja fuera al supervisor y al administrador de Comercial
--     (`coordinador_ventas` / `director_ventas`), y al mismo tiempo deja de más
--     — cualquier `ventas` puede meter renglones en la remisión de OTRO. Con la
--     edición abierta esa puerta no puede quedarse así.
--   · La de 20260825000001 ya trae la escalera correcta; si es la que está,
--     esto la deja igual salvo un detalle: aquella daba INSERT a cualquiera de
--     Dirección y aquí sólo al administrador de Dirección, que es lo que dice
--     el modelo (Dirección es de lectura, salvo su administrador).
-- Nadie pierde nada de lo que hace a diario: se captura sobre la remisión que
-- uno acaba de crear (uno es el vendedor), y el supervisor captura a nombre de
-- quien sea de su área.
DROP POLICY IF EXISTS "remision_items_insert"      ON public.remision_items;
DROP POLICY IF EXISTS "remision_items_insert_area" ON public.remision_items;
CREATE POLICY "remision_items_insert_area" ON public.remision_items
  FOR INSERT TO authenticated
  WITH CHECK (public.puede_editar_remision(remision_id));


-- ============================================================================
-- BLOQUE 4 · Editar el encabezado de la remisión
-- ============================================================================
-- `actualizar remisiones` ya deja al dueño y al rol legado `coordinador`. Esta
-- suma al supervisor y al administrador de Comercial por área, sin depender de
-- que el rol legado se siga derivando bien.

DROP POLICY IF EXISTS "comercial edita sus remisiones" ON public.remisiones;
CREATE POLICY "comercial edita sus remisiones" ON public.remisiones
  FOR UPDATE TO authenticated
  USING (public.puede_editar_remision(id))
  WITH CHECK (public.puede_editar_remision(id));

-- Y por si acaso, la captura. `crear remisiones` tiene, otra vez, dos versiones
-- posibles con el mismo nombre: la original pide los roles legados `admin`,
-- `coordinador` o `ventas` — con lo que un supervisor de Comercial
-- (`coordinador_ventas`) o su administrador (`director_ventas`) no puede dar de
-- alta una remisión ni a su nombre —, y la de 20260825000001 ya lo arregla.
-- Esta política es ADITIVA y no toca ninguna de las dos: si la buena ya está,
-- no cambia nada; si está la vieja, cierra el absurdo de que el supervisor
-- pueda corregir todas las remisiones de su área pero no capturar una.
-- El bloque 6 dice cuál de las dos tenías.
DROP POLICY IF EXISTS "comercial captura remisiones" ON public.remisiones;
CREATE POLICY "comercial captura remisiones" ON public.remisiones
  FOR INSERT TO authenticated
  WITH CHECK (public.puede_capturar_remision(vendedor_id));


-- ============================================================================
-- BLOQUE 5 · Bitácora de modificaciones de remisión
-- ============================================================================
-- El motivo es NOT NULL con un mínimo de 10 caracteres: si la pantalla se
-- brinca el recuadro, la base no acepta el registro. Y el registro se escribe
-- ANTES de aplicar el cambio, así que una modificación sin justificación no
-- llega a guardarse.

CREATE TABLE IF NOT EXISTS public.remisiones_bitacora (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  remision_id    UUID NOT NULL REFERENCES public.remisiones(id) ON DELETE CASCADE,
  usuario_id     UUID REFERENCES auth.users(id),
  nombre_usuario TEXT,
  tipo_cambio    TEXT NOT NULL DEFAULT 'edicion',
  motivo         TEXT NOT NULL,
  datos_antes    JSONB,
  datos_despues  JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT remisiones_bitacora_motivo_min CHECK (length(btrim(motivo)) >= 10)
);

CREATE INDEX IF NOT EXISTS idx_remisiones_bitacora_remision ON public.remisiones_bitacora (remision_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_remisiones_bitacora_usuario  ON public.remisiones_bitacora (usuario_id);

ALTER TABLE public.remisiones_bitacora ENABLE ROW LEVEL SECURITY;

-- Se lee junto con la remisión: quien puede ver la remisión ve su historial.
-- Saber quién le movió y por qué es justo lo que hace que abrir la edición a
-- todo el área no se vuelva un agujero.
DROP POLICY IF EXISTS "leer bitacora de remisiones" ON public.remisiones_bitacora;
CREATE POLICY "leer bitacora de remisiones" ON public.remisiones_bitacora
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.remisiones r WHERE r.id = remision_id)
  );

-- Nadie firma a nombre de otro.
DROP POLICY IF EXISTS "registrar cambio de remision" ON public.remisiones_bitacora;
CREATE POLICY "registrar cambio de remision" ON public.remisiones_bitacora
  FOR INSERT TO authenticated WITH CHECK (usuario_id = auth.uid());

-- La bitácora no se corrige ni se borra: no se crean políticas de UPDATE ni
-- DELETE, así que con RLS activo nadie (fuera del service role) puede tocarla.


-- ============================================================================
-- BLOQUE 6 · Comprobación
-- ============================================================================

DO $postflight$
DECLARE _faltan text[] := ARRAY[]::text[]; _p text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='remision_items'
                    AND column_name='orden_linea') THEN
    _faltan := _faltan || 'remision_items.orden_linea'::text; END IF;

  IF to_regprocedure('public.rol_comercial(uuid)') IS NULL THEN
    _faltan := _faltan || 'rol_comercial()'::text; END IF;
  IF to_regprocedure('public.puede_editar_remision(uuid,uuid)') IS NULL THEN
    _faltan := _faltan || 'puede_editar_remision()'::text; END IF;
  IF to_regprocedure('public.puede_capturar_remision(uuid,uuid)') IS NULL THEN
    _faltan := _faltan || 'puede_capturar_remision()'::text; END IF;

  FOREACH _p IN ARRAY ARRAY['remision_items_update_area','remision_items_delete_area','remision_items_insert_area'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename='remision_items' AND policyname=_p) THEN
      _faltan := _faltan || _p; END IF;
  END LOOP;

  FOREACH _p IN ARRAY ARRAY['comercial edita sus remisiones','comercial captura remisiones'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename='remisiones' AND policyname=_p) THEN
      _faltan := _faltan || _p; END IF;
  END LOOP;

  IF to_regclass('public.remisiones_bitacora') IS NULL THEN
    _faltan := _faltan || 'remisiones_bitacora'::text; END IF;

  IF array_length(_faltan,1) > 0 THEN
    RAISE EXCEPTION E'Quedó incompleto, se revierte:\n  · %', array_to_string(_faltan, E'\n  · ');
  END IF;
  RAISE NOTICE 'Listo: el operador de Comercial corrige y complementa sus remisiones, y cada cambio queda con motivo en remisiones_bitacora.';
END $postflight$;


-- ============================================================================
-- BLOQUE 7 · Qué había en esta base (informativo, no cambia nada)
-- ============================================================================
-- La primera versión de este script se negó a correr porque faltaba un helper
-- de ÁREA × NIVEL, y el diagnóstico decía que estaban todos — porque revisaba
-- uno de los ocho. Esto lo deja a la vista.
--
-- Va como SELECT, no como RAISE NOTICE: el editor SQL de Supabase no muestra
-- los avisos, sólo el resultado de la última consulta. Es la tabla que sale
-- abajo cuando termina la corrida.

SELECT * FROM (
  SELECT 1 AS orden,
         'helper'                                AS que,
         split_part(f, '(', 1)                   AS nombre,
         CASE WHEN to_regprocedure('public.' || f) IS NULL
              THEN '✗ NO está' ELSE '✓ está' END AS estado,
         '20260823000005 / 20260824000003'       AS lo_deja
    FROM unnest(ARRAY[
      'es_area(uuid,public.user_area)',
      'supervisa_area(uuid,public.user_area)',
      'es_admin_area(uuid,public.user_area)',
      'es_admin_global(uuid)',
      'nivel_al_menos(uuid,public.user_nivel)',
      'usuario_activo(uuid)'
    ]) AS f

  UNION ALL

  -- Las políticas de captura viven con el mismo nombre en dos versiones: por
  -- rol legado (la vieja) o por área (20260825000001). El nombre no lo dice.
  SELECT 2,
         'política de captura',
         tablename || ' · ' || policyname,
         CASE WHEN COALESCE(qual,'') || COALESCE(with_check,'') LIKE '%supervisa_area%'
              THEN '✓ versión por área (20260825000001)'
              ELSE '✗ versión vieja, por rol legado' END,
         'la rige ahora este script'
    FROM pg_policies
   WHERE schemaname = 'public'
     AND ((tablename = 'remisiones'     AND policyname = 'crear remisiones')
       OR (tablename = 'remision_items' AND policyname = 'remision_items_insert'))

  UNION ALL

  -- Y lo que acaba de quedar, para no tener que ir a buscarlo.
  SELECT 3, 'lo que dejó este script', tablename || ' · ' || policyname, '✓ creada', '20260902000001'
    FROM pg_policies
   WHERE schemaname = 'public'
     AND policyname IN ('remision_items_update_area','remision_items_delete_area',
                        'remision_items_insert_area','comercial edita sus remisiones',
                        'comercial captura remisiones','leer bitacora de remisiones',
                        'registrar cambio de remision')
) t
ORDER BY orden, nombre;
