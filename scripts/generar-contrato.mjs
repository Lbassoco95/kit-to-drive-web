// Genera contrato/funciones.json: las funciones de `public` que las migraciones crean.
// El front (kit-to-drive) copia este archivo para comprobar que toda RPC que llama existe,
// sin necesitar una copia de las migraciones.   Uso: npm run contrato
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIR = join(RAIZ, "supabase", "migrations");

export function funcionesDeMigraciones() {
  const nombres = new Set();
  for (const f of readdirSync(DIR).filter((x) => x.endsWith(".sql"))) {
    const sql = readFileSync(join(DIR, f), "utf8");
    for (const m of sql.matchAll(/FUNCTION\s+public\.([a-z_0-9]+)\s*\(/gi)) nombres.add(m[1]);
  }
  return [...nombres].sort();
}

export function contrato() {
  return { generado_de: "supabase/migrations", funciones: funcionesDeMigraciones() };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync(join(RAIZ, "contrato", "funciones.json"), JSON.stringify(contrato(), null, 2) + "\n");
  console.log(`contrato/funciones.json: ${contrato().funciones.length} funciones`);
}
