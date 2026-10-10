import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * Pruebas de base de Compras, Inventario y Cobranza.
 *
 * La regla vive en Postgres (candados, ajustes retroactivos, cobranza), así
 * que se prueba contra un Postgres de verdad: `scripts/db-local/probar_compras.sh`
 * crea una base vacía, aplica TODAS las migraciones y corre
 * `scripts/db-local/pruebas_compras.sql`. Para correrlas aquí:
 *
 *   KIT_PG_PRUEBAS=1 PGHOST=/var/lib/postgresql PGPORT=5433 npx vitest run compras-inventario-db
 *
 * Sin `KIT_PG_PRUEBAS` sólo se revisa que el guion de pruebas cubra cada
 * criterio de aceptación (la máquina de CI no trae Postgres).
 */

const RAIZ = process.cwd();
const guion = readFileSync(join(RAIZ, "scripts/db-local/pruebas_compras.sql"), "utf8");

describe("pruebas de base: cubren los criterios de aceptación", () => {
  const criterios = [
    "Candado en ceros",
    "Candado de pertenencia",
    "Ajuste retroactivo",
    "Remisión mixta dorada + azul",
    "Pago a varias remisiones, parcial, en exceso (saldo a favor) y reversión",
    "Corregir remisión: recalcula monto, inventario y saldo a favor",
    "Compra confirmada vs. recepción con diferencia",
    "Seguridad por filas y por rol",
    "Reportes excluyen la prueba por defecto",
    "Siembra idempotente",
    "Saldos a favor: sólo Compras (y el administrador) los aplica; Finanzas no",
    "Motivos de ajuste: catálogo real, editable, un motivo usado no se borra",
    "Las cuentas de prueba no ven ni tocan datos reales (todas las tablas y vistas)",
  ];
  for (const c of criterios) {
    it(c, () => expect(guion).toContain(c));
  }

  it("las migraciones nuevas están en orden y son aditivas (no reescriben funciones del flujo de motocarros ni de gastos)", () => {
    const nuevas = readdirSync(join(RAIZ, "supabase/migrations")).filter(f => /^2026100[67]/.test(f));
    expect(nuevas.length).toBeGreaterThanOrEqual(5);
    const prohibidas = [
      /FUNCTION public\.(asignar_chasis_remision|configurar_unidad|recibir_contenedor|importar_packing_list|marcar_unidad_entregada)\(/,
      /(ALTER|DROP)\s+TABLE[^;]*public\.(pagos|movimientos_financieros|motocarros|inventario_chasis|inventario_motor|contenedor_partes|inventario_partes)\b/i,
    ];
    for (const f of nuevas) {
      const sql = readFileSync(join(RAIZ, "supabase/migrations", f), "utf8");
      for (const re of prohibidas) expect(sql, `${f} toca ${re}`).not.toMatch(re);
    }
  });
});

describe("decisiones de Polo (2026-10-07) quedan en las migraciones", () => {
  const leer = (f: string) => readFileSync(join(RAIZ, "supabase/migrations", f), "utf8");
  const base = leer("20261006000001_compras_inventario_base.sql");
  const decisiones = leer("20261007000001_compras_decisiones_y_modo_prueba.sql");
  const semilla = leer("20261006000004_datos_prueba_compras.sql");

  it("saldo a favor: por defecto sólo Compras, editable sólo por un administrador", () => {
    expect(base).toContain(`('saldo_favor_aplican', '["compras"]'`);
    expect(decisiones).toMatch(/SET valor = '\["compras"\]'::jsonb/);
    expect(decisiones).toMatch(/'saldo_favor_aplican', 'entrega_exige_pago', 'cargador_saldos_habilitado'\)\s+AND NOT public\.es_admin_compras/);
  });

  it("los seis motivos aprobados se siembran como catálogo real (no en la semilla de prueba), «Mal conteo» primero", () => {
    for (const m of ["Mal conteo", "Auditoría o conteo físico", "Incidencia de recepción de contenedor", "Merma o daño", "Corrección de captura", "Otro"]) {
      expect(base).toContain(`'${m}'`);
      expect(decisiones).toContain(`'${m}'`);
    }
    expect(decisiones).toMatch(/\('mal_conteo',\s+'Mal conteo', false, 10\)/);
    expect(semilla).not.toMatch(/INSERT INTO public\.inventario_motivos_ajuste/);
  });

  it("la Línea dorada no afirma su equivalencia con Ecount (no está confirmada)", () => {
    expect(base).not.toMatch(/'linea_dorada',[^\n]*Ecount/);
    expect(decisiones).toContain("equivalente_ecount");
  });

  it("la exigencia de pago para entregar sigue apagada y el cargador de saldos también", () => {
    expect(base).toContain("('entrega_exige_pago', 'false'");
    expect(leer("20261006000003_cobranza_refacciones.sql")).toContain("('cargador_saldos_habilitado', 'false'");
    expect(decisiones).not.toMatch(/SET valor = 'true'[^;]*entrega_exige_pago/);
  });

  it("toda tabla queda con candado de modo prueba; lo que no tiene regla queda cerrado", () => {
    expect(decisiones).toContain("coalesce(r.lectura, 'nada')");
    expect(decisiones).toContain("coalesce(r.escritura, 'nada')");
    expect(decisiones).toContain("Tablas sin candado de modo prueba");
  });
});

describe.runIf(process.env.KIT_PG_PRUEBAS === "1")("pruebas de base contra Postgres local", () => {
  it("base vacía → migraciones → todas las pruebas pasan", () => {
    const salida = execFileSync("bash", [join(RAIZ, "scripts/db-local/probar_compras.sh")], {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 300_000,
    });
    expect(salida).toContain("Migraciones con falla: 0");
    expect(salida).toContain("TODAS LAS PRUEBAS DE BASE PASARON");
  }, 300_000);

  it("sobre un esquema existente con datos: sin pérdida", () => {
    const salida = execFileSync("bash", [join(RAIZ, "scripts/db-local/probar_sobre_existente.sh")], {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 300_000,
    });
    // Si algún registro cambió o se perdió, el script termina con error (RAISE EXCEPTION).
    expect(salida).toMatch(/ok x2\s+20261007000001/);
  }, 300_000);

  it("una base con la versión anterior de las migraciones se actualiza limpia", () => {
    const salida = execFileSync("bash", [join(RAIZ, "scripts/db-local/probar_actualizacion.sh")], {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 300_000,
    });
    expect(salida).toMatch(/actual\s+20261007000001/);
  }, 300_000);
});
