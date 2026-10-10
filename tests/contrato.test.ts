import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
// @ts-expect-error módulo .mjs sin tipos
import { contrato } from "../scripts/generar-contrato.mjs";

describe("contrato con el front", () => {
  it("contrato/funciones.json está al día (si falla: npm run contrato y copia el archivo al front)", () => {
    const guardado = JSON.parse(readFileSync(join(process.cwd(), "contrato", "funciones.json"), "utf8"));
    expect(guardado).toEqual(contrato());
  });
});
