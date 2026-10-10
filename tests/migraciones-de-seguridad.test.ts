import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const mig = (f: string) => readFileSync(join(process.cwd(), "supabase/migrations", f), "utf8");

describe("historial de conexiones (migración)", () => {
  const migration = mig("20260929000001_historial_conexiones.sql");

  it("registra con la sesión autenticada y no duplica", () => {
    expect(migration).toContain("auth.uid()");
    expect(migration).toContain("ON CONFLICT (usuario_id, sesion_id) DO NOTHING");
  });

  it("protege el historial para que solo Dirección pueda consultarlo", () => {
    expect(migration).toContain("public.es_area(auth.uid(), 'direccion'::public.user_area)");
    expect(migration).not.toMatch(/FOR SELECT TO authenticated\s+USING \(true\)/);
    expect(migration).toContain("REVOKE ALL ON FUNCTION public.registrar_conexion() FROM PUBLIC, anon");
  });
});

describe("vendedor solo ve su información (migración)", () => {
  const sql = mig("20261007000001_vendedor_solo_su_informacion.sql");

  it("ya no abre clientes/remisiones/items/cxc a todo el comercial", () => {
    expect(sql).not.toMatch(/remision_items_select[\s\S]{0,120}USING \(true\)/);
    expect(sql).not.toMatch(/cxc_select[\s\S]{0,120}USING \(true\)/);
    const rol = sql.split('"leer remisiones por rol"')[2]?.split(");")[0] ?? "";
    expect(rol).not.toContain("'ventas'");
    expect(sql).toContain("vendedor_id = auth.uid()");
    expect(sql).toContain("ve_todo_comercial");
  });
});

describe("cierre de seguridad (2026-10-09/10)", () => {
  it("ninguna función de public queda abierta a anon y las nuevas no nacen abiertas", () => {
    const s = mig("20261009000002_cerrar_puente_heredado_y_funciones_anon.sql");
    expect(s).toContain("REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon");
    expect(s).toContain("ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon");
  });

  it("el rol de Auth conserva permiso sobre el trigger que crea cuentas", () => {
    expect(mig("20261010000001_arreglo_permiso_trigger_auth.sql")).toContain(
      "GRANT EXECUTE ON FUNCTION public.handle_new_user() TO supabase_auth_admin",
    );
  });

  it("las altas autorizadas no son visibles para anon ni authenticated", () => {
    const s = mig("20261010000002_altas_autorizadas.sql");
    expect(s).toContain("ENABLE ROW LEVEL SECURITY");
    expect(s).toContain("REVOKE ALL ON public.altas_autorizadas FROM PUBLIC, anon, authenticated");
  });
});
