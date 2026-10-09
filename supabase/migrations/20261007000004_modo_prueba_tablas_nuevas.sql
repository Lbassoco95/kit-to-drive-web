-- Vuelve a aplicar el candado de MODO PRUEBA (migración
-- 20261007000001_compras_decisiones_y_modo_prueba) a las tablas creadas después
-- de ella, por ejemplo tareas y notificaciones. Sin regla en
-- inventario_reglas_modo_prueba, una tabla queda cerrada para las cuentas de prueba.
-- Es idempotente: donde el candado ya existe, sólo lo recrea igual.
-- Correr de nuevo cada vez que se agregue una tabla al esquema public.
SELECT public.aplicar_reglas_modo_prueba();
NOTIFY pgrst, 'reload schema';
