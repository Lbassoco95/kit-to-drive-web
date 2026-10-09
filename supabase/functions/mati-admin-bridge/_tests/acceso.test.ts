import { enviarAcceso, escaparHtml, generarPassword, htmlAcceso } from "../../_shared/acceso.ts";
const eq = (name: string, got: unknown, want: unknown) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(ok ? "OK  " : "FAIL", name, ok ? "" : `got=${JSON.stringify(got)} want=${JSON.stringify(want)}`);
  if (!ok) Deno.exitCode = 1;
};

// Contraseñas: 14 caracteres, mayúscula, minúscula, número y símbolo, y distintas entre sí.
const pws = Array.from({ length: 200 }, generarPassword);
eq("14 caracteres", pws.every((p) => p.length === 14), true);
eq("compleja", pws.every((p) => /[A-Z]/.test(p) && /[a-z]/.test(p) && /[2-9]/.test(p) && /[!@#$%&*]/.test(p)), true);
eq("sin duplicados", new Set(pws).size, pws.length);

// HTML: lo que escribe un admin (nombre) no inyecta marcas.
eq("escapa", escaparHtml(`<img src=x onerror="a">&'`), "&lt;img src=x onerror=&quot;a&quot;&gt;&amp;&#39;");
const html = htmlAcceso("a@b.co", "<b>Ana</b>", "Pw-123", "https://app.test", false);
eq("html sin etiquetas inyectadas", html.includes("<b>Ana</b>"), false);
eq("html lleva la contraseña y el aviso de cambio", html.includes("Pw-123") && html.includes("cambiar esta contraseña"), true);

// Envío con fetch falso.
const real = globalThis.fetch;
let ultimo: { url: string; body: any; auth: string | null } | null = null;
let status = 200;
globalThis.fetch = ((url: string, init: RequestInit) => {
  ultimo = { url: String(url), body: JSON.parse(String(init.body)), auth: new Headers(init.headers).get("Authorization") };
  return Promise.resolve(new Response("{}", { status }));
}) as typeof fetch;

Deno.env.delete("RESEND_API_KEY"); Deno.env.delete("RESEND_FROM_EMAIL");
eq("sin secretos: no_configurado y no llama a la red", [await enviarAcceso("a@b.co", "Ana", "x", false), ultimo], [{ ok: false, motivo: "no_configurado" }, null]);

Deno.env.set("RESEND_API_KEY", "re_test"); Deno.env.set("RESEND_FROM_EMAIL", "Dazon <no-responder@dazon.mx>");
eq("ok", await enviarAcceso("a@b.co", "Ana", "Pw-123", false), { ok: true });
eq("destinatario y remitente", [ultimo!.body.to, ultimo!.body.from, ultimo!.auth], [["a@b.co"], "Dazon <no-responder@dazon.mx>", "Bearer re_test"]);
eq("asunto de alta", ultimo!.body.subject, "Tu acceso a Kit-to-Drive");
await enviarAcceso("a@b.co", "Ana", "Pw-123", true);
eq("asunto de reinicio", ultimo!.body.subject, "Tu contraseña de Kit-to-Drive fue restablecida");
status = 422;
eq("rechazado", await enviarAcceso("a@b.co", "Ana", "x", false), { ok: false, motivo: "rechazado" });
globalThis.fetch = (() => Promise.reject(new Error("red"))) as typeof fetch;
eq("red caída", await enviarAcceso("a@b.co", "Ana", "x", false), { ok: false, motivo: "red" });
globalThis.fetch = real;
