-- ============================================================================
-- ¿Qué scripts están aplicados de verdad en esta base?
--
-- Este proyecto no lleva tabla de migraciones: los scripts se pegan a mano en
-- el SQL editor. Cuando uno no se corre —o se corre y revienta a media página,
-- que en el SQL editor es lo mismo porque todo va en una transacción— no queda
-- rastro: la app compila igual, y el hueco sale semanas después como
-- «column ... does not exist» en una pantalla cualquiera.
--
-- Esto lo revisa al revés: por cada script, busca los objetos que ese script
-- debería haber dejado. Es de SOLO LECTURA — no modifica nada.
--
-- Cómo se usa: pégalo completo en el SQL editor de Supabase y corre.
--   · APLICADO  → el script está.
--   · FALTA     → hay que correr ese archivo de supabase/migrations/.
--   · PARCIAL   → quedó a medias; vuelve a correr el archivo completo
--                 (todos son idempotentes) y revisa el error que salga.
--
--   · SUPERADO → otro script posterior lo reemplazó por completo; no hay que
--                 correrlo y no se revisa.
--
-- AQUÍ SE REGISTRAN TODOS LOS SCRIPTS. Si `supabase/migrations/` tiene un
-- archivo que no aparece abajo (ni en `esperado` ni en `superado`), la prueba
-- `src/test/inventario-migraciones.test.ts` falla: un script sin registrar es
-- un hueco que este diagnóstico no puede ver, y así fue como
-- 20260827000001 llevaba días sin correr mientras la pantalla de Clientes
-- decía «Sin resultados».
--
-- Tipos de objeto que se pueden pedir en `esperado`:
--   tabla|nombre                       · vista|nombre
--   columna|tabla.columna              · funcion|nombre(tipos)
--   columna|tabla.columna|texto        · el DEFAULT debe contener ese texto
--   funcion|nombre(tipos)|texto        · el cuerpo debe contener ese texto
--   trigger|tabla.trigger              · indice|nombre[|texto del índice]
--   secuencia|nombre                  · tabla|nombre y vista|nombre
--   politica|tabla.politica[|texto]    · tipo|enum.valor
--   (política de storage: politica|storage.objects.nombre[|texto])
--   restriccion|tabla.restriccion[|texto]
--   sin_privilegio|funcion(tipos)|rol  · ese rol NO debe poder ejecutarla
--
-- Para saber qué le falta a UN script antes de correrlo, hay revisiones
-- puntuales al lado de este archivo, p. ej.
-- supabase/revisar_antes_de_20260902000001.sql.
-- ============================================================================

WITH esperado(script, objeto) AS (VALUES
  -- Base del sistema. Si algo de esto falta, la app no arranca; se registra
  -- para que el inventario esté completo y no por miedo a que se pierda.
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tipo|app_role.admin'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|user_roles'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|profiles'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|clientes'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|contenedores'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|remisiones'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|motocarros'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|bitacora_eventos'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'tabla|config_general'),
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'funcion|has_role(uuid,app_role)'),
  -- Endurecimiento de permisos: `anon` no debe poder preguntar por roles.
  -- No deja objetos nuevos, así que se revisa por lo que QUITA.
  ('20260503015323_a96fe55f-42c2-460e-b39d-70ee25c5777b', 'sin_privilegio|get_my_role()|anon'),
  ('20260503015323_a96fe55f-42c2-460e-b39d-70ee25c5777b', 'sin_privilegio|handle_new_user()|authenticated'),
  ('20260503023936_e271aa15-dd34-4c36-970b-6b30a5eaf2a4', 'funcion|log_motocarros_changes()'),
  ('20260503023936_e271aa15-dd34-4c36-970b-6b30a5eaf2a4', 'funcion|log_remisiones_changes()'),
  ('20260503190820_5b97bddd-db06-4817-abf2-cc96562f8fa0', 'funcion|auto_asignar_motocarros_remision()'),
  ('20260503190820_5b97bddd-db06-4817-abf2-cc96562f8fa0', 'funcion|reintentar_asignar_remision(uuid)'),
  ('20260503192247_c54db563-2e9e-43a1-ad2b-757bd198e7ac', 'tipo|app_role.coordinador'),
  ('20260503192333_cb78101f-581a-4ca7-ba6c-2917c43edb25', 'columna|motocarros.fecha_propuesta_entrega'),
  ('20260503192333_cb78101f-581a-4ca7-ba6c-2917c43edb25', 'columna|motocarros.confirmada_logistica_at'),
  ('20260503192333_cb78101f-581a-4ca7-ba6c-2917c43edb25', 'funcion|proponer_fecha_entrega(uuid,date,text)'),
  ('20260503192333_cb78101f-581a-4ca7-ba6c-2917c43edb25', 'funcion|confirmar_fecha_entrega(uuid,text)'),
  ('20260503193601_1f2d647e-2717-44a2-a009-d1616587e0ac', 'funcion|recibir_contenedor(text,date,text,text,jsonb)'),
  ('20260629000001_reportes_comentarios',         'tabla|reportes_turno'),
  ('20260629000001_reportes_comentarios',         'tabla|comentarios_motocarros'),
  ('20260629000002_profiles_email',               'columna|profiles.email'),
  ('20260629000003_remision_items',               'tabla|remision_items'),
  ('20260629000003_remision_items',               'columna|remisiones.tipo_remision'),
  -- Ojo: la restricción `remisiones_tipo_remision_check` NO sirve para
  -- reconocer este script, porque 20260629000005 la borra a propósito (el
  -- tipo pasó a vivir en cada renglón). Lo que queda es el default de la
  -- columna, que este script cambió de 'cabina' a 'motocarro'.
  ('20260629000004_tipo_remision_v2',             'columna|remisiones.tipo_remision|motocarro'),
  ('20260629000005_remision_items_tipo_servicio', 'columna|remision_items.tipo_servicio'),
  ('20260713000001_finanzas_module',              'tabla|pagos'),
  -- El bug era asignar un 300cc a una remisión de 200cc: la versión buena
  -- filtra por modelo y se distingue por el cuarto argumento.
  ('20260714000001_fix_asignar_chasis_modelo',    'funcion|asignar_chasis_remision(uuid,integer,text,text)'),
  ('20260714000002_crm_ventas',                   'tabla|crm_oportunidades'),
  ('20260714000002_crm_ventas',                   'tabla|crm_rutas'),
  ('20260717000003_clientes_expediente_digital',  'columna|clientes.rfc'),
  ('20260717000003_clientes_expediente_digital',  'columna|clientes.codigo_postal'),
  ('20260717000004_crm_fixes',                    'vista|v_reporte_pipeline'),
  ('20260717000004_crm_fixes',                    'columna|crm_oportunidades.limitante_notas'),
  ('20260717000007_crm_actividades_estatus',      'columna|crm_actividades.objetivo_visita'),
  ('20260819000001_parts_inventory',              'tabla|contenedor_partes'),
  ('20260819000004_inventario_chasis',            'tabla|inventario_chasis'),
  ('20260819000005_inventario_motor',             'tabla|inventario_motor'),
  ('20260819000006_inventario_partes',            'tabla|inventario_partes'),
  ('20260819000007_inventario_colores',           'tabla|inventario_colores'),
  ('20260819000009_importar_packing_list',        'funcion|importar_packing_list(uuid,jsonb)'),
  ('20260819000010_bitacora_eliminaciones',       'tabla|bitacora_eliminaciones'),
  -- El expediente del cliente: sin esto la ficha abre con las pestañas vacías.
  ('20260819000011_clientes_crm',                 'columna|clientes.activo'),
  ('20260819000011_clientes_crm',                 'tabla|clientes_comentarios'),
  ('20260819000011_clientes_crm',                 'tabla|clientes_bitacora'),

  -- KIT-1 · unidad = chasis + motor
  ('20260821000001_unidad_chasis_motor',          'columna|contenedores.total_chasis'),
  ('20260821000001_unidad_chasis_motor',          'funcion|importar_motores_inventario(uuid,text,jsonb)'),

  -- KIT-3 · configuración manual y nomenclatura comercial
  ('20260822000001_configuracion_manual_unidades','tabla|modelos_producto'),
  ('20260822000001_configuracion_manual_unidades','columna|modelos_producto.nombre_comercial'),
  ('20260822000001_configuracion_manual_unidades','tabla|bitacora_orden_armado'),
  ('20260822000001_configuracion_manual_unidades','funcion|desconfigurar_unidad(uuid,text)'),

  -- KIT-4 · incidencias, colores registrados, cierre con serial
  ('20260823000001_incidencias_chasis_colores_cierre','tabla|incidencias_chasis'),
  ('20260823000001_incidencias_chasis_colores_cierre','funcion|chasis_bloqueado(uuid)'),
  ('20260823000001_incidencias_chasis_colores_cierre','funcion|asignar_remision_items(uuid)'),
  ('20260823000001_incidencias_chasis_colores_cierre','columna|inventario_colores.piezas_total'),
  ('20260823000001_incidencias_chasis_colores_cierre','vista|v_stock_modelo_color'),
  ('20260823000001_incidencias_chasis_colores_cierre','trigger|motocarros.trg_exigir_serial_para_cerrar'),

  -- KIT-4b · captura de seriales ligando la pieza
  ('20260823000002_capturar_seriales_unidad',     'funcion|capturar_seriales_unidad(uuid,text,text)'),

  -- KIT-4c · color efectivo vs. color del VIN, y capacidad por color
  ('20260823000003_color_efectivo_capacidad',     'columna|inventario_chasis.color_original'),
  ('20260823000003_color_efectivo_capacidad',     'tabla|bitacora_color'),
  ('20260823000003_color_efectivo_capacidad',     'columna|inventario_colores.piezas_recibidas'),
  ('20260823000003_color_efectivo_capacidad',     'columna|v_stock_modelo_color.capacidad_color'),
  ('20260823000003_color_efectivo_capacidad',     'funcion|norm_color(text)'),
  ('20260823000003_color_efectivo_capacidad',     'funcion|cambiar_color_chasis(uuid,text,text)'),
  ('20260823000003_color_efectivo_capacidad',     'funcion|intercambiar_color_chasis(uuid,uuid,text)'),
  ('20260823000003_color_efectivo_capacidad',     'funcion|ajustar_capacidad_color(text,text,integer,text)'),
  ('20260823000003_color_efectivo_capacidad',     'funcion|configurar_unidad(uuid,uuid,integer,text)'),
  ('20260823000003_color_efectivo_capacidad',     'trigger|inventario_chasis.trg_chasis_color_original'),
  ('20260823000003_color_efectivo_capacidad',     'trigger|inventario_chasis.trg_verificar_capacidad_color'),

  -- KIT-4d · control financiero
  ('20260823000004_finanzas_ingresos_egresos',    'tabla|movimientos_financieros'),
  ('20260823000004_finanzas_ingresos_egresos',    'tabla|proveedores'),
  ('20260823000004_finanzas_ingresos_egresos',    'tabla|cuentas_financieras'),
  ('20260823000004_finanzas_ingresos_egresos',    'vista|v_saldos_cuentas'),

  -- Usuarios ÁREA × NIVEL y permisos
  -- Los OCHO helpers, no sólo es_area: este script dejaba pasar una base a la
  -- que le faltaba supervisa_area() y la reportaba como APLICADA, con lo que el
  -- hueco sólo salía cuando otro script se negaba a correr.
  ('20260823000005_usuarios_niveles_areas',       'columna|user_roles.area'),
  ('20260823000005_usuarios_niveles_areas',       'columna|user_roles.nivel'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|nivel_rank(user_nivel)'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|rol_legacy(user_area,user_nivel)'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|mi_area()'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|mi_nivel()'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|es_area(uuid,user_area)'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|nivel_al_menos(uuid,user_nivel)'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|es_admin_area(uuid,user_area)'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|es_admin_global(uuid)'),
  ('20260823000005_usuarios_niveles_areas',       'funcion|supervisa_area(uuid,user_area)'),
  ('20260824000001_remisiones_visibles_equipo_comercial','politica|remisiones.leer remisiones por rol'),
  ('20260824000002_comercial_lee_toda_la_bandeja','politica|remisiones.comercial lee remisiones'),
  ('20260824000002_comercial_lee_toda_la_bandeja','politica|motocarros.comercial lee motocarros'),
  ('20260824000003_usuario_activo_se_aplica',     'funcion|usuario_activo(uuid)'),
  -- La escalera de Comercial no es sólo el CRM: lo que más se nota es que el
  -- supervisor pueda capturar una remisión y sus renglones.
  ('20260825000001_comercial_escalera_de_permisos','politica|remisiones.crear remisiones|supervisa_area'),
  -- `remision_items_insert` NO se revisa aquí: 20260902000001 se hace cargo de
  -- ese permiso con `remision_items_insert_area`, y la política vieja deja de
  -- existir a propósito. Revisarla marcaría este script como PARCIAL para
  -- siempre.
  ('20260825000001_comercial_escalera_de_permisos','politica|crm_oportunidades.crm_oportunidades_insert_area'),
  ('20260825000001_comercial_escalera_de_permisos','politica|crm_actividades.crm_actividades_insert_area'),
  ('20260825000001_comercial_escalera_de_permisos','politica|crm_rutas.crm_rutas_insert_area'),

  -- Reutilizar el folio de una remisión cancelada: el UNIQUE completo se
  -- cambió por un índice único parcial que excluye las CANCELADA. Se pide con
  -- el texto, porque un índice con ese nombre pero sin el WHERE no es éste.
  ('20260826000002_folio_reutilizable_canceladas','indice|idx_remisiones_folio_activas|CANCELADA'),

  -- Asignación manual de motocarros a remisiones. `desasignar_` faltaba en
  -- producción aunque su gemela del mismo archivo sí estaba: el botón de
  -- liberar una unidad no servía.
  ('20260826000003_asignacion_manual_remisiones','funcion|asignar_motocarro_a_remision(uuid,uuid)'),
  ('20260826000003_asignacion_manual_remisiones','funcion|desasignar_motocarro_de_remision(uuid)'),

  -- Folio interno de clientes nuevos. ESTE es el que dejó a Clientes sin
  -- lista en producción: la pantalla pedía `clientes.folio_interno` y la base
  -- no la tenía, porque el script tronaba en su setval y se revertía entero.
  ('20260827000001_folio_interno_clientes_nuevos','columna|clientes.folio_interno'),
  ('20260827000001_folio_interno_clientes_nuevos','indice|idx_clientes_folio_interno_unico'),
  ('20260827000001_folio_interno_clientes_nuevos','secuencia|clientes_folio_interno_seq'),
  ('20260827000001_folio_interno_clientes_nuevos','funcion|generar_folio_interno_cliente()'),
  ('20260827000001_folio_interno_clientes_nuevos','trigger|clientes.trg_clientes_folio_interno'),

  -- Motocarro ya armado desde remisiones
  ('20260828000001_motocarro_ya_armado',          'funcion|crear_motocarro_ya_armado(text,text,text,text,uuid)'),

  -- El operador corrige y complementa sus remisiones, con motivo
  ('20260902000001_operador_edita_remisiones',    'funcion|rol_comercial(uuid)'),
  ('20260902000001_operador_edita_remisiones',    'funcion|puede_editar_remision(uuid,uuid)'),
  ('20260902000001_operador_edita_remisiones',    'funcion|puede_capturar_remision(uuid,uuid)'),
  ('20260902000001_operador_edita_remisiones',    'columna|remision_items.orden_linea'),
  ('20260902000001_operador_edita_remisiones',    'tabla|remisiones_bitacora'),
  ('20260902000001_operador_edita_remisiones',    'politica|remision_items.remision_items_update_area'),
  ('20260902000001_operador_edita_remisiones',    'politica|remision_items.remision_items_delete_area'),
  ('20260902000001_operador_edita_remisiones',    'politica|remision_items.remision_items_insert_area'),
  ('20260902000001_operador_edita_remisiones',    'politica|remisiones.comercial edita sus remisiones'),
  ('20260902000001_operador_edita_remisiones',    'politica|remisiones.comercial captura remisiones'),

  -- Fix: usuarios de Finanzas deben poder ver/descargar PDFs de remisiones.
  ('20260902223156_fix_remisiones_docs_lectura_finanzas', 'politica|storage.objects.leer docs remisiones operativos'),

  -- Avisos entre áreas y liberación de unidades
  ('20260903000001_avisos_entre_areas',           'tabla|avisos'),
  ('20260903000001_avisos_entre_areas',           'funcion|recibe_avisos_de(user_area,uuid)'),
  ('20260903000001_avisos_entre_areas',           'funcion|ajustar_unidades_remision(uuid,integer,text)'),
  ('20260903000001_avisos_entre_areas',           'trigger|avisos.trg_avisos_solo_acuse'),
  ('20260903000001_avisos_entre_areas',           'politica|avisos.leer avisos de mi area'),
  ('20260903000001_avisos_entre_areas',           'politica|avisos.mandar aviso'),
  ('20260903000001_avisos_entre_areas',           'politica|avisos.dar por visto'),

  -- Solicitudes a Fábrica cuando la unidad ya entró a armado
  ('20260904000001_solicitudes_a_fabrica',        'columna|avisos.requiere_respuesta'),
  ('20260904000001_solicitudes_a_fabrica',        'columna|avisos.estado'),
  ('20260904000001_solicitudes_a_fabrica',        'columna|avisos.accion'),
  ('20260904000001_solicitudes_a_fabrica',        'columna|avisos.usuario_destino'),
  ('20260904000001_solicitudes_a_fabrica',        'funcion|responder_solicitud(uuid,boolean,text)'),
  -- La política la redefinió después 20260925000001 (ahora usa destinatario_id),
  -- así que aquí sólo se pide que exista.
  ('20260904000001_solicitudes_a_fabrica',        'politica|avisos.leer avisos de mi area'),

  -- El cilindraje y el color del motocarro ya armado los declara Fábrica.
  -- Misma firma que 20260828000001, así que se reconoce por el cuerpo: la
  -- versión nueva es la que manda el color por `cambiar_color_chasis`.
  ('20260907000001_ya_armado_cilindraje_color',   'funcion|crear_motocarro_ya_armado(text,text,text,text,uuid)|cambiar_color_chasis'),

  -- Registrar una unidad que YA está armada no se atora por la cuenta de
  -- juegos de color: si no hay libre, se registra el extra con motivo.
  ('20260908000001_ya_armado_no_se_atora_por_capacidad', 'funcion|crear_motocarro_ya_armado(text,text,text,text,uuid)|capacidad_ajustada'),

  -- Las unidades que ya estaban ensambladas son un lote cerrado: se marcan,
  -- se cuentan y no pasan del tope.
  ('20260908000002_tope_unidades_ya_armadas',     'columna|motocarros.carga_ya_armado'),
  ('20260908000002_tope_unidades_ya_armadas',     'columna|config_general.limite_ya_armados'),
  ('20260908000002_tope_unidades_ya_armadas',     'vista|v_carga_ya_armados'),
  ('20260908000002_tope_unidades_ya_armadas',     'funcion|crear_motocarro_ya_armado(text,text,text,text,uuid)|limite_ya_armados'),

  -- Los tipos de actividad del CRM que la pantalla ofrece y la base rechazaba.
  ('20260908000003_crm_tipos_actividad',          'restriccion|crm_actividades.crm_actividades_tipo_check|videollamada'),

  -- Almacén de refacciones para venta (lista de precios, códigos duales, compat).
  ('20260922000001_almacen_refacciones',          'tabla|almacen_refacciones_productos'),
  ('20260922000001_almacen_refacciones',          'tabla|almacen_refacciones_codigos'),
  ('20260922000001_almacen_refacciones',          'tabla|almacen_refacciones_unidades'),
  ('20260922000001_almacen_refacciones',          'tabla|almacen_refacciones_producto_compat'),
  ('20260922000001_almacen_refacciones',          'tabla|almacen_refacciones_movimientos'),
  ('20260922000001_almacen_refacciones',          'tabla|almacen_refacciones_acceso'),
  ('20260922000001_almacen_refacciones',          'funcion|puede_ver_almacen_refacciones(uuid)'),
  ('20260922000001_almacen_refacciones',          'funcion|importar_almacen_refacciones(jsonb)'),
  ('20260922000001_almacen_refacciones',          'vista|v_almacen_refacciones'),

  -- Reproceso de descripción vs compatibilidades reutilizables.
  ('20260922000002_sincronizar_compat_refacciones', 'funcion|sincronizar_compat_refacciones(jsonb)'),

  -- Área Compras (dos pasos: enum primero, luego helpers/RLS).
  ('20260922000003_area_compras_enum',            'tipo|user_area.compras'),
  ('20260922000003_area_compras_enum',            'tipo|app_role.compras'),
  ('20260922000004_area_compras',                 'funcion|es_compras(uuid)'),
  ('20260922000004_area_compras',                 'funcion|es_compras_admin(uuid)'),
  ('20260922000004_area_compras',                 'funcion|rol_legacy(user_area,user_nivel)|compras'),
  ('20260922000004_area_compras',                 'politica|proveedores.proveedores_insert|es_compras'),

  -- Remisión de venta de refacciones: apartado, liberación en almacén y contingencia.
  ('20260923000001_remisiones_refacciones',       'tabla|remisiones_refacciones'),
  ('20260923000001_remisiones_refacciones',       'tabla|remision_refaccion_items'),
  ('20260923000001_remisiones_refacciones',       'tabla|remision_refaccion_eventos'),
  ('20260923000001_remisiones_refacciones',       'funcion|stock_bloqueado_producto(uuid)'),
  ('20260923000001_remisiones_refacciones',       'funcion|liberar_refaccion_remision(uuid,integer)'),
  ('20260923000001_remisiones_refacciones',       'funcion|liberar_refaccion_remision(uuid,integer)'),
  ('20260923000001_remisiones_refacciones',       'funcion|reportar_faltante_refaccion(uuid,integer,text)'),
  ('20260923000001_remisiones_refacciones',       'funcion|confirmar_sin_existencia_refaccion(uuid,text)'),
  ('20260923000001_remisiones_refacciones',       'funcion|cancelar_remision_refacciones(uuid,text)'),
  ('20260923000001_remisiones_refacciones',       'columna|v_almacen_refacciones.stock_disponible'),
  ('20260923000001_remisiones_refacciones',       'politica|remisiones_refacciones.leer remisiones refacciones|puede_leer_remision_refaccion'),

  ('20260925000004_remision_refacciones_canceladas', 'columna|remisiones_refacciones.motivo_cancelacion'),
  ('20260925000004_remision_refacciones_canceladas', 'columna|remisiones_refacciones.cancelada_at'),
  ('20260925000003_remision_refacciones_pago_descuento', 'columna|remisiones_refacciones.forma_pago'),
  ('20260925000003_remision_refacciones_pago_descuento', 'columna|remisiones_refacciones.descuento_pct'),
  ('20260925000003_remision_refacciones_pago_descuento', 'columna|remision_refaccion_items.descuento_pct'),
  ('20260925000002_vista_refacciones_stock',        'columna|v_almacen_refacciones.stock_bloqueado'),
  ('20260925000002_vista_refacciones_stock',        'columna|v_almacen_refacciones.stock_disponible'),
  ('20260925000001_remision_refacciones_seguimiento', 'columna|remisiones_refacciones.tipo_envio'),
  ('20260925000001_remision_refacciones_seguimiento', 'columna|remisiones_refacciones.direccion_entrega'),
  ('20260925000001_remision_refacciones_seguimiento', 'columna|remisiones_refacciones.pagado'),
  ('20260925000001_remision_refacciones_seguimiento', 'columna|remisiones_refacciones.entregada_at'),
  ('20260925000001_remision_refacciones_seguimiento', 'columna|avisos.remision_refaccion_id'),
  ('20260925000001_remision_refacciones_seguimiento', 'columna|avisos.destinatario_id'),
  ('20260925000001_remision_refacciones_seguimiento', 'funcion|crear_remision_refacciones(uuid,text,text,jsonb,jsonb)'),
  ('20260925000001_remision_refacciones_seguimiento', 'funcion|avisar_faltante_refaccion(uuid,uuid,text)'),
  ('20260925000001_remision_refacciones_seguimiento', 'funcion|actualizar_envio_remision_refaccion(uuid,jsonb)'),
  ('20260925000001_remision_refacciones_seguimiento', 'funcion|registrar_guia_remision_refaccion(uuid,text,text)'),
  ('20260925000001_remision_refacciones_seguimiento', 'funcion|entregar_remision_refaccion(uuid)'),
  ('20260925000001_remision_refacciones_seguimiento', 'funcion|marcar_pago_remision_refaccion(uuid,boolean,text)'),
  ('20260925000001_remision_refacciones_seguimiento', 'restriccion|almacen_refacciones_productos.almacen_refacciones_productos_stock_no_negativo|stock >= 0'),
  ('20260925000001_remision_refacciones_seguimiento', 'restriccion|inventario_colores.inventario_colores_disponible_no_negativo|cantidad_disponible >= 0'),

  ('20260925000005_inventario_trigger_sin_campo_ajeno', 'funcion|impedir_inventario_negativo()'),

  ('20260925170000_security_hardening_criticos', 'columna|profiles.debe_cambiar_password'),
  ('20260925170000_security_hardening_criticos', 'funcion|proteger_campos_privilegiados_profiles()'),
  ('20260925170000_security_hardening_criticos', 'politica|profiles.profiles_update_propio'),
  ('20260925170000_security_hardening_criticos', 'politica|bitacora_eliminaciones.bitacora_elim_select_admin'),
  ('20260925170000_security_hardening_criticos', 'politica|proveedores.proveedores_select|es_finanzas'),
  ('20260925170000_security_hardening_criticos', 'politica|almacen_refacciones_acceso.ref_acceso_escribir|es_admin_global'),

  ('20260925193000_security_hardening_fase2', 'funcion|puede_escribir_inventario(uuid)'),
  ('20260925193000_security_hardening_fase2', 'funcion|puede_leer_inventario(uuid)'),
  ('20260925193000_security_hardening_fase2', 'politica|inventario_chasis.inv_select_operativo'),
  ('20260925193000_security_hardening_fase2', 'politica|compras.leer compras|es_compras'),
  -- cxc_select ya no se revisa aquí: 20261007000002 la redefinió a propósito
  -- (la visibilidad la da el RLS de clientes). Se revisa en ese script.

  ('20260925210000_disable_public_signups', 'funcion|reject_public_signups()'),

  -- Parche suelto, sin fecha en el nombre: columnas de pago de la remisión.
  ('fix_remisiones_columns',                      'columna|remisiones.tipo_pago'),
  ('fix_remisiones_columns',                      'columna|remisiones.color_solicitado'),
  ('fix_remisiones_columns',                      'restriccion|remisiones.remisiones_tipo_pago_check|contra_entrega'),

  -- Módulo de crédito: cartera CxC y bloqueo por vencidos.
  ('20260925190000_modulo_credito_cxc',           'tabla|cuentas_por_cobrar'),
  ('20260925190000_modulo_credito_cxc',           'tabla|cxc_abonos'),
  ('20260925190000_modulo_credito_cxc',           'vista|v_clientes_credito'),
  ('20260925190000_modulo_credito_cxc',           'funcion|cliente_tiene_cxc_vencidas(uuid)'),
  ('20260925190000_modulo_credito_cxc',           'funcion|cxc_vencidas_resumen(uuid)'),
  ('20260925190000_modulo_credito_cxc',           'funcion|cliente_tiene_credito(uuid)'),

  ('20260929000001_historial_conexiones',         'tabla|historial_conexiones'),
  ('20260929000001_historial_conexiones',         'funcion|registrar_conexion()'),
  ('20260929000001_historial_conexiones',         'politica|historial_conexiones.direccion lee historial conexiones|es_area'),

  ('20260929000002_permiso_asignar_remisiones',   'tabla|remisiones_asignacion_acceso'),
  ('20260929000002_permiso_asignar_remisiones',   'funcion|puede_asignar_remisiones(uuid)|remisiones_asignacion_acceso'),
  ('20260929000002_permiso_asignar_remisiones',   'funcion|asignar_motocarro_a_remision(uuid,uuid)|puede_asignar_remisiones'),
  ('20260929000002_permiso_asignar_remisiones',   'funcion|desasignar_motocarro_de_remision(uuid)|puede_asignar_remisiones'),
  ('20260929000002_permiso_asignar_remisiones',   'funcion|capturar_seriales_unidad(uuid,text,text)|puede_asignar_remisiones'),
  ('20260929000002_permiso_asignar_remisiones',   'funcion|crear_motocarro_ya_armado(text,text,text,text,uuid)|puede_asignar_remisiones'),

  ('20260930000001_marcar_entrega_asignacion',    'funcion|marcar_unidad_entregada(uuid,date)|puede_asignar_remisiones'),
  ('20260930000001_marcar_entrega_asignacion',    'funcion|marcar_remision_entregada(uuid)|puede_asignar_remisiones'),

  ('20261001000001_configurar_pedido_atenea',     'columna|remisiones_asignacion_acceso.puede_configurar_pedido'),
  ('20261001000001_configurar_pedido_atenea',     'funcion|puede_configurar_pedido(uuid,uuid)|remisiones_asignacion_acceso'),
  ('20261001000001_configurar_pedido_atenea',     'funcion|configurar_pedido_remision(uuid,jsonb)|remisiones_bitacora'),

  ('20261001000002_atenea_corrige_y_carga_anteriores', 'columna|remisiones_asignacion_acceso.puede_editar_remisiones'),
  ('20261001000002_atenea_corrige_y_carga_anteriores', 'columna|remisiones_asignacion_acceso.puede_cargar_anteriores'),
  ('20261001000002_atenea_corrige_y_carga_anteriores', 'columna|remisiones.es_anterior'),
  ('20261001000002_atenea_corrige_y_carga_anteriores', 'funcion|puede_editar_todas_remisiones(uuid)|puede_editar_remisiones'),
  ('20261001000002_atenea_corrige_y_carga_anteriores', 'funcion|puede_cargar_remisiones_anteriores(uuid)|puede_cargar_anteriores'),
  ('20261001000002_atenea_corrige_y_carga_anteriores', 'funcion|puede_editar_remision(uuid,uuid)|puede_editar_todas_remisiones'),
  ('20261001000002_atenea_corrige_y_carga_anteriores', 'funcion|puede_capturar_remision(uuid,uuid)|puede_cargar_remisiones_anteriores'),

  -- Compras e inventario de refacciones (sesión con Compras del 30-sep-2026).
  ('20261006000001_compras_inventario_base',       'tabla|inventario_almacenes'),
  ('20261006000001_compras_inventario_base',       'tabla|inventario_motivos_ajuste'),
  ('20261006000001_compras_inventario_base',       'tabla|bitacora_compras_inventario'),
  ('20261006000001_compras_inventario_base',       'columna|almacen_refacciones_movimientos.fecha_efectiva'),
  ('20261006000001_compras_inventario_base',       'columna|almacen_refacciones_productos.unidad_venta'),
  ('20261006000001_compras_inventario_base',       'columna|v_almacen_refacciones.piezas_caja_cerrada'),
  ('20261006000001_compras_inventario_base',       'columna|clientes.es_prueba'),
  ('20261006000001_compras_inventario_base',       'funcion|puede_compras_inventario(uuid)'),
  ('20261006000001_compras_inventario_base',       'funcion|es_usuario_prueba(uuid)'),
  ('20261006000002_compras_ajustes_kardex',        'tabla|compras_refacciones'),
  ('20261006000002_compras_ajustes_kardex',        'tabla|ajustes_inventario'),
  ('20261006000002_compras_ajustes_kardex',        'tabla|recepciones_refacciones'),
  ('20261006000002_compras_ajustes_kardex',        'vista|v_compra_refacciones_contenedor'),
  ('20261006000002_compras_ajustes_kardex',        'funcion|aplicar_ajuste_rapido(text,date,text,text,jsonb,text,text)'),
  ('20261006000002_compras_ajustes_kardex',        'funcion|kardex_refaccion(uuid,date,date)'),
  ('20261006000002_compras_ajustes_kardex',        'funcion|ventas_mensuales_refacciones(date,date,boolean)'),
  ('20261006000002_compras_ajustes_kardex',        'funcion|unificar_unidades_refacciones(uuid,uuid[],text)'),
  ('20261006000003_cobranza_refacciones',          'tabla|cobranza_pagos'),
  ('20261006000003_cobranza_refacciones',          'tabla|cobranza_aplicaciones'),
  ('20261006000003_cobranza_refacciones',          'tabla|cobranza_saldos_favor'),
  ('20261006000003_cobranza_refacciones',          'tabla|remision_refaccion_ordenes'),
  ('20261006000003_cobranza_refacciones',          'vista|v_cobranza_remisiones'),
  ('20261006000003_cobranza_refacciones',          'funcion|corregir_remision_refaccion(uuid,jsonb,text)'),
  ('20261006000003_cobranza_refacciones',          'funcion|marcar_pago_remision_con_evidencia(uuid,boolean,text,text,boolean)'),
  ('20261006000004_datos_prueba_compras',          'funcion|sembrar_datos_prueba_compras()'),
  ('20261006000004_datos_prueba_compras',          'funcion|reiniciar_datos_prueba_compras(text)'),
  ('20261006000004_datos_prueba_compras',          'funcion|remision_refaccion_marca_prueba()|P-%'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'tabla|inventario_reglas_modo_prueba'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'tabla|abc_leyenda_combinaciones'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'columna|inventario_motivos_ajuste.es_prueba'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'columna|avisos.es_prueba'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'columna|inventario_almacenes.equivalente_ecount'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'funcion|guardar_motivo_ajuste(text,text,boolean,boolean,integer)'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'funcion|candado_modo_prueba()'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'funcion|compras_parametros_guardia()'),
  ('20261007000001_vendedor_solo_su_informacion', 'funcion|ve_todo_comercial(uuid)|supervisa_area'),
  ('20261007000002_vendedor_clientes_credito', 'politica|clientes.leer clientes|ve_todo_comercial'),
  ('20261007000002_vendedor_clientes_credito', 'politica|cuentas_por_cobrar.cxc_select|clientes'),
  ('20261007000003_vendedor_crm_asignacion', 'politica|crm_actividades.crm_act_select|ve_todo_comercial'),
  ('20261007000001_modulo_tareas',                'tabla|tareas'),
  ('20261007000001_modulo_tareas',                'funcion|usuarios_asignables()|area_nivel_de'),
  ('20261007000001_modulo_tareas',                'funcion|es_admin_de_area(user_area,uuid)|area_nivel_de'),
  ('20261007000001_modulo_tareas',                'politica|tareas.ver tareas|es_admin_de_area'),
  ('20261007000001_notificaciones_menciones', 'tabla|notificaciones'),
  ('20261007000001_notificaciones_menciones', 'columna|notificaciones.usuario_destino'),
  ('20261007000004_modo_prueba_tablas_nuevas', 'trigger|tareas.zzz_candado_modo_prueba'),
  ('20261007000004_modo_prueba_tablas_nuevas', 'trigger|notificaciones.zzz_candado_modo_prueba'),
  ('20261008000001_compras_supervisa_remisiones', 'funcion|compras_supervisa_remisiones(uuid)'),
  ('20261008000001_compras_supervisa_remisiones', 'funcion|puede_editar_remision(uuid,uuid)|compras_supervisa_remisiones'),
  ('20261008000001_compras_supervisa_remisiones', 'funcion|puede_capturar_remision(uuid,uuid)|compras_supervisa_remisiones'),
  ('20261008000001_compras_supervisa_remisiones', 'politica|remisiones.compras supervisa remisiones lectura'),
  ('20261008000001_compras_supervisa_remisiones', 'politica|remisiones.compras supervisa remisiones captura'),
  ('20261008000001_compras_supervisa_remisiones', 'politica|motocarros.compras supervisa motocarros de remisiones'),
  ('20261008000002_compras_supervisa_remisiones_refacciones', 'funcion|puede_capturar_refacciones(uuid)|compras_supervisa_remisiones'),
  ('20261008000002_compras_supervisa_remisiones_refacciones', 'funcion|actualizar_envio_remision_refaccion(uuid,jsonb)|compras_supervisa_remisiones'),
  ('20261008000002_compras_supervisa_remisiones_refacciones', 'funcion|cancelar_linea_refaccion(uuid,text)|compras_supervisa_remisiones'),
  ('20261008000002_compras_supervisa_remisiones_refacciones', 'funcion|cancelar_remision_refacciones(uuid,text)|compras_supervisa_remisiones')
), superado(script, por) AS (VALUES
  -- Scripts que otro posterior reemplazó por completo (les tiró la función y
  -- la volvió a crear con otra firma). No hay que correrlos y revisarlos
  -- daría un falso APLICADO: lo que se busca es lo que dejó el script nuevo.
  ('20260819000008_importar_vins_inventario',     '20260821000001_unidad_chasis_motor'),
  ('20260819000012_importar_motores_inventario',  '20260821000001_unidad_chasis_motor')
), revisado AS (
  SELECT e.script, e.objeto,
         split_part(e.objeto, '|', 1) AS tipo,
         split_part(e.objeto, '|', 2) AS nombre,
         -- Tercer campo opcional. Para `politica`, `funcion`, `indice` y
         -- `restriccion` es el texto que la definición tiene que contener:
         -- hace falta porque varios scripts REDEFINEN el mismo objeto con el
         -- mismo nombre, y que exista no dice cuál versión quedó. Para
         -- `sin_privilegio` es el rol que NO debe poder ejecutar la función.
         NULLIF(split_part(e.objeto, '|', 3), '') AS detalle
    FROM esperado e
), resuelto AS (
  SELECT r.script, r.objeto, r.tipo, r.nombre,
    CASE r.tipo
      WHEN 'tabla' THEN
        to_regclass('public.' || quote_ident(r.nombre)) IS NOT NULL
      WHEN 'vista' THEN
        to_regclass('public.' || quote_ident(r.nombre)) IS NOT NULL
      WHEN 'columna' THEN
        EXISTS (SELECT 1 FROM information_schema.columns c
                 WHERE c.table_schema = 'public'
                   AND c.table_name  = split_part(r.nombre, '.', 1)
                   AND c.column_name = split_part(r.nombre, '.', 2)
                   -- Con `detalle`, el DEFAULT de la columna tiene que
                   -- contener ese texto: sirve para los scripts que sólo
                   -- cambian un default y no dejan objeto nuevo.
                   AND (r.detalle IS NULL
                        OR COALESCE(c.column_default,'') LIKE '%' || r.detalle || '%'))
      WHEN 'funcion' THEN
        to_regprocedure('public.' || r.nombre) IS NOT NULL
        -- Con `detalle`, además de existir, el cuerpo tiene que contener ese
        -- texto: varios scripts REDEFINEN la misma función con la misma firma
        -- y que exista no dice cuál de las dos versiones quedó.
        AND (r.detalle IS NULL OR EXISTS (
              SELECT 1 FROM pg_proc p
               WHERE p.oid = to_regprocedure('public.' || r.nombre)
                 AND p.prosrc LIKE '%' || r.detalle || '%'))
      WHEN 'sin_privilegio' THEN
        -- Al revés que los demás: el script se reconoce por lo que QUITÓ.
        to_regprocedure('public.' || r.nombre) IS NOT NULL
        AND NOT has_function_privilege(
              r.detalle, to_regprocedure('public.' || r.nombre), 'EXECUTE')
      WHEN 'tipo' THEN
        EXISTS (SELECT 1 FROM pg_enum e
                  JOIN pg_type ty ON ty.oid = e.enumtypid
                  JOIN pg_namespace n ON n.oid = ty.typnamespace
                 WHERE n.nspname = 'public'
                   AND ty.typname  = split_part(r.nombre, '.', 1)
                   AND e.enumlabel = split_part(r.nombre, '.', 2))
      WHEN 'indice' THEN
        EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public'
                   AND indexname  = r.nombre
                   AND (r.detalle IS NULL OR indexdef LIKE '%' || r.detalle || '%'))
      WHEN 'restriccion' THEN
        EXISTS (SELECT 1 FROM pg_constraint co
                  JOIN pg_class cl ON cl.oid = co.conrelid
                  JOIN pg_namespace n ON n.oid = cl.relnamespace
                 WHERE n.nspname = 'public'
                   AND cl.relname = split_part(r.nombre, '.', 1)
                   AND co.conname = split_part(r.nombre, '.', 2)
                   AND (r.detalle IS NULL
                        OR pg_get_constraintdef(co.oid) LIKE '%' || r.detalle || '%'))
      WHEN 'trigger' THEN
        EXISTS (SELECT 1 FROM pg_trigger t
                  JOIN pg_class c ON c.oid = t.tgrelid
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public'
                   AND c.relname = split_part(r.nombre, '.', 1)
                   AND t.tgname  = split_part(r.nombre, '.', 2)
                   AND NOT t.tgisinternal)
      WHEN 'politica' THEN
        -- `storage.objects.nombre` apunta al esquema storage; sin prefijo, public.
        EXISTS (SELECT 1 FROM pg_policies p
                 WHERE p.schemaname = CASE WHEN r.nombre LIKE 'storage.%' THEN 'storage' ELSE 'public' END
                   AND p.tablename  = split_part(regexp_replace(r.nombre, '^storage\.', ''), '.', 1)
                   AND p.policyname = split_part(regexp_replace(r.nombre, '^storage\.', ''), '.', 2)
                   AND (r.detalle IS NULL
                        OR COALESCE(p.qual,'') || ' ' || COALESCE(p.with_check,'') LIKE '%' || r.detalle || '%'))
      WHEN 'secuencia' THEN
        to_regclass('public.' || quote_ident(r.nombre)) IS NOT NULL
    END AS existe
  FROM revisado r
)
SELECT * FROM (
  SELECT script,
         CASE
           WHEN bool_and(existe)     THEN 'APLICADO'
           WHEN bool_or(existe)      THEN 'PARCIAL  ←— vuelve a correr el archivo completo'
           ELSE                           'FALTA    ←— corre supabase/migrations/' || script || '.sql'
         END AS estado,
         count(*) FILTER (WHERE existe)     AS objetos_ok,
         count(*)                           AS objetos_esperados,
         string_agg(nombre, ', ') FILTER (WHERE NOT existe) AS lo_que_falta
    FROM resuelto
   GROUP BY script
  UNION ALL
  SELECT s.script,
         'SUPERADO ←— lo reemplazó ' || s.por,
         0::bigint, 0::bigint, NULL::text
    FROM superado s
) todo
 ORDER BY script;
