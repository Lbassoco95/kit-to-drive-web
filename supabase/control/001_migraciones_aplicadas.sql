-- ============================================================================
-- Tabla de migraciones aplicadas
--
-- Cierra el hueco que describe docs/no-romper-produccion.md: hasta ahora un
-- script que no se corría (o se revertía) no dejaba rastro. Desde aquí, cada
-- script que se pega en el SQL editor se registra con una fila.
--
-- Es idempotente: se puede correr más de una vez. Sólo agrega una tabla nueva
-- y filas; no toca ninguna tabla, función ni política existente.
--
-- Estado inicial: verificado con supabase/diagnostico_esquema.sql el
-- 2026-10-09 contra el proyecto kit-to-drive. Todo APLICADO, salvo los dos
-- scripts SUPERADO (los reemplazó 20260821000001).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.migraciones_aplicadas (
  script       text PRIMARY KEY,
  estado       text NOT NULL DEFAULT 'aplicado'
               CHECK (estado IN ('aplicado', 'superado')),
  aplicada_at  timestamptz NOT NULL DEFAULT now(),
  notas        text
);

COMMENT ON TABLE public.migraciones_aplicadas IS
  'Registro manual de los scripts de supabase/migrations/ que ya corrieron en esta base.';

-- Sin políticas: la leen y escriben el SQL editor y el service role, no la app.
ALTER TABLE public.migraciones_aplicadas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.migraciones_aplicadas FROM anon, authenticated;

INSERT INTO public.migraciones_aplicadas (script, estado, notas) VALUES
  ('20260503015306_f99960c9-701f-452a-aab9-4d1216cb57ae', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260503015323_a96fe55f-42c2-460e-b39d-70ee25c5777b', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260503023936_e271aa15-dd34-4c36-970b-6b30a5eaf2a4', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260503190820_5b97bddd-db06-4817-abf2-cc96562f8fa0', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260503192247_c54db563-2e9e-43a1-ad2b-757bd198e7ac', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260503192333_cb78101f-581a-4ca7-ba6c-2917c43edb25', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260503193601_1f2d647e-2717-44a2-a009-d1616587e0ac', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260629000001_reportes_comentarios', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260629000002_profiles_email', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260629000003_remision_items', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260629000004_tipo_remision_v2', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260629000005_remision_items_tipo_servicio', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260713000001_finanzas_module', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260714000001_fix_asignar_chasis_modelo', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260714000002_crm_ventas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260717000003_clientes_expediente_digital', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260717000004_crm_fixes', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260717000007_crm_actividades_estatus', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000001_parts_inventory', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000004_inventario_chasis', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000005_inventario_motor', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000006_inventario_partes', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000007_inventario_colores', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000008_importar_vins_inventario', 'superado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000009_importar_packing_list', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000010_bitacora_eliminaciones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000011_clientes_crm', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260819000012_importar_motores_inventario', 'superado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260821000001_unidad_chasis_motor', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260822000001_configuracion_manual_unidades', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260823000001_incidencias_chasis_colores_cierre', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260823000002_capturar_seriales_unidad', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260823000003_color_efectivo_capacidad', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260823000004_finanzas_ingresos_egresos', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260823000005_usuarios_niveles_areas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260824000001_remisiones_visibles_equipo_comercial', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260824000002_comercial_lee_toda_la_bandeja', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260824000003_usuario_activo_se_aplica', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260825000001_comercial_escalera_de_permisos', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260826000002_folio_reutilizable_canceladas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260826000003_asignacion_manual_remisiones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260827000001_folio_interno_clientes_nuevos', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260828000001_motocarro_ya_armado', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260902000001_operador_edita_remisiones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260902223156_fix_remisiones_docs_lectura_finanzas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260903000001_avisos_entre_areas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260904000001_solicitudes_a_fabrica', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260907000001_ya_armado_cilindraje_color', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260908000001_ya_armado_no_se_atora_por_capacidad', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260908000002_tope_unidades_ya_armadas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260908000003_crm_tipos_actividad', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260922000001_almacen_refacciones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260922000002_sincronizar_compat_refacciones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260922000003_area_compras_enum', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260922000004_area_compras', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260923000001_remisiones_refacciones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925000001_remision_refacciones_seguimiento', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925000002_vista_refacciones_stock', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925000003_remision_refacciones_pago_descuento', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925000004_remision_refacciones_canceladas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925000005_inventario_trigger_sin_campo_ajeno', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925170000_security_hardening_criticos', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925190000_modulo_credito_cxc', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925193000_security_hardening_fase2', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260925210000_disable_public_signups', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260929000001_historial_conexiones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260929000002_permiso_asignar_remisiones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20260930000001_marcar_entrega_asignacion', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261001000001_configurar_pedido_atenea', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261001000002_atenea_corrige_y_carga_anteriores', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261006000001_compras_inventario_base', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261006000002_compras_ajustes_kardex', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261006000003_cobranza_refacciones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261006000004_datos_prueba_compras', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261007000001_compras_decisiones_y_modo_prueba', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261007000001_modulo_tareas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261007000001_notificaciones_menciones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261007000001_vendedor_solo_su_informacion', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261007000002_vendedor_clientes_credito', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261007000003_vendedor_crm_asignacion', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261007000004_modo_prueba_tablas_nuevas', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261008000001_compras_supervisa_remisiones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('20261008000002_compras_supervisa_remisiones_refacciones', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09'),
  ('fix_remisiones_columns', 'aplicado', 'verificada con diagnostico_esquema.sql 2026-10-09')
ON CONFLICT (script) DO NOTHING;

-- Para registrar un script nuevo después de correrlo:
--   INSERT INTO public.migraciones_aplicadas (script) VALUES ('AAAAMMDDNNNNNN_nombre');
