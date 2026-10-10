import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = process.cwd();
const leer = (f: string) => readFileSync(join(root, "supabase/functions", f), "utf8");
const reset = leer("admin-reset-user-password/index.ts");
const crear = leer("admin-create-user/index.ts");
const compartido = leer("_shared/acceso.ts");
const cambio = leer("complete-password-change/index.ts");

describe("contraseña temporal: siempre por correo (Edge Functions)", () => {
  it("el restablecimiento obliga a cambiar la contraseña generada", () => {
    expect(reset).toContain("password: temporaryPassword");
    expect(reset).toContain("app_metadata:");
    expect(reset).toContain("must_change_password: true");
    expect(reset).toContain("debe_cambiar_password: true");
  });

  it("restringe el restablecimiento a administradores y a su área", () => {
    expect(reset).toContain('callerNivel !== "admin"');
    expect(reset).toContain("targetRole?.area !== callerArea");
  });

  it("genera la contraseña en el servidor y NUNCA la devuelve al navegador", () => {
    expect(reset).toContain("generarPassword()");
    expect(reset).not.toContain("temporary_password");
    expect(reset).toContain("correo: { enviado: true }");
    expect(compartido).toContain("crypto.getRandomValues");
  });

  it("manda el correo ANTES de cambiar la contraseña (si no sale, no se toca la cuenta)", () => {
    expect(reset.indexOf("enviarAcceso(")).toBeGreaterThan(-1);
    expect(reset.indexOf("enviarAcceso(")).toBeLessThan(reset.indexOf("updateUserById"));
  });

  it("el alta tampoco recibe contraseña del cliente, ni la devuelve, y autoriza el correo antes de crear", () => {
    expect(crear).toContain("generarPassword()");
    expect(crear).not.toMatch(/\bpassword\b[^\n]*body/);
    expect(crear).toContain("correo: { enviado: true }");
    expect(crear.indexOf("enviarAcceso(")).toBeLessThan(crear.indexOf("auth.admin.createUser"));
    expect(crear.indexOf("autorizarAlta(")).toBeLessThan(crear.indexOf("auth.admin.createUser"));
  });
});

describe("cambio de contraseña fuerza re-login (Edge Function)", () => {
  it("la Edge Function avisa reauth_required", () => {
    expect(cambio).toContain("reauth_required: true");
    expect(cambio).toContain("revoca refresh tokens");
  });
});
