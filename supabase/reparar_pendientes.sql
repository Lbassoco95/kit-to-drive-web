-- ============================================================================
-- REPARACIÓN · los scripts que nunca se aplicaron
--
-- Se pega COMPLETO en el SQL editor de Supabase y se corre una sola vez.
--
-- Qué es esto: la concatenación, en el orden correcto, de los archivos de
-- `supabase/migrations/` que el diagnóstico del 2026-08-25 reportó como FALTA o
-- PARCIAL en producción. Los archivos originales siguen siendo la fuente de
-- verdad; esto existe para no depender de que alguien los pegue uno por uno y
-- en orden.
--
-- El SQL editor manda todo en UNA transacción: o quedan los seis, o no queda
-- ninguno. Verificado corriéndolo así sobre una base que reproduce el estado
-- exacto de producción.
--
-- Después de correrlo, `supabase/diagnostico_esquema.sql` debe salir todo
-- APLICADO.
-- ============================================================================


-- ==========================================================================
-- PARTE 1/6 · 20260819000010_bitacora_eliminaciones.sql
--
-- Sin esta tabla, BORRAR una remisión falla («Error al registrar la
-- eliminación» y ni siquiera borra) y el trigger de borrado de Control
-- Financiero truena.
-- ==========================================================================

-- Re-ejecutable: el SQL editor manda el archivo completo en UNA transacción,
-- así que una sentencia que falla por «already exists» revierte todo el resto.
-- Correrlo dos veces tiene que ser inocuo.

-- Table for audit log of deleted records
CREATE TABLE IF NOT EXISTS public.bitacora_eliminaciones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tabla TEXT NOT NULL,
  registro_id UUID NOT NULL,
  eliminado_por UUID REFERENCES auth.users(id),
  nombre_usuario TEXT,
  motivo TEXT NOT NULL,
  datos_eliminados JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE bitacora_eliminaciones ENABLE ROW LEVEL SECURITY;

-- RLS policies
DROP POLICY IF EXISTS "solo admin lee bitacora" ON public.bitacora_eliminaciones;
CREATE POLICY "solo admin lee bitacora" ON public.bitacora_eliminaciones 
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "sistema escribe bitacora" ON public.bitacora_eliminaciones;
CREATE POLICY "sistema escribe bitacora" ON public.bitacora_eliminaciones 
  FOR INSERT TO authenticated WITH CHECK (true);

-- Index for performance
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_tabla ON public.bitacora_eliminaciones(tabla);
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_registro_id ON public.bitacora_eliminaciones(registro_id);
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_eliminado_por ON public.bitacora_eliminaciones(eliminado_por);
CREATE INDEX IF NOT EXISTS idx_bitacora_eliminaciones_created_at ON public.bitacora_eliminaciones(created_at);


-- ==========================================================================
-- PARTE 2/6 · 20260823000002_capturar_seriales_unidad.sql
--
-- KIT-4b. Producción → Editar llama a esta RPC. Además liga la pieza a la
-- unidad: sin ella, un chasis con serial capturado se queda «disponible» y
-- se puede volver a configurar en otra unidad (inventario contado doble).
-- ==========================================================================

-- ============================================================================
-- KIT-4b · Capturar seriales ligando la pieza del inventario
--
-- El hueco: KIT-4 exige NS chasis y NS motor para cerrar el proceso, pero la
-- captura manual (Producción → Editar) escribía nada más en motocarros. Si el
-- capturista teclea un serial que SÍ está en el embarque, la pieza se queda en
-- 'disponible' y fábrica puede volver a configurarla en otra unidad —
-- inventario contado doble, que es justo lo que KIT-4 venía a arreglar.
--
-- Caso real que lo detonó (dmhzhyeivvuliumcgsmm, 2026-08-23): la unidad #1
-- (300cc 2026 AZUL, REM-002, cliente A410) está en LISTO desde el 14/07 sin
-- ninguno de los dos seriales.
--
-- Fecha: 2026-08-23
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.capturar_seriales_unidad(
  _motocarro_id uuid,
  _ns_chasis    text DEFAULT NULL,   -- NULL = no cambiar
  _ns_motor     text DEFAULT NULL)   -- NULL = no cambiar
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _m record; _ch text; _mo text;
  _ic record; _im record;
  _ch_vinculado boolean := false; _mo_vinculado boolean := false;
  _ch_detenido  boolean := false;
  _liberados text[] := '{}';
  _otra int;
BEGIN
  IF NOT (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'fabrica'::app_role)) THEN
    RAISE EXCEPTION 'Solo admin/fábrica puede capturar seriales';
  END IF;

  SELECT * INTO _m FROM motocarros WHERE id = _motocarro_id;
  IF _m IS NULL THEN RAISE EXCEPTION 'Unidad no encontrada'; END IF;

  -- Mismo saneo que la importación: mayúsculas, sin espacios ni signos.
  _ch := NULLIF(regexp_replace(upper(COALESCE(_ns_chasis,'')), '[^A-Z0-9-]', '', 'g'), '');
  _mo := NULLIF(regexp_replace(upper(COALESCE(_ns_motor ,'')), '[^A-Z0-9-]', '', 'g'), '');

  IF _ch IS NULL AND _mo IS NULL THEN
    RAISE EXCEPTION 'No se recibió ningún serial que capturar';
  END IF;
  IF _ch IS NOT NULL AND _ch !~ '^[A-Z0-9-]{4,30}$' THEN
    RAISE EXCEPTION 'NS chasis inválido: usa de 4 a 30 caracteres (letras, números o guion)';
  END IF;
  IF _mo IS NOT NULL AND _mo !~ '^[A-Z0-9-]{4,30}$' THEN
    RAISE EXCEPTION 'NS motor inválido: usa de 4 a 30 caracteres (letras, números o guion)';
  END IF;

  -- Un serial no puede estar en dos unidades: el UNIQUE de motocarros lo
  -- impide, pero el mensaje crudo de Postgres no dice en cuál está.
  IF _ch IS NOT NULL THEN
    SELECT orden_armado INTO _otra FROM motocarros WHERE ns_chasis = _ch AND id <> _motocarro_id;
    IF _otra IS NOT NULL THEN
      RAISE EXCEPTION 'El NS chasis % ya está capturado en la unidad #%', _ch, _otra;
    END IF;
  END IF;
  IF _mo IS NOT NULL THEN
    SELECT orden_armado INTO _otra FROM motocarros WHERE ns_motor = _mo AND id <> _motocarro_id;
    IF _otra IS NOT NULL THEN
      RAISE EXCEPTION 'El NS motor % ya está capturado en la unidad #%', _mo, _otra;
    END IF;
  END IF;

  -- ── Chasis ────────────────────────────────────────────────────────────────
  IF _ch IS NOT NULL THEN
    SELECT * INTO _ic FROM inventario_chasis WHERE numero_chasis = _ch;

    IF _ic.id IS NOT NULL AND _ic.motocarro_id IS NOT NULL AND _ic.motocarro_id <> _motocarro_id THEN
      RAISE EXCEPTION 'El chasis % ya es parte de otra unidad (#%): libérala antes de capturarlo aquí',
        _ch, (SELECT orden_armado FROM motocarros WHERE id = _ic.motocarro_id);
    END IF;

    -- Corregir un serial mal capturado: la pieza vieja vuelve al pool.
    IF _m.ns_chasis IS NOT NULL AND _m.ns_chasis <> _ch THEN
      UPDATE inventario_chasis SET motocarro_id = NULL, fecha_configuracion = NULL
       WHERE motocarro_id = _motocarro_id AND numero_chasis <> _ch;
      IF FOUND THEN _liberados := array_append(_liberados, _m.ns_chasis); END IF;
    END IF;
  END IF;

  -- ── Motor ─────────────────────────────────────────────────────────────────
  IF _mo IS NOT NULL THEN
    SELECT * INTO _im FROM inventario_motor WHERE numero_motor = _mo;

    IF _im.id IS NOT NULL AND _im.motocarro_id IS NOT NULL AND _im.motocarro_id <> _motocarro_id THEN
      RAISE EXCEPTION 'El motor % ya es parte de otra unidad (#%): libérala antes de capturarlo aquí',
        _mo, (SELECT orden_armado FROM motocarros WHERE id = _im.motocarro_id);
    END IF;

    IF _m.ns_motor IS NOT NULL AND _m.ns_motor <> _mo THEN
      UPDATE inventario_motor SET motocarro_id = NULL, estatus = 'disponible', fecha_configuracion = NULL
       WHERE motocarro_id = _motocarro_id AND numero_motor <> _mo;
      IF FOUND THEN _liberados := array_append(_liberados, _m.ns_motor); END IF;
    END IF;
  END IF;

  UPDATE motocarros
     SET ns_chasis = COALESCE(_ch, ns_chasis),
         ns_motor  = COALESCE(_mo, ns_motor),
         updated_at = now()
   WHERE id = _motocarro_id;

  -- Ligar las piezas que sí existen en inventario. Si el serial es de un
  -- embarque viejo (no está en inventario_chasis/motor), no hay nada que
  -- ligar: la unidad queda con su serial y ya.
  IF _ch IS NOT NULL AND _ic.id IS NOT NULL THEN
    UPDATE inventario_chasis
       SET motocarro_id = _motocarro_id,
           fecha_configuracion = COALESCE(fecha_configuracion, now())
     WHERE id = _ic.id;
    -- El estatus lo decide la incidencia, si hay: un chasis en garantía no
    -- vuelve a 'configurado' nada más porque se capturó su serial.
    PERFORM public._sincronizar_estatus_chasis(_ic.id);
    _ch_vinculado := true;
    _ch_detenido  := public.chasis_bloqueado(_ic.id);
  END IF;

  IF _mo IS NOT NULL AND _im.id IS NOT NULL THEN
    UPDATE inventario_motor
       SET motocarro_id = _motocarro_id, estatus = 'configurado',
           fecha_configuracion = COALESCE(fecha_configuracion, now())
     WHERE id = _im.id;
    _mo_vinculado := true;
  END IF;

  -- Cuadrar el contenedor de las piezas ligadas y los conteos por color.
  UPDATE contenedores c SET total_unidades =
    (SELECT count(*) FROM inventario_chasis ic
      WHERE ic.contenedor_id = c.id AND ic.motocarro_id IS NOT NULL)
   WHERE c.id IN (_ic.contenedor_id, _m.contenedor_id) AND c.id IS NOT NULL;

  PERFORM public.recalcular_inventario_colores();

  RETURN jsonb_build_object(
    'ok', true,
    'orden_armado', _m.orden_armado,
    'ns_chasis', COALESCE(_ch, _m.ns_chasis),
    'ns_motor',  COALESCE(_mo, _m.ns_motor),
    'chasis_vinculado', _ch_vinculado,
    'motor_vinculado',  _mo_vinculado,
    'chasis_detenido',  _ch_detenido,
    'piezas_liberadas', to_jsonb(_liberados),
    'cierra_proceso', (COALESCE(_ch, _m.ns_chasis) IS NOT NULL
                   AND COALESCE(_mo, _m.ns_motor)  IS NOT NULL));
END; $$;

GRANT EXECUTE ON FUNCTION public.capturar_seriales_unidad(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.capturar_seriales_unidad(uuid, text, text) IS
  'Captura NS chasis / NS motor de una unidad y liga la pieza del inventario '
  'cuando el serial existe, para que no se quede contada como disponible. '
  'Úsala en lugar de un UPDATE directo a motocarros.';


-- ==========================================================================
-- PARTE 3/6 · 20260824000003_usuario_activo_se_aplica.sql
--
-- Sin `usuario_activo()`, dar de baja a alguien no significa nada en la
-- base: el RLS lo sigue dejando leer.
-- ==========================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- `profiles.activo` deja de ser decorativo
--
-- Hasta ahora desactivar a alguien desde Sistema → Usuarios sólo lo pintaba en
-- gris en esa lista: no se validaba en el login, ni en `ProtectedRoute`, ni en
-- ninguna política de RLS. Un usuario «inactivo» entraba igual y leía igual.
--
-- En vez de perseguir cada política una por una, se aprovecha que TODAS pasan
-- por el mismo puñado de helpers (`has_role`, `es_area`, `nivel_al_menos`,
-- `es_admin_area`, `es_admin_global`, `supervisa_area`). Con que esos devuelvan
-- FALSE para un usuario dado de baja, el corte aplica en todo el sistema de
-- golpe y sin reescribir una sola política.
--
-- Criterio conservador a propósito: se bloquea sólo a quien está marcado
-- explícitamente como inactivo. Un `profiles` inexistente o un `activo` nulo
-- NO deja a nadie fuera — un error de datos no debe convertirse en un usuario
-- que no puede trabajar.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. El predicado, en un solo lugar ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.usuario_activo(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = _user_id AND p.activo IS FALSE
  )
$$;

COMMENT ON FUNCTION public.usuario_activo(UUID) IS
  'FALSE sólo si el usuario está marcado explícitamente como inactivo en '
  'profiles.activo. Un perfil ausente o nulo cuenta como activo, para que un '
  'hueco de datos no bloquee a nadie. Lo consultan todos los helpers de rol.';

REVOKE EXECUTE ON FUNCTION public.usuario_activo(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.usuario_activo(UUID) TO authenticated;

-- ── 2. Los helpers de rol lo respetan ──────────────────────────────────────
-- Rol legacy.
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

-- Área.
CREATE OR REPLACE FUNCTION public.es_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND area = _area)
$$;

-- Nivel mínimo.
CREATE OR REPLACE FUNCTION public.nivel_al_menos(_user_id UUID, _nivel public.user_nivel)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id AND public.nivel_rank(nivel) >= public.nivel_rank(_nivel)
     )
$$;

-- Administrador de área (o global).
CREATE OR REPLACE FUNCTION public.es_admin_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id AND nivel = 'admin' AND (area = _area OR area = 'direccion')
     )
$$;

-- Administrador global (Dirección).
CREATE OR REPLACE FUNCTION public.es_admin_global(_user_id UUID)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id AND nivel = 'admin' AND area = 'direccion'
     )
$$;

-- Supervisa o administra el área.
CREATE OR REPLACE FUNCTION public.supervisa_area(_user_id UUID, _area public.user_area)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.usuario_activo(_user_id)
     AND EXISTS (
       SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id
          AND public.nivel_rank(nivel) >= 2
          AND (area = _area OR (area = 'direccion' AND nivel = 'admin'))
     )
$$;

-- ── 3. El dueño de una remisión tampoco entra si está dado de baja ─────────
-- Varias políticas caen a `vendedor_id = auth.uid()` cuando el rol no alcanza.
-- Sin esto, un vendedor desactivado seguiría leyendo y editando lo suyo.
DROP POLICY IF EXISTS "leer remisiones por rol" ON public.remisiones;
CREATE POLICY "leer remisiones por rol" ON public.remisiones
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR has_role(auth.uid(),'ventas'::app_role)
  OR (vendedor_id = auth.uid() AND public.usuario_activo(auth.uid()))
);

DROP POLICY IF EXISTS "actualizar remisiones" ON public.remisiones;
CREATE POLICY "actualizar remisiones" ON public.remisiones
FOR UPDATE USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR (vendedor_id = auth.uid() AND public.usuario_activo(auth.uid()))
);

DROP POLICY IF EXISTS "leer motocarros por rol" ON public.motocarros;
CREATE POLICY "leer motocarros por rol" ON public.motocarros
FOR SELECT USING (
  has_role(auth.uid(),'admin'::app_role)
  OR has_role(auth.uid(),'fabrica'::app_role)
  OR has_role(auth.uid(),'logistica'::app_role)
  OR has_role(auth.uid(),'coordinador'::app_role)
  OR has_role(auth.uid(),'finanzas'::app_role)
  OR has_role(auth.uid(),'admin_financiero'::app_role)
  OR has_role(auth.uid(),'ventas'::app_role)
  OR (public.usuario_activo(auth.uid()) AND remision_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM remisiones r
         WHERE r.id = motocarros.remision_id AND r.vendedor_id = auth.uid()))
);

-- ── Verificación ───────────────────────────────────────────────────────────
-- 1. Nadie activo debe perder permisos: esta consulta lista a cada usuario con
--    lo que los helpers responden hoy. Los activos deben verse igual que antes.
SELECT p.nombre_completo, p.activo, ur.area, ur.nivel,
       public.usuario_activo(ur.user_id)              AS activo_efectivo,
       public.es_area(ur.user_id, ur.area)            AS pasa_su_area,
       public.has_role(ur.user_id, ur.role)           AS pasa_su_rol_legacy
  FROM public.user_roles ur
  JOIN public.profiles p ON p.id = ur.user_id
 ORDER BY p.activo DESC, ur.area, ur.nivel, p.nombre_completo;

-- 2. Ningún usuario activo debe salir con `pasa_su_area = false`. Si aparece
--    alguno aquí, algo se rompió y hay que revisar antes de seguir.
SELECT p.nombre_completo, ur.area, ur.nivel
  FROM public.user_roles ur
  JOIN public.profiles p ON p.id = ur.user_id
 WHERE p.activo AND NOT public.es_area(ur.user_id, ur.area);


-- ==========================================================================
-- PARTE 4/6 · 20260824000002_comercial_lee_toda_la_bandeja.sql
--
-- Falta la política `comercial lee motocarros`: el equipo comercial ve la
-- remisión pero no sus unidades.
-- ==========================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- Comercial lee la bandeja completa, sin importar el nivel
--
-- `20260823000005_usuarios_niveles_areas.sql` dejó la lectura de remisiones
-- amarrada a `supervisa_area('comercial')`, o sea supervisor para arriba. Un
-- **operador** de Comercial quedaba viendo sólo lo suyo, que es justo el
-- problema que `20260824000001` había resuelto para el rol `ventas`: el equipo
-- comercial no compartía la misma información y un vendedor recién dado de
-- alta abría la bandeja vacía.
--
-- Aquí se separan las dos cosas, que no son la misma:
--
--   LEER  → toda el área comercial, en cualquier nivel. Todos trabajan sobre
--           la misma información.
--   ESCRIBIR → sigue por nivel. El operador captura y edita lo suyo; el
--           supervisor corrige lo de cualquiera; el administrador borra.
--
-- No se toca ninguna política de escritura.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. remisiones: lectura para toda el área comercial ─────────────────────
DROP POLICY IF EXISTS "comercial lee remisiones" ON public.remisiones;
CREATE POLICY "comercial lee remisiones" ON public.remisiones
FOR SELECT TO authenticated
USING (
  public.es_area(auth.uid(), 'comercial')      -- ← antes: supervisa_area(...)
  OR public.es_area(auth.uid(), 'direccion')
  OR public.es_area(auth.uid(), 'administracion')
);

-- ── 2. motocarros: lo mismo, o las tarjetas salen sin chasis ───────────────
-- Este hueco no era sólo del operador. El rol legacy se deriva de (área,nivel)
-- por trigger, así que un supervisor de Comercial queda con `coordinador_ventas`
-- y un administrador con `director_ventas`; ninguno de los dos aparece en
-- `leer motocarros por rol`, y `direccion lee motocarros` sólo cubre Dirección
-- y Administración. Resultado: veían la remisión pero no sus unidades.
DROP POLICY IF EXISTS "comercial lee motocarros" ON public.motocarros;
CREATE POLICY "comercial lee motocarros" ON public.motocarros
FOR SELECT TO authenticated
USING (public.es_area(auth.uid(), 'comercial'));

-- ── Verificación ───────────────────────────────────────────────────────────
-- 1. Las dos políticas deben resolverse por área, no por nivel.
SELECT tablename, policyname, qual
  FROM pg_policies
 WHERE schemaname = 'public'
   AND policyname IN ('comercial lee remisiones','comercial lee motocarros');

-- 2. Cada quien con su área y su nivel, y si lee la bandeja completa.
SELECT p.nombre_completo, ur.area, ur.nivel, ur.role AS rol_legacy_derivado,
       public.es_area(ur.user_id, 'comercial') AS lee_bandeja_comercial
  FROM public.user_roles ur
  JOIN public.profiles p ON p.id = ur.user_id
 ORDER BY ur.area, ur.nivel, p.nombre_completo;

-- 3. La escritura NO debe haberse abierto: sigue por nivel.
SELECT policyname, cmd, qual, with_check
  FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'remisiones' AND cmd <> 'SELECT'
 ORDER BY cmd, policyname;


-- ==========================================================================
-- PARTE 5/6 · 20260717000003_clientes_expediente_digital.sql
--
-- Columnas del expediente de clientes (rfc, codigo_postal, razon_social,
-- email_cobranza) que la pantalla de Clientes ya captura.
-- ==========================================================================

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


-- ==========================================================================
-- PARTE 6/6 · 20260819000001_parts_inventory.sql
--
-- `contenedor_partes`. Nadie la escribe: `importar_partes_excel` nunca se
-- aplicó y se borró del repo el 2026-09-08. La tabla se crea igual, vacía.
-- ==========================================================================

-- Re-ejecutable: el SQL editor manda el archivo completo en UNA transacción,
-- así que una sentencia que falla por «already exists» revierte todo el resto.
-- Correrlo dos veces tiene que ser inocuo.

-- Parts inventory for containers
CREATE TABLE IF NOT EXISTS public.contenedor_partes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contenedor_id UUID NOT NULL REFERENCES public.contenedores(id) ON DELETE CASCADE,
  descripcion TEXT NOT NULL, -- English name from DESCRIPTIONS column
  modelo TEXT,
  cantidad_esperada INTEGER NOT NULL DEFAULT 0,
  cantidad_recibida INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.contenedor_partes ENABLE ROW LEVEL SECURITY;

-- RLS policies for contenedor_partes
DROP POLICY IF EXISTS "leer partes contenedor" ON public.contenedor_partes;
CREATE POLICY "leer partes contenedor" ON public.contenedor_partes FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "escribir partes contenedor admin/fabrica" ON public.contenedor_partes;
CREATE POLICY "escribir partes contenedor admin/fabrica" ON public.contenedor_partes FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
DROP POLICY IF EXISTS "actualizar partes contenedor admin/fabrica" ON public.contenedor_partes;
CREATE POLICY "actualizar partes contenedor admin/fabrica" ON public.contenedor_partes FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'fabrica'));
DROP POLICY IF EXISTS "borrar partes contenedor admin" ON public.contenedor_partes;
CREATE POLICY "borrar partes contenedor admin" ON public.contenedor_partes FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));

-- updated_at trigger
DROP TRIGGER IF EXISTS trg_contenedor_partes_updated ON public.contenedor_partes;
CREATE TRIGGER trg_contenedor_partes_updated BEFORE UPDATE ON public.contenedor_partes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Index for performance
CREATE INDEX IF NOT EXISTS idx_contenedor_partes_contenedor ON public.contenedor_partes(contenedor_id);


-- ==========================================================================
-- CIERRE · comprobación


-- ============================================================================
DO $reparacion$
DECLARE _faltan text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.bitacora_eliminaciones') IS NULL THEN
    _faltan := _faltan || 'tabla bitacora_eliminaciones'::text; END IF;
  IF to_regprocedure('public.capturar_seriales_unidad(uuid,text,text)') IS NULL THEN
    _faltan := _faltan || 'capturar_seriales_unidad(uuid,text,text)'::text; END IF;
  IF to_regprocedure('public.usuario_activo(uuid)') IS NULL THEN
    _faltan := _faltan || 'usuario_activo(uuid)'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                   AND tablename='motocarros' AND policyname='comercial lee motocarros') THEN
    _faltan := _faltan || 'política «comercial lee motocarros»'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
                   AND table_name='clientes' AND column_name='rfc') THEN
    _faltan := _faltan || 'clientes.rfc y el resto del expediente'::text; END IF;
  IF to_regclass('public.contenedor_partes') IS NULL THEN
    _faltan := _faltan || 'tabla contenedor_partes'::text; END IF;

  IF array_length(_faltan, 1) > 0 THEN
    RAISE EXCEPTION E'La reparación quedó incompleta, se revierte:\n  · %',
      array_to_string(_faltan, E'\n  · ');
  END IF;
  RAISE NOTICE 'Reparación completa. Corre supabase/diagnostico_esquema.sql para confirmar.';
END $reparacion$;
