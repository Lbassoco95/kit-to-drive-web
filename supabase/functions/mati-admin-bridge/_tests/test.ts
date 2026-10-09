import { handler } from "./server.ts";
import "../index.ts";
const base = "https://x.supabase.co/functions/v1/mati-admin-bridge";
const S = "a".repeat(64);
const call = async (path: string, init: RequestInit = {}) => {
  const r = await handler(new Request(base + path, init));
  return [r.status, await r.json().catch(() => null), r.headers.get("access-control-allow-origin")] as const;
};
const eq = (name: string, got: unknown, want: unknown) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(ok ? "OK  " : "FAIL", name, ok ? "" : `got=${JSON.stringify(got)} want=${JSON.stringify(want)}`);
  if (!ok) Deno.exitCode = 1;
};
Deno.env.set("SUPABASE_URL", "https://x.supabase.co");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "k");
// sin secreto configurado
eq("503 sin secreto", (await call("/health"))[0], 503);
Deno.env.set("MATI_ADMIN_BRIDGE_SECRET", S);
eq("401 sin header", (await call("/health"))[0], 401);
eq("401 secreto malo", (await call("/health", { headers: { Authorization: "Bearer " + "b".repeat(64) } }))[0], 401);
eq("401 'Bearer ' vacío", (await call("/health", { headers: { Authorization: "Bearer " } }))[0], 401);
eq("401 prefijo del secreto", (await call("/health", { headers: { Authorization: "Bearer " + S.slice(0, 63) } }))[0], 401);
eq("200 bearer", (await call("/health", { headers: { Authorization: "Bearer " + S } }))[0], 200);
eq("200 x-mati-bridge-secret", (await call("/health", { headers: { "x-mati-bridge-secret": S } }))[0], 200);
const h = { Authorization: "Bearer " + S };
const meta = await call("/meta", { headers: h });
eq("meta incluye compras", (meta[1] as any).areas.includes("compras"), true);
eq("sin CORS en respuesta", meta[2], null);
eq("OPTIONS → 405", (await call("/health", { method: "OPTIONS" }))[0], 405);
eq("ruta inexistente 404", (await call("/nada", { headers: h }))[0], 404);
eq("uuid inválido 400", (await call("/users/123", { headers: h }))[0], 400);
eq("ticket uuid inválido 400", (await call("/tickets/abc", { headers: h }))[0], 400);
eq("módulo clave inválida 400", (await call("/modules/a-b", { method: "PUT", headers: h, body: "{}" }))[0], 400);
eq("json inválido 400", (await call("/users", { method: "POST", headers: h, body: "{no" }))[0], 400);
eq("body arreglo 400", (await call("/users", { method: "POST", headers: h, body: "[]" }))[0], 400);
eq("body enorme 413", (await call("/users", { method: "POST", headers: h, body: JSON.stringify({ a: "x".repeat(70000) }) }))[0], 413);
eq("alta sin campos 400", (await call("/users", { method: "POST", headers: h, body: "{}" }))[0], 400);
eq("alta área inválida 400", (await call("/users", { method: "POST", headers: h, body: JSON.stringify({ email: "a@b.co", password: "12345678", nombre_completo: "X", area: "x", nivel: "admin" }) }))[0], 400);
eq("alta pw corta 400", (await call("/users", { method: "POST", headers: h, body: JSON.stringify({ email: "a@b.co", password: "123", nombre_completo: "X", area: "compras", nivel: "operador" }) }))[0], 400);
