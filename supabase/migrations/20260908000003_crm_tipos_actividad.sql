-- ============================================================================
-- Los tipos de actividad que la pantalla ofrece, la base los acepta
-- Fecha: 2026-09-08
--
-- Qué estaba pasando
-- ------------------
-- El selector de tipo de actividad del CRM ofrece diez opciones. El CHECK de
-- `crm_actividades.tipo` en producción aceptaba siete, así que tres de ellas
-- fallaban al guardar con un error crudo de Postgres en un toast:
--
--   · «Otro»          — en el formulario de programar visita
--   · «Videollamada»  — en el formulario de actividad
--   · «Cotización»    — en el formulario de actividad
--
-- Elegir cualquiera de esas tres y guardar no registraba la actividad. Y las
-- tres tienen su etiqueta en el diccionario (`t.crm.tipoActividad`), así que
-- la intención siempre fue soportarlas: lo que quedó atrás fue el CHECK.
--
-- Un detalle que este arreglo también cierra: el CHECK vivo NO coincidía con
-- el repo. `20260717000004_crm_fixes.sql` lo declara con `cotizacion`
-- adentro, y la base no lo tenía — alguien lo cambió a mano en el SQL editor
-- y quitó ese valor. Aquí quedan los dos lados iguales otra vez.
--
-- Por qué ampliar el CHECK y no quitar las opciones de la pantalla: porque
-- son tipos de actividad legítimos de una operación de ventas, y porque es lo
-- que ya hizo `20260717000004` cuando pasó lo mismo (ahí se sustituyó un
-- `ALTER TYPE ... ADD VALUE` sobre un enum inexistente por la ampliación del
-- CHECK, «que es lo que de verdad hacía falta»).
--
-- Ojo con `videollamada`: es válido en `canal_contacto` desde hace tiempo, y
-- de ahí venía la confusión — estaba en una lista y no en la otra.
--
-- ADVERTENCIA: idempotente, para el SQL editor de Supabase. NO usar
-- `supabase db push`.
-- ============================================================================

DO $preflight$
BEGIN
  IF to_regclass('public.crm_actividades') IS NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Falta la tabla crm_actividades (corre antes 20260714000002_crm_ventas.sql).';
  END IF;
END $preflight$;


-- ============================================================================
-- El CHECK, con las diez que la pantalla ofrece
-- ============================================================================
-- Se revisa primero que ninguna fila viole la lista nueva: la lista sólo
-- crece, así que no debería pasar, pero si alguien metió otro valor a mano el
-- ALTER fallaría a media transacción y se llevaría el archivo por delante.

DO $tipos$
DECLARE _fuera text;
BEGIN
  SELECT string_agg(DISTINCT tipo, ', ') INTO _fuera
    FROM public.crm_actividades
   WHERE tipo IS NOT NULL
     AND tipo NOT IN ('visita','llamada','demo','seguimiento','cotizacion',
                      'email','whatsapp','nota','videollamada','otro');
  IF _fuera IS NOT NULL THEN
    RAISE EXCEPTION 'No se modificó nada. Hay actividades con un tipo que la lista nueva no cubre: %. Corrígelas o agrega esos valores a este script.', _fuera;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.crm_actividades'::regclass
                AND conname  = 'crm_actividades_tipo_check') THEN
    ALTER TABLE public.crm_actividades DROP CONSTRAINT crm_actividades_tipo_check;
  END IF;

  ALTER TABLE public.crm_actividades ADD CONSTRAINT crm_actividades_tipo_check
    CHECK (tipo IN ('visita','llamada','demo','seguimiento','cotizacion',
                    'email','whatsapp','nota','videollamada','otro'));
END $tipos$;


-- ============================================================================
-- Postflight: que quedó, y que acepta las tres que faltaban
-- ============================================================================
DO $postflight$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.crm_actividades'::regclass
                    AND conname  = 'crm_actividades_tipo_check'
                    AND pg_get_constraintdef(oid) LIKE '%videollamada%'
                    AND pg_get_constraintdef(oid) LIKE '%cotizacion%'
                    AND pg_get_constraintdef(oid) LIKE '%otro%') THEN
    RAISE EXCEPTION 'El CHECK no quedó con los tipos nuevos. Revisa el bloque anterior.';
  END IF;
END $postflight$;
