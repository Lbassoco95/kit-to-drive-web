-- Compras e Inventario: Compras resurte para seguir vendiendo, así que ve el
-- inventario completo. Ya leía y escribía chasis, motores, partes y colores
-- (puede_escribir_inventario incluye el área Compras); faltaba leer los
-- motocarros. Sólo lectura: no cambia el flujo de chasis y motor.
DROP POLICY IF EXISTS "compras lee motocarros" ON public.motocarros;
CREATE POLICY "compras lee motocarros" ON public.motocarros
  FOR SELECT TO authenticated
  USING (public.es_compras(auth.uid()));

NOTIFY pgrst, 'reload schema';
