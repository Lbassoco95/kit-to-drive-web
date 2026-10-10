import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * Que una configuración nueva no rompa lo que ya estaba.
 * ───────────────────────────────────────────────────────────────────────────
 * Este proyecto no tiene tabla de migraciones: los scripts de
 * `supabase/migrations/` se pegan A MANO en el SQL editor de Supabase. Nadie
 * sabe cuáles corrieron, y cuando uno se queda sin aplicar la app no falla al
 * compilar: falla semanas después, en una pantalla cualquiera, con un
 * «column ... does not exist» que el usuario lee como «se perdió la
 * información».
 *
   * `supabase/diagnostico_esquema.sql` responde eso: por cada script busca los
 * objetos que debió dejar. Pero sólo ve los scripts que tiene registrados —
 * un archivo sin registrar es un hueco invisible. Así pasó con
 * 20260827000001: la lista de Clientes salió vacía en producción porque le
 * faltaba `clientes.folio_interno`, y el diagnóstico no lo señalaba.
 *
 * Estas pruebas cierran ese boquete: el diagnóstico y la carpeta de
 * migraciones tienen que cuadrar exactamente, en las dos direcciones.
 */

const RAIZ = process.cwd();
const DIR_MIGRACIONES = join(RAIZ, "supabase", "migrations");
const DIAGNOSTICO = join(RAIZ, "supabase", "diagnostico_esquema.sql");

const diagnostico = readFileSync(DIAGNOSTICO, "utf8");

/** Los scripts del disco, sin la extensión (así se registran). */
const archivos = readdirSync(DIR_MIGRACIONES)
  .filter(f => f.endsWith(".sql"))
  .map(f => f.replace(/\.sql$/, ""))
  .sort();

/**
 * Los scripts registrados en el diagnóstico. Cada renglón de `esperado` y de
 * `superado` empieza con `('<script>',`.
 */
const registrados = new Set(
  Array.from(diagnostico.matchAll(/^\s*\('([^']+)',/gm), m => m[1]),
);

describe("inventario de migraciones", () => {
  it("hay migraciones y hay diagnóstico", () => {
    expect(archivos.length).toBeGreaterThan(10);
    expect(registrados.size).toBeGreaterThan(10);
  });

  it("cada script de supabase/migrations/ está registrado en el diagnóstico", () => {
    const sinRegistrar = archivos.filter(a => !registrados.has(a));
    expect(
      sinRegistrar,
      "Estos scripts no los ve supabase/diagnostico_esquema.sql, así que nadie " +
      "puede saber si corrieron en producción. Agrégalos a `esperado` con un " +
      "objeto que el script deje (una tabla, columna, función, política…), o a " +
      "`superado` si otro script posterior ya lo reemplazó:\n" +
      sinRegistrar.map(s => `  · ${s}`).join("\n"),
    ).toEqual([]);
  });

  it("el diagnóstico no revisa scripts que ya no existen", () => {
    const enElAire = [...registrados].filter(r => !archivos.includes(r));
    expect(
      enElAire,
      "El diagnóstico busca objetos de scripts que no están en " +
      "supabase/migrations/. Un registro viejo reporta FALTA para siempre y " +
      "quema la confianza en el diagnóstico:\n" +
      enElAire.map(s => `  · ${s}`).join("\n"),
    ).toEqual([]);
  });
});
