-- ============================================================================
-- Quién puede capturar, hoy, con las políticas que están puestas.
-- SOLO LECTURA. Evalúa las mismas funciones que usa el RLS, usuario por usuario.
-- ============================================================================
SELECT p.nombre_completo,
       ur.area::text  AS area,
       ur.nivel::text AS nivel,
       ur.role::text  AS rol_derivado,
       CASE WHEN p.activo IS FALSE THEN 'DADO DE BAJA' ELSE 'activo' END AS estado,
       CASE
         WHEN public.es_area(ur.user_id,'direccion')            THEN 'todo'
         WHEN public.supervisa_area(ur.user_id,'comercial')     THEN 'toda su área'
         WHEN public.es_area(ur.user_id,'comercial')            THEN 'sólo a su nombre'
         ELSE 'no captura remisiones'
       END AS puede_capturar_remisiones
  FROM public.user_roles ur
  LEFT JOIN public.profiles p ON p.id = ur.user_id
 ORDER BY ur.area, public.nivel_rank(ur.nivel) DESC, p.nombre_completo;
