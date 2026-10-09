-- ============================================================================
-- Compras e inventario: decisiones de Polo y aislamiento de las cuentas de
-- prueba — 2026-10-07
-- ----------------------------------------------------------------------------
-- Aplica lo que Polo decidió al revisar el PR de Compras e Inventario:
--
--   1. Saldos a favor: SÓLO Compras (y el administrador) los aplica. Finanzas
--      los ve y valida pagos; Ventas los ve y solicita. Sigue siendo un
--      parámetro (`saldo_favor_aplican`) que sólo un administrador cambia.
--   2. Motivos de ajuste: catálogo REAL (no de prueba), editable por Compras y
--      el administrador. Un motivo usado nunca se borra: se desactiva.
--   3. ABC: la leyenda de combinaciones pasa a un catálogo editable y queda la
--      marca «parámetros iniciales, por confirmar con Compras».
--   4. Almacenes: la equivalencia con Ecount es un dato editable y vacío; no se
--      afirma nada que Polo no haya confirmado.
--   5. Cuentas de prueba: SÓLO ven y tocan datos de prueba. Políticas
--      restrictivas de lectura en todas las tablas y un candado de escritura
--      que también alcanza a las funciones SECURITY DEFINER existentes. Las
--      reglas por tabla viven en `inventario_reglas_modo_prueba`; lo que no
--      tiene regla queda cerrado para ellas.
--
-- No cambia nada para los usuarios reales (salvo que dejan de ver los avisos
-- generados por datos de prueba). No toca el flujo de motocarros ni los
-- gastos de Finanzas: sólo les pone el candado para las cuentas de prueba.
-- Idempotente. Requiere 20261006000001…04.
-- ============================================================================

DO $preflight$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regprocedure('public.es_usuario_prueba(uuid)') IS NULL THEN
    _faltan := _faltan || '20261006000001_compras_inventario_base'::text;
  END IF;
  IF to_regclass('public.ajustes_inventario') IS NULL THEN
    _faltan := _faltan || '20261006000002_compras_ajustes_kardex'::text;
  END IF;
  IF to_regclass('public.cobranza_saldos_favor') IS NULL THEN
    _faltan := _faltan || '20261006000003_cobranza_refacciones'::text;
  END IF;
  IF to_regprocedure('public.sembrar_datos_prueba_compras()') IS NULL THEN
    _faltan := _faltan || '20261006000004_datos_prueba_compras'::text;
  END IF;
  IF to_regclass('public.avisos') IS NULL THEN
    _faltan := _faltan || 'tabla avisos'::text;
  END IF;
  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION 'No se modificó nada. Falta aplicar antes: %', array_to_string(_faltan, ' | ');
  END IF;
END $preflight$;

-- ── 0. ¿Es de prueba quien opera? (con memoria por transacción) ───────────
-- Los candados de escritura corren por cada fila: se recuerda la respuesta
-- para no consultar Auth en cada una (cargas masivas reales).
CREATE OR REPLACE FUNCTION public.es_usuario_prueba_actual()
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_cache text;
  v boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN false;
  END IF;
  v_cache := current_setting('kit.es_prueba_cache', true);
  IF v_cache LIKE v_uid::text || ':%' THEN
    RETURN split_part(v_cache, ':', 2)::boolean;
  END IF;
  v := public.es_usuario_prueba(v_uid);
  PERFORM set_config('kit.es_prueba_cache', v_uid::text || ':' || v::text, true);
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public.es_usuario_prueba_actual() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_usuario_prueba_actual() TO authenticated;

CREATE OR REPLACE FUNCTION public.es_admin_compras(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _uid IS NOT NULL AND public.usuario_activo(_uid)
     AND (public.es_admin_global(_uid) OR public.has_role(_uid, 'admin'::public.app_role))
$$;
REVOKE ALL ON FUNCTION public.es_admin_compras(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.es_admin_compras(uuid) TO authenticated;

-- ── 1. Parámetros: decisión de saldos a favor y parámetros sólo de admin ───
INSERT INTO public.compras_parametros (clave, valor, descripcion) VALUES
  ('abc_parametros_confirmados', 'false',
   'ABC: false mientras los cortes, coberturas y la leyenda sean los iniciales. Compras lo pone en true al confirmarlos con su archivo «Tendencia v2».')
ON CONFLICT (clave) DO NOTHING;

-- Una sola vez: el valor anterior (Compras y Finanzas) pasa a sólo Compras.
-- La marca en la descripción evita que una segunda corrida pise un cambio
-- posterior del administrador.
UPDATE public.compras_parametros
   SET valor = '["compras"]'::jsonb,
       descripcion = 'Quién aplica un saldo a favor (compras, finanzas). Decisión de Polo (2026-10-07): sólo Compras; el administrador siempre. Finanzas lo ve y Ventas lo solicita.',
       updated_at = now()
 WHERE clave = 'saldo_favor_aplican'
   AND valor = '["compras","finanzas"]'::jsonb
   AND descripcion NOT LIKE '%Decisión de Polo (2026-10-07)%';

UPDATE public.compras_parametros
   SET descripcion = 'Si es true, Logística no cierra una entrega real sin pago validado o crédito. APAGADO hasta que Polo lo decida; sólo un administrador lo enciende. Los datos de prueba siempre lo exigen.'
 WHERE clave = 'entrega_exige_pago' AND descripcion NOT LIKE '%sólo un administrador%';

CREATE OR REPLACE FUNCTION public.compras_parametros_guardia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_clave text := coalesce(NEW.clave, OLD.clave);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN coalesce(NEW, OLD);  -- SQL editor / migraciones
  END IF;
  IF public.es_usuario_prueba_actual() THEN
    RAISE EXCEPTION 'Estás en MODO PRUEBA: los parámetros son configuración real y una cuenta de prueba no los cambia.';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Los parámetros no se borran';
  END IF;
  IF v_clave IN ('saldo_favor_aplican', 'entrega_exige_pago', 'cargador_saldos_habilitado')
     AND NOT public.es_admin_compras(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo un administrador cambia «%»', v_clave;
  END IF;
  IF v_clave = 'saldo_favor_aplican' THEN
    IF jsonb_typeof(NEW.valor) <> 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(NEW.valor) x WHERE x NOT IN ('compras', 'finanzas')) THEN
      RAISE EXCEPTION 'saldo_favor_aplican es una lista con compras y/o finanzas';
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_by := auth.uid();
    NEW.updated_at := now();
    PERFORM public.registrar_bitacora_compras('inventario', 'cambiar_parametro', 'compras_parametros', NULL, v_clave,
      jsonb_build_object('antes', OLD.valor, 'despues', NEW.valor), false);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_compras_parametros_guardia ON public.compras_parametros;
CREATE TRIGGER trg_compras_parametros_guardia
  BEFORE INSERT OR UPDATE OR DELETE ON public.compras_parametros
  FOR EACH ROW EXECUTE FUNCTION public.compras_parametros_guardia();

-- ── 2. Catálogos editables: motivos de ajuste y unidades de venta ──────────
ALTER TABLE public.inventario_motivos_ajuste
  ADD COLUMN IF NOT EXISTS es_prueba  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.inventario_unidades_venta
  ADD COLUMN IF NOT EXISTS es_prueba  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- La lista que aprobó Polo es catálogo real. Si alguien ya la cambió, no se
-- pisa: sólo se agregan las que falten. «Mal conteo» va primero y «Otro»
-- siempre pide explicación.
INSERT INTO public.inventario_motivos_ajuste (clave, nombre, requiere_texto, orden) VALUES
  ('mal_conteo',           'Mal conteo', false, 10),
  ('auditoria',            'Auditoría o conteo físico', false, 20),
  ('incidencia_recepcion', 'Incidencia de recepción de contenedor', false, 30),
  ('merma',                'Merma o daño', false, 40),
  ('correccion_captura',   'Corrección de captura', false, 50),
  ('otro',                 'Otro', true, 90)
ON CONFLICT (clave) DO NOTHING;
UPDATE public.inventario_motivos_ajuste SET requiere_texto = true WHERE clave = 'otro' AND NOT requiere_texto;
UPDATE public.inventario_motivos_ajuste SET es_prueba = false
 WHERE clave IN ('mal_conteo', 'auditoria', 'incidencia_recepcion', 'merma', 'correccion_captura', 'otro') AND es_prueba;

INSERT INTO public.inventario_unidades_venta (clave, nombre, orden) VALUES
  ('pieza', 'Pieza', 10), ('bolsa', 'Bolsa', 20), ('juego', 'Juego', 30),
  ('par', 'Par', 40), ('paquete', 'Paquete', 50)
ON CONFLICT (clave) DO NOTHING;

-- ¿Ya se usó esta clave? (motivo en ajustes o kárdex; unidad en artículos)
CREATE OR REPLACE FUNCTION public.clave_catalogo_usada(_tabla text, _clave text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE _tabla
    WHEN 'inventario_motivos_ajuste' THEN
      EXISTS (SELECT 1 FROM public.ajustes_inventario WHERE motivo_clave = _clave)
      OR EXISTS (SELECT 1 FROM public.almacen_refacciones_movimientos WHERE motivo_clave = _clave)
    WHEN 'inventario_unidades_venta' THEN
      EXISTS (SELECT 1 FROM public.almacen_refacciones_productos WHERE unidad_venta = _clave)
    ELSE false END
$$;
REVOKE ALL ON FUNCTION public.clave_catalogo_usada(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clave_catalogo_usada(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.catalogo_inventario_guardia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_prueba boolean := public.es_usuario_prueba_actual();
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF public.clave_catalogo_usada(TG_TABLE_NAME, OLD.clave) THEN
      RAISE EXCEPTION '«%» ya se usó: no se borra, se desactiva para conservar el historial', OLD.nombre;
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    -- Lo que da de alta una cuenta de prueba nace como prueba.
    NEW.es_prueba := coalesce(NEW.es_prueba, false) OR v_prueba;
  ELSE
    IF NEW.clave IS DISTINCT FROM OLD.clave AND public.clave_catalogo_usada(TG_TABLE_NAME, OLD.clave) THEN
      RAISE EXCEPTION '«%» ya se usó: puedes cambiarle el nombre, no la clave', OLD.nombre;
    END IF;
    NEW.es_prueba := OLD.es_prueba;
  END IF;
  IF TG_TABLE_NAME = 'inventario_motivos_ajuste' AND NEW.clave = 'otro' THEN
    NEW.requiere_texto := true;
  END IF;
  IF auth.uid() IS NOT NULL THEN
    NEW.updated_by := auth.uid();
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_motivos_ajuste_guardia ON public.inventario_motivos_ajuste;
CREATE TRIGGER trg_motivos_ajuste_guardia
  BEFORE INSERT OR UPDATE OR DELETE ON public.inventario_motivos_ajuste
  FOR EACH ROW EXECUTE FUNCTION public.catalogo_inventario_guardia();
DROP TRIGGER IF EXISTS trg_unidades_venta_guardia ON public.inventario_unidades_venta;
CREATE TRIGGER trg_unidades_venta_guardia
  BEFORE INSERT OR UPDATE OR DELETE ON public.inventario_unidades_venta
  FOR EACH ROW EXECUTE FUNCTION public.catalogo_inventario_guardia();

-- Alta, cambio de nombre y desactivación de motivos (Compras y admin).
CREATE OR REPLACE FUNCTION public.guardar_motivo_ajuste(
  _clave text, _nombre text, _requiere_texto boolean DEFAULT false,
  _activo boolean DEFAULT true, _orden integer DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_clave text := trim(both '_' from regexp_replace(translate(lower(trim(coalesce(_clave, ''))), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', '_', 'g'));
  v_actual public.inventario_motivos_ajuste%ROWTYPE;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador cambia los motivos de ajuste';
  END IF;
  IF nullif(trim(_nombre), '') IS NULL THEN
    RAISE EXCEPTION 'Escribe el nombre del motivo';
  END IF;
  IF v_clave = '' THEN
    v_clave := trim(both '_' from regexp_replace(translate(lower(trim(_nombre)), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', '_', 'g'));
  END IF;
  v_clave := left(v_clave, 40);
  IF v_clave !~ '^[a-z0-9_]{2,40}$' THEN
    RAISE EXCEPTION 'La clave del motivo lleva de 2 a 40 letras o números';
  END IF;
  SELECT * INTO v_actual FROM public.inventario_motivos_ajuste WHERE clave = v_clave;
  IF FOUND THEN
    PERFORM public.exigir_dato_prueba(v_actual.es_prueba, 'el motivo «' || v_actual.nombre || '»');
    UPDATE public.inventario_motivos_ajuste
       SET nombre = trim(_nombre), requiere_texto = coalesce(_requiere_texto, false),
           activo = coalesce(_activo, true), orden = coalesce(_orden, orden)
     WHERE clave = v_clave;
  ELSE
    INSERT INTO public.inventario_motivos_ajuste (clave, nombre, requiere_texto, activo, orden)
    VALUES (v_clave, trim(_nombre), coalesce(_requiere_texto, false), coalesce(_activo, true),
            coalesce(_orden, (SELECT coalesce(max(orden), 0) + 10 FROM public.inventario_motivos_ajuste WHERE clave <> 'otro')));
  END IF;
  PERFORM public.registrar_bitacora_compras('inventario', 'guardar_motivo_ajuste', 'inventario_motivos_ajuste', NULL, v_clave,
    jsonb_build_object('nombre', _nombre, 'requiere_texto', _requiere_texto, 'activo', _activo),
    public.es_usuario_prueba_actual());
  RETURN v_clave;
END;
$$;
REVOKE ALL ON FUNCTION public.guardar_motivo_ajuste(text, text, boolean, boolean, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_motivo_ajuste(text, text, boolean, boolean, integer) TO authenticated;

-- Un ajuste real nunca usa un motivo dado de alta en prueba.
CREATE OR REPLACE FUNCTION public.ajuste_motivo_de_prueba()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT NEW.es_prueba AND EXISTS (SELECT 1 FROM public.inventario_motivos_ajuste
                                    WHERE clave = NEW.motivo_clave AND es_prueba) THEN
    RAISE EXCEPTION 'El motivo «%» es de prueba: no se usa en un ajuste real', NEW.motivo_clave;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_ajuste_motivo_de_prueba ON public.ajustes_inventario;
CREATE TRIGGER trg_ajuste_motivo_de_prueba
  BEFORE INSERT OR UPDATE OF motivo_clave ON public.ajustes_inventario
  FOR EACH ROW EXECUTE FUNCTION public.ajuste_motivo_de_prueba();

-- ── 3. ABC: leyenda editable ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.abc_leyenda_combinaciones (
  combinacion text PRIMARY KEY CHECK (combinacion ~ '^[ABC]{2}$'),
  descripcion text NOT NULL,
  accion      text,
  orden       integer NOT NULL DEFAULT 100,
  fuente      text NOT NULL DEFAULT 'Parámetros iniciales (prompt de Compras, 2026-10-06)',
  updated_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.abc_leyenda_combinaciones ENABLE ROW LEVEL SECURITY;
INSERT INTO public.abc_leyenda_combinaciones (combinacion, descripcion, orden) VALUES
  ('AA', 'Mucho dinero y mucho volumen: el corazón del negocio, nunca debe faltar.', 10),
  ('AB', 'Mucho dinero, volumen medio.', 20),
  ('AC', 'Se mueve poco pero genera mucho.', 30),
  ('BA', 'Dinero medio, mucho volumen: pieza barata que se vende mucho.', 40),
  ('BB', 'Dinero y volumen medios.', 50),
  ('BC', 'Dinero medio, poco volumen.', 60),
  ('CA', 'Poco dinero pero mucho volumen: pieza barata de alta rotación.', 70),
  ('CB', 'Poco dinero, volumen medio.', 80),
  ('CC', 'Poco dinero y poco volumen: revisar si conviene seguir comprándola.', 90)
ON CONFLICT (combinacion) DO NOTHING;

DROP POLICY IF EXISTS abc_leyenda_leer ON public.abc_leyenda_combinaciones;
CREATE POLICY abc_leyenda_leer ON public.abc_leyenda_combinaciones
  FOR SELECT TO authenticated USING (public.puede_leer_compras_inventario(auth.uid()));
DROP POLICY IF EXISTS abc_leyenda_escribir ON public.abc_leyenda_combinaciones;
CREATE POLICY abc_leyenda_escribir ON public.abc_leyenda_combinaciones
  FOR UPDATE TO authenticated
  USING (public.puede_compras_inventario(auth.uid()))
  WITH CHECK (public.puede_compras_inventario(auth.uid()));
GRANT SELECT, UPDATE ON public.abc_leyenda_combinaciones TO authenticated;

CREATE OR REPLACE FUNCTION public.abc_leyenda_sello()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.updated_by := auth.uid();
  NEW.updated_at := now();
  IF NEW.descripcion IS DISTINCT FROM OLD.descripcion OR NEW.accion IS DISTINCT FROM OLD.accion THEN
    NEW.fuente := coalesce(nullif(NEW.fuente, OLD.fuente), 'Editada por Compras');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_abc_leyenda_sello ON public.abc_leyenda_combinaciones;
CREATE TRIGGER trg_abc_leyenda_sello
  BEFORE UPDATE ON public.abc_leyenda_combinaciones
  FOR EACH ROW EXECUTE FUNCTION public.abc_leyenda_sello();

-- ── 4. Almacenes: equivalencia con Ecount (por confirmar) ─────────────────
ALTER TABLE public.inventario_almacenes
  ADD COLUMN IF NOT EXISTS equivalente_ecount text;
COMMENT ON COLUMN public.inventario_almacenes.equivalente_ecount IS
  'Nombre del almacén en Ecount. Vacío = por confirmar con Compras (no se supone).';
-- La primera versión decía «en Ecount: Dazon 2025 Nuevo» como hecho; Polo no
-- lo confirmó. Se quita sólo si nadie cambió ese texto.
UPDATE public.inventario_almacenes
   SET descripcion = 'Lo nuevo. Aquí llegan todas las compras.'
 WHERE clave = 'linea_dorada'
   AND descripcion = 'Lo nuevo (en Ecount: «Dazon 2025 Nuevo»). Aquí llegan todas las compras.';

-- La función de alta/edición conserva su firma; la equivalencia se guarda
-- con esta otra (Compras / admin; nunca una cuenta de prueba sobre lo real).
CREATE OR REPLACE FUNCTION public.guardar_equivalente_ecount(_clave text, _equivalente text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_prueba boolean;
BEGIN
  IF NOT public.puede_compras_inventario(auth.uid()) THEN
    RAISE EXCEPTION 'Sólo Compras o un administrador cambia los almacenes';
  END IF;
  SELECT es_prueba INTO v_prueba FROM public.inventario_almacenes WHERE clave = _clave;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el almacén %', _clave; END IF;
  PERFORM public.exigir_dato_prueba(v_prueba, 'el almacén ' || _clave);
  UPDATE public.inventario_almacenes SET equivalente_ecount = nullif(trim(_equivalente), '') WHERE clave = _clave;
  PERFORM public.registrar_bitacora_compras('inventario', 'equivalente_ecount', 'inventario_almacenes', NULL, _clave,
    jsonb_build_object('equivalente_ecount', _equivalente), v_prueba);
END;
$$;
REVOKE ALL ON FUNCTION public.guardar_equivalente_ecount(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_equivalente_ecount(text, text) TO authenticated;

-- ── 5. Fecha por defecto de una compra: la de México, no la UTC ────────────
ALTER TABLE public.compras_refacciones
  ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Mexico_City')::date);

-- ── 6. Avisos generados por datos de prueba ────────────────────────────────
-- Antes, un pago de prueba avisaba a todo el área Compras, también a Martin.
-- Ahora el aviso nace marcado y sólo lo ven las cuentas de prueba.
ALTER TABLE public.avisos ADD COLUMN IF NOT EXISTS es_prueba boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.aviso_marca_prueba()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.es_prueba := coalesce(NEW.es_prueba, false)
    OR public.es_usuario_prueba_actual()
    OR (NEW.creado_por IS NOT NULL AND public.es_usuario_prueba(NEW.creado_por))
    OR (NEW.remision_refaccion_id IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.remisiones_refacciones r WHERE r.id = NEW.remision_refaccion_id AND r.es_prueba));
  RETURN NEW;
END;
$$;
-- Los avisos que ya generaron los datos de prueba sembrados antes.
UPDATE public.avisos a SET es_prueba = true
 WHERE NOT a.es_prueba
   AND ((a.creado_por IS NOT NULL AND public.es_usuario_prueba(a.creado_por))
     OR EXISTS (SELECT 1 FROM public.remisiones_refacciones r WHERE r.id = a.remision_refaccion_id AND r.es_prueba)
     OR (a.datos ? 'pago_id' AND EXISTS (SELECT 1 FROM public.cobranza_pagos p
                                          WHERE p.id::text = a.datos->>'pago_id' AND p.es_prueba)));

DROP TRIGGER IF EXISTS trg_aviso_marca_prueba ON public.avisos;
CREATE TRIGGER trg_aviso_marca_prueba
  BEFORE INSERT ON public.avisos
  FOR EACH ROW EXECUTE FUNCTION public.aviso_marca_prueba();

DROP POLICY IF EXISTS avisos_modo_prueba ON public.avisos;
CREATE POLICY avisos_modo_prueba ON public.avisos AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (CASE WHEN (SELECT public.es_usuario_prueba(auth.uid()))
              THEN es_prueba OR destinatario_id = auth.uid()
              ELSE NOT es_prueba END);

-- ── 7a. Sólo correos «prueba.…» pueden ser cuentas de prueba ───────────────
-- Las cuentas @dazon.demo sin ese prefijo (finanzas@, martin@, marco@…) son de
-- personas reales mientras se configura el correo; si una entrara a la lista
-- quedaría aislada de los datos reales. La primera versión del PR sembraba
-- compras@, finanzas@… : se sacan (en producción esa lista no existía).
DELETE FROM public.inventario_usuarios_prueba
 WHERE lower(email) IN ('compras@dazon.demo', 'almacen@dazon.demo', 'finanzas@dazon.demo', 'logistica@dazon.demo',
                        'ventas@dazon.demo', 'admin@dazon.demo', 'super@dazon.demo');
ALTER TABLE public.inventario_usuarios_prueba DROP CONSTRAINT IF EXISTS inventario_usuarios_prueba_solo_prefijo;
ALTER TABLE public.inventario_usuarios_prueba ADD CONSTRAINT inventario_usuarios_prueba_solo_prefijo
  CHECK (lower(email) LIKE 'prueba.%@%');

-- ── 7. Aislamiento de las cuentas de prueba ───────────────────────────────
-- Una regla por tabla: qué puede LEER y qué puede ESCRIBIR una cuenta de
-- prueba. Una tabla sin regla (o nueva) queda cerrada para ellas.
--   lectura:   todo | prueba | padre | propio | propio_o_prueba | especial | nada
--   escritura: prueba | padre | propio | nada
--   prueba          = la fila tiene es_prueba = true
--   padre           = la fila cuelga (columna) de una fila de prueba de padre_tabla
--   propio          = la columna es el propio usuario
--   propio_o_prueba = la columna es el propio usuario u otra cuenta de prueba
CREATE TABLE IF NOT EXISTS public.inventario_reglas_modo_prueba (
  tabla       text PRIMARY KEY,
  lectura     text NOT NULL CHECK (lectura IN ('todo', 'prueba', 'padre', 'propio', 'propio_o_prueba', 'especial', 'nada')),
  escritura   text NOT NULL CHECK (escritura IN ('prueba', 'padre', 'propio', 'nada')),
  padre_tabla text,
  columna     text,
  nota        text,
  CHECK ((lectura = 'padre' OR escritura = 'padre') = (padre_tabla IS NOT NULL)),
  CHECK ((lectura IN ('padre', 'propio', 'propio_o_prueba') OR escritura IN ('padre', 'propio')) = (columna IS NOT NULL))
);
ALTER TABLE public.inventario_reglas_modo_prueba ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reglas_modo_prueba_leer ON public.inventario_reglas_modo_prueba;
CREATE POLICY reglas_modo_prueba_leer ON public.inventario_reglas_modo_prueba
  FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.inventario_reglas_modo_prueba TO authenticated;

INSERT INTO public.inventario_reglas_modo_prueba (tabla, lectura, escritura, padre_tabla, columna, nota) VALUES
  -- Marcadas con es_prueba
  ('clientes',                        'prueba', 'prueba', NULL, NULL, 'Clientes'),
  ('almacen_refacciones_productos',   'prueba', 'prueba', NULL, NULL, 'Artículos'),
  ('almacen_refacciones_movimientos', 'prueba', 'prueba', NULL, NULL, 'Kárdex'),
  ('remisiones_refacciones',          'prueba', 'prueba', NULL, NULL, 'Remisiones de refacciones'),
  ('remision_refaccion_correcciones', 'prueba', 'prueba', NULL, NULL, NULL),
  ('compras_refacciones',             'prueba', 'prueba', NULL, NULL, NULL),
  ('recepciones_refacciones',         'prueba', 'prueba', NULL, NULL, NULL),
  ('ajustes_inventario',              'prueba', 'prueba', NULL, NULL, NULL),
  ('cobranza_pagos',                  'prueba', 'prueba', NULL, NULL, NULL),
  ('cobranza_aplicaciones',           'prueba', 'prueba', NULL, NULL, NULL),
  ('cobranza_saldos_favor',           'prueba', 'prueba', NULL, NULL, NULL),
  ('cobranza_solicitudes_saldo',      'prueba', 'prueba', NULL, NULL, NULL),
  ('compras_folios',                  'prueba', 'prueba', NULL, NULL, 'Series P-'),
  ('bitacora_compras_inventario',     'prueba', 'prueba', NULL, NULL, NULL),
  -- Catálogos que se leen completos (no traen datos de clientes ni dinero)
  ('inventario_almacenes',            'todo',   'prueba', NULL, NULL, 'Catálogo de almacenes'),
  ('inventario_motivos_ajuste',       'todo',   'prueba', NULL, NULL, 'Catálogo real; lo que da de alta una cuenta de prueba nace como prueba'),
  ('inventario_unidades_venta',       'todo',   'prueba', NULL, NULL, NULL),
  ('almacen_refacciones_unidades',    'todo',   'prueba', NULL, NULL, 'Modelos compatibles'),
  ('almacen_refacciones_unidad_alias','todo',   'padre',  'almacen_refacciones_unidades', 'unidad_id', NULL),
  ('abc_leyenda_combinaciones',       'todo',   'nada',   NULL, NULL, NULL),
  ('compras_parametros',              'todo',   'nada',   NULL, NULL, 'Configuración real'),
  ('inventario_usuarios_prueba',      'todo',   'nada',   NULL, NULL, 'Una cuenta de prueba no se saca de la lista'),
  ('inventario_reglas_modo_prueba',   'todo',   'nada',   NULL, NULL, NULL),
  ('config_general',                  'todo',   'nada',   NULL, NULL, 'Nombre y logo de la empresa'),
  -- Hijas de un registro marcado
  ('almacen_refacciones_codigos',     'padre',  'padre',  'almacen_refacciones_productos', 'producto_id', NULL),
  ('almacen_refacciones_producto_compat','padre','padre', 'almacen_refacciones_productos', 'producto_id', NULL),
  ('ajuste_inventario_lineas',        'padre',  'padre',  'ajustes_inventario', 'ajuste_id', NULL),
  ('compra_refaccion_lineas',         'padre',  'padre',  'compras_refacciones', 'compra_id', NULL),
  ('compra_refaccion_pendientes',     'padre',  'padre',  'compras_refacciones', 'compra_id', NULL),
  ('recepcion_refaccion_lineas',      'padre',  'padre',  'recepciones_refacciones', 'recepcion_id', NULL),
  ('remision_refaccion_items',        'padre',  'padre',  'remisiones_refacciones', 'remision_id', NULL),
  ('remision_refaccion_ordenes',      'padre',  'padre',  'remisiones_refacciones', 'remision_id', NULL),
  ('remision_refaccion_eventos',      'padre',  'padre',  'remisiones_refacciones', 'remision_id', NULL),
  ('clientes_bitacora',               'padre',  'padre',  'clientes', 'cliente_id', NULL),
  ('clientes_comentarios',            'padre',  'padre',  'clientes', 'cliente_id', NULL),
  -- Lo suyo
  ('profiles',                        'propio_o_prueba', 'propio', NULL, 'id', 'Su perfil y el de las otras cuentas de prueba'),
  ('user_roles',                      'propio_o_prueba', 'nada',   NULL, 'user_id', 'Una cuenta de prueba no cambia permisos'),
  ('almacen_refacciones_acceso',      'propio', 'nada',   NULL, 'user_id', NULL),
  ('remisiones_asignacion_acceso',    'propio', 'nada',   NULL, 'user_id', NULL),
  ('historial_conexiones',            'propio', 'propio', NULL, 'usuario_id', NULL),
  ('bitacora_eventos',                'propio', 'propio', NULL, 'usuario_id', NULL),
  ('bitacora_eliminaciones',          'propio', 'propio', NULL, 'eliminado_por', NULL),
  ('avisos',                          'especial', 'prueba', NULL, NULL, 'Política propia: los suyos y los de prueba')
ON CONFLICT (tabla) DO NOTHING;

-- Candado de escritura: corre por fila, también dentro de funciones
-- SECURITY DEFINER (motocarros, finanzas…), que la seguridad por filas no
-- alcanza. Para un usuario real no hace nada.
CREATE OR REPLACE FUNCTION public.candado_modo_prueba()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_regla  text := TG_ARGV[0];
  v_padre  text := nullif(TG_ARGV[1], '');
  v_col    text := nullif(TG_ARGV[2], '');
  v_filas  jsonb[] := ARRAY[]::jsonb[];
  v_fila   jsonb;
  v_ok     boolean;
  v_id     text;
BEGIN
  IF NOT public.es_usuario_prueba_actual() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN v_filas := v_filas || to_jsonb(NEW); END IF;
  IF TG_OP IN ('UPDATE', 'DELETE') THEN v_filas := v_filas || to_jsonb(OLD); END IF;
  FOREACH v_fila IN ARRAY v_filas LOOP
    IF v_regla = 'prueba' THEN
      v_ok := coalesce((v_fila->>'es_prueba')::boolean, false);
    ELSIF v_regla = 'propio' THEN
      v_ok := (v_fila->>v_col) = auth.uid()::text;
    ELSIF v_regla = 'padre' THEN
      v_id := v_fila->>v_col;
      IF v_id IS NULL THEN
        v_ok := false;
      ELSE
        EXECUTE format('SELECT es_prueba FROM public.%I WHERE id = $1::uuid', v_padre) INTO v_ok USING v_id;
        -- Al borrar en cascada, el padre (de prueba) ya no está.
        IF v_ok IS NULL THEN v_ok := TG_OP = 'DELETE'; END IF;
      END IF;
    ELSE
      v_ok := false;
    END IF;
    IF NOT coalesce(v_ok, false) THEN
      RAISE EXCEPTION 'Estás en MODO PRUEBA: % es información real y una cuenta de prueba no la puede modificar.', TG_TABLE_NAME
        USING ERRCODE = '42501';
    END IF;
  END LOOP;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

-- Aplica la regla de cada tabla del esquema public con seguridad por filas.
CREATE OR REPLACE FUNCTION public.aplicar_reglas_modo_prueba()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t record;
  r public.inventario_reglas_modo_prueba%ROWTYPE;
  v_using text;
  v_lectura text;
  v_escritura text;
  v_sin_rls text[] := ARRAY[]::text[];
  v_sin_permiso text[] := ARRAY[]::text[];
  v_aplicadas integer := 0;
BEGIN
  FOR t IN
    SELECT c.oid, c.relname, c.relrowsecurity
      FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
       AND NOT c.relispartition
     ORDER BY c.relname
  LOOP
    SELECT * INTO r FROM public.inventario_reglas_modo_prueba WHERE tabla = t.relname;
    v_lectura := coalesce(r.lectura, 'nada');
    v_escritura := coalesce(r.escritura, 'nada');
    BEGIN

    -- Lectura: política RESTRICTIVA (se suma a las que ya existen).
    EXECUTE format('DROP POLICY IF EXISTS modo_prueba_lectura ON public.%I', t.relname);
    IF NOT t.relrowsecurity THEN
      v_sin_rls := v_sin_rls || t.relname::text;
    ELSIF v_lectura NOT IN ('todo', 'especial') THEN
      v_using := CASE v_lectura
        WHEN 'prueba' THEN 'es_prueba'
        WHEN 'padre' THEN format('EXISTS (SELECT 1 FROM public.%I p WHERE p.id = %I AND p.es_prueba)', r.padre_tabla, r.columna)
        WHEN 'propio' THEN format('%I = auth.uid()', r.columna)
        WHEN 'propio_o_prueba' THEN format('(%I = auth.uid() OR public.es_usuario_prueba(%I))', r.columna, r.columna)
        ELSE 'false' END;
      EXECUTE format('CREATE POLICY modo_prueba_lectura ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated '
                     'USING (NOT (SELECT public.es_usuario_prueba(auth.uid())) OR %s)', t.relname, v_using);
    END IF;

    -- Escritura: candado por fila (alcanza también a SECURITY DEFINER).
    EXECUTE format('DROP TRIGGER IF EXISTS zzz_candado_modo_prueba ON public.%I', t.relname);
    EXECUTE format('CREATE TRIGGER zzz_candado_modo_prueba BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
                   'FOR EACH ROW EXECUTE FUNCTION public.candado_modo_prueba(%L, %L, %L)',
                   t.relname, v_escritura, coalesce(r.padre_tabla, ''), coalesce(r.columna, ''));
    v_aplicadas := v_aplicadas + 1;
    EXCEPTION WHEN insufficient_privilege THEN
      v_sin_permiso := v_sin_permiso || t.relname::text;
    END;
  END LOOP;
  IF array_length(v_sin_permiso, 1) > 0 THEN
    RAISE EXCEPTION 'No se pudo poner el candado de modo prueba en: % (el rol que corre la migración no es dueño de esas tablas; córrela como postgres)',
      array_to_string(v_sin_permiso, ', ');
  END IF;
  RETURN jsonb_build_object('tablas', v_aplicadas, 'sin_seguridad_por_filas', to_jsonb(v_sin_rls));
END;
$$;
REVOKE ALL ON FUNCTION public.aplicar_reglas_modo_prueba() FROM PUBLIC, anon, authenticated;

DO $aplicar$
DECLARE v jsonb := public.aplicar_reglas_modo_prueba();
BEGIN
  RAISE NOTICE 'Modo prueba: reglas aplicadas en % tablas', v->>'tablas';
  IF jsonb_array_length(v->'sin_seguridad_por_filas') > 0 THEN
    RAISE NOTICE 'OJO: estas tablas no tienen seguridad por filas y cualquier usuario autenticado las lee (también las cuentas de prueba): %',
      v->'sin_seguridad_por_filas';
  END IF;
END $aplicar$;

-- Archivos: una cuenta de prueba sólo ve y sube lo suyo dentro de la carpeta
-- prueba/ del bucket de evidencias de Compras.
DO $storage$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'Sin storage.objects: se omite el candado de archivos';
    RETURN;
  END IF;
  EXECUTE 'DROP POLICY IF EXISTS modo_prueba_archivos_leer ON storage.objects';
  EXECUTE $p$CREATE POLICY modo_prueba_archivos_leer ON storage.objects AS RESTRICTIVE
    FOR SELECT TO authenticated
    USING (NOT (SELECT public.es_usuario_prueba(auth.uid()))
           OR (bucket_id = 'evidencias-compras' AND name LIKE 'prueba/%'))$p$;
  EXECUTE 'DROP POLICY IF EXISTS modo_prueba_archivos_subir ON storage.objects';
  EXECUTE $p$CREATE POLICY modo_prueba_archivos_subir ON storage.objects AS RESTRICTIVE
    FOR INSERT TO authenticated
    WITH CHECK (NOT (SELECT public.es_usuario_prueba(auth.uid()))
                OR (bucket_id = 'evidencias-compras' AND name LIKE 'prueba/%'))$p$;
  EXECUTE 'DROP POLICY IF EXISTS modo_prueba_archivos_cambiar ON storage.objects';
  EXECUTE $p$CREATE POLICY modo_prueba_archivos_cambiar ON storage.objects AS RESTRICTIVE
    FOR UPDATE TO authenticated
    USING (NOT (SELECT public.es_usuario_prueba(auth.uid())))$p$;
  EXECUTE 'DROP POLICY IF EXISTS modo_prueba_archivos_borrar ON storage.objects';
  EXECUTE $p$CREATE POLICY modo_prueba_archivos_borrar ON storage.objects AS RESTRICTIVE
    FOR DELETE TO authenticated
    USING (NOT (SELECT public.es_usuario_prueba(auth.uid())))$p$;
END $storage$;

-- ── 8. Postflight ──────────────────────────────────────────────────────────
DO $postflight$
DECLARE v_faltan text;
BEGIN
  SELECT string_agg(c.relname, ', ') INTO v_faltan
    FROM pg_class c
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
     AND NOT EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgrelid = c.oid AND g.tgname = 'zzz_candado_modo_prueba');
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Tablas sin candado de modo prueba: %', v_faltan;
  END IF;
  IF (SELECT valor FROM public.compras_parametros WHERE clave = 'entrega_exige_pago') IS DISTINCT FROM 'false'::jsonb THEN
    RAISE NOTICE 'OJO: entrega_exige_pago está encendido (esta migración no lo cambia)';
  END IF;
  IF (SELECT count(*) FROM public.inventario_motivos_ajuste WHERE NOT es_prueba AND activo) < 6 THEN
    RAISE NOTICE 'Hay menos de 6 motivos reales activos (alguien desactivó alguno)';
  END IF;
END $postflight$;

NOTIFY pgrst, 'reload schema';
