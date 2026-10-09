-- ============================================================================
-- La escalera del área Comercial estaba invertida
--
-- Medido con RLS real sobre producción reproducida (2026-08-25):
--
--   operación             com/operador  com/supervisor  com/admin  dirección
--   remisión                   SÍ             no            no        SÍ
--   remision_item              SÍ             no            no        SÍ
--   crm_oportunidad            SÍ             SÍ            no        SÍ
--   crm_actividad              SÍ             SÍ            no        SÍ
--   crm_ruta                   SÍ             SÍ            no        SÍ
--
-- Mientras más alto el nivel, menos podía hacer. La causa: cuando se migró a
-- ÁREA × NIVEL (20260823000005) el rol legado pasó a DERIVARSE — un supervisor
-- de Comercial es `coordinador_ventas` y un administrador `director_ventas` —
-- pero estas políticas de ESCRITURA se quedaron escritas contra los roles
-- viejos (`ventas`, `coordinador`, `admin`), que ya no incluyen a esos dos.
-- La LECTURA sí se migró (20260824000001/2), y el UPDATE de remisiones también
-- (`comercial supervisa remisiones`); el INSERT nunca.
--
-- Regla que se aplica aquí, y que es la del modelo: **cada nivel puede al menos
-- lo que puede el de abajo.**
--   · operador   → lo suyo
--   · supervisor → todo lo de su área
--   · admin      → todo lo de su área
--   · Dirección  → todo
--
-- No se ensancha nada más: nadie gana acceso fuera de su área, y quien está
-- dado de baja sigue fuera (`usuario_activo` vive dentro de `es_area` y
-- `supervisa_area`).
--
-- Fecha: 2026-08-25
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('public.es_area(uuid,public.user_area)') IS NULL
     OR to_regprocedure('public.supervisa_area(uuid,public.user_area)') IS NULL THEN
    RAISE EXCEPTION 'Faltan los helpers de ÁREA × NIVEL. Corre antes 20260823000005_usuarios_niveles_areas.sql y 20260824000003_usuario_activo_se_aplica.sql. No se modificó nada.';
  END IF;
END $preflight$;


-- ============================================================================
-- BLOQUE 1 · Remisiones: capturar
-- ============================================================================
-- El supervisor y el administrador de Comercial capturan a nombre de quien sea
-- de su equipo (es justo lo que hacen cuando cubren a un vendedor); el operador
-- sólo a su nombre, igual que antes.

DROP POLICY IF EXISTS "crear remisiones" ON public.remisiones;
CREATE POLICY "crear remisiones" ON public.remisiones
  FOR INSERT TO authenticated WITH CHECK (
    public.es_area(auth.uid(), 'direccion'::public.user_area)
    OR public.supervisa_area(auth.uid(), 'comercial'::public.user_area)
    OR (public.es_area(auth.uid(), 'comercial'::public.user_area) AND vendedor_id = auth.uid())
  );


-- ============================================================================
-- BLOQUE 2 · Las líneas de la remisión van con la remisión
-- ============================================================================
-- Sin esto, arreglar el INSERT de arriba no serviría de nada: la remisión se
-- crearía vacía porque los renglones se rechazan aparte.

DROP POLICY IF EXISTS "remision_items_insert" ON public.remision_items;
CREATE POLICY "remision_items_insert" ON public.remision_items
  FOR INSERT TO authenticated WITH CHECK (
    public.es_area(auth.uid(), 'direccion'::public.user_area)
    OR public.supervisa_area(auth.uid(), 'comercial'::public.user_area)
    OR (public.es_area(auth.uid(), 'comercial'::public.user_area)
        AND EXISTS (SELECT 1 FROM public.remisiones r
                     WHERE r.id = remision_id AND r.vendedor_id = auth.uid()))
  );


-- ============================================================================
-- BLOQUE 3 · CRM: oportunidades, actividades y rutas
-- ============================================================================
-- Aquí el hueco era el administrador del área: podía leer el pipeline de su
-- equipo y no podía dar de alta una oportunidad.

DO $crm$
DECLARE _t text;
BEGIN
  FOREACH _t IN ARRAY ARRAY['crm_oportunidades','crm_actividades','crm_rutas'] LOOP
    -- Alta: cualquiera del área comercial; el operador queda amarrado a su
    -- nombre por el trigger/DEFAULT de vendedor_id, igual que hoy.
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
                   replace(_t,'crm_','crm_')||'_insert_area', _t);
    EXECUTE format($p$
      DROP POLICY IF EXISTS "%1$s_insert_area" ON public.%1$I;
      CREATE POLICY "%1$s_insert_area" ON public.%1$I
        FOR INSERT TO authenticated WITH CHECK (
          public.es_area(auth.uid(), 'direccion'::public.user_area)
          OR public.es_area(auth.uid(), 'comercial'::public.user_area)
        );
    $p$, _t);

    -- Edición: lo suyo el operador, todo lo del área de supervisor para arriba.
    EXECUTE format($p$
      DROP POLICY IF EXISTS "%1$s_update_area" ON public.%1$I;
      CREATE POLICY "%1$s_update_area" ON public.%1$I
        FOR UPDATE TO authenticated USING (
          public.es_area(auth.uid(), 'direccion'::public.user_area)
          OR public.supervisa_area(auth.uid(), 'comercial'::public.user_area)
          OR (public.es_area(auth.uid(), 'comercial'::public.user_area) AND vendedor_id = auth.uid())
        );
    $p$, _t);

    -- Borrado: sólo supervisor para arriba, como estaba pensado.
    EXECUTE format($p$
      DROP POLICY IF EXISTS "%1$s_delete_area" ON public.%1$I;
      CREATE POLICY "%1$s_delete_area" ON public.%1$I
        FOR DELETE TO authenticated USING (
          public.es_area(auth.uid(), 'direccion'::public.user_area)
          OR public.supervisa_area(auth.uid(), 'comercial'::public.user_area)
        );
    $p$, _t);
  END LOOP;
END $crm$;


-- ============================================================================
-- BLOQUE 4 · Comentarios de motocarro
-- ============================================================================
-- La política pedía `ventas` o `coordinador`: el supervisor y el administrador
-- de Comercial no podían dejar un comentario en una unidad.

DROP POLICY IF EXISTS "insertar comentario motocarro" ON public.comentarios_motocarros;
CREATE POLICY "insertar comentario motocarro" ON public.comentarios_motocarros
  FOR INSERT TO authenticated WITH CHECK (
    usuario_id = auth.uid()
    AND (
      public.es_area(auth.uid(), 'direccion'::public.user_area)
      OR public.es_area(auth.uid(), 'comercial'::public.user_area)
      OR public.es_area(auth.uid(), 'fabrica'::public.user_area)
      OR public.es_area(auth.uid(), 'almacen_logistica'::public.user_area)
    )
  );


-- ============================================================================
-- BLOQUE 5 · Comprobación
-- ============================================================================

DO $postflight$
DECLARE _faltan text[] := ARRAY[]::text[]; _t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                   AND tablename='remisiones' AND policyname='crear remisiones'
                   AND with_check LIKE '%supervisa_area%') THEN
    _faltan := _faltan || 'crear remisiones'::text; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                   AND tablename='remision_items' AND policyname='remision_items_insert'
                   AND with_check LIKE '%supervisa_area%') THEN
    _faltan := _faltan || 'remision_items_insert'::text; END IF;
  FOREACH _t IN ARRAY ARRAY['crm_oportunidades','crm_actividades','crm_rutas'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename=_t AND policyname = _t||'_insert_area') THEN
      _faltan := _faltan || (_t||'_insert_area')::text; END IF;
  END LOOP;

  IF array_length(_faltan,1) > 0 THEN
    RAISE EXCEPTION E'Quedó incompleto, se revierte:\n  · %', array_to_string(_faltan, E'\n  · ');
  END IF;
  RAISE NOTICE 'Escalera de Comercial enderezada: supervisor y administrador pueden al menos lo que puede el operador.';
END $postflight$;
