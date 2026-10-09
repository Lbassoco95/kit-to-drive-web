/**
 * Contraseñas temporales y correo de acceso a Kit-to-Drive.
 *
 * Regla: NADIE escribe ni ve una contraseña temporal. Se genera aquí, viaja
 * solo por correo a la persona y se le exige cambiarla al entrar. La
 * contraseña nunca se registra en logs ni en la bitácora.
 *
 * Secretos de la función (Supabase → Edge Functions → Secrets):
 *   RESEND_API_KEY, RESEND_FROM_EMAIL, y opcional KIT_TO_DRIVE_APP_URL.
 */

export function generarPassword(): string {
  const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const lower = "abcdefghijkmnopqrstuvwxyz";
  const digits = "23456789";
  const symbols = "!@#$%&*";
  const all = upper + lower + digits + symbols;
  const pick = (chars: string) => chars[crypto.getRandomValues(new Uint32Array(1))[0] % chars.length];
  const out = [pick(upper), pick(lower), pick(digits), pick(symbols)];
  while (out.length < 14) out.push(pick(all));
  for (let i = out.length - 1; i > 0; i--) {
    const j = crypto.getRandomValues(new Uint32Array(1))[0] % (i + 1);
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out.join("");
}

export const escaparHtml = (t: string) =>
  t.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));

export type ResultadoCorreo = { ok: true } | { ok: false; motivo: "no_configurado" | "rechazado" | "red" };

export function correoConfigurado(): boolean {
  return !!(Deno.env.get("RESEND_API_KEY") && Deno.env.get("RESEND_FROM_EMAIL"));
}

export function htmlAcceso(to: string, nombre: string, password: string, appUrl: string, reinicio: boolean): string {
  return `
    <div style="font-family:system-ui,sans-serif;max-width:480px;margin:0 auto;padding:32px 24px">
      <h2 style="font-size:20px;font-weight:800;color:#1a1a2e;margin-bottom:8px">Hola, ${escaparHtml(nombre)}</h2>
      <p style="color:#6b7280;font-size:14px;line-height:1.6;margin-bottom:16px">
        ${reinicio ? "Se restableció tu contraseña de Kit-to-Drive." : "Se creó tu cuenta de Kit-to-Drive."} Entra con estos datos:
      </p>
      <table style="font-size:14px;color:#1a1a2e;margin-bottom:16px">
        <tr><td style="padding:2px 12px 2px 0;color:#6b7280">Correo</td><td><strong>${escaparHtml(to)}</strong></td></tr>
        <tr><td style="padding:2px 12px 2px 0;color:#6b7280">Contraseña temporal</td><td><strong style="font-family:monospace">${escaparHtml(password)}</strong></td></tr>
      </table>
      <a href="${escaparHtml(appUrl)}" style="display:inline-block;background:#032B61;color:#fff;font-weight:700;font-size:14px;padding:12px 24px;border-radius:10px;text-decoration:none">Entrar a Kit-to-Drive</a>
      <p style="color:#6b7280;font-size:13px;line-height:1.6;margin-top:20px">
        Por seguridad, <strong>al entrar por primera vez se te pedirá cambiar esta contraseña</strong>. No la compartas con nadie.
      </p>
    </div>`;
}

export async function enviarAcceso(
  to: string,
  nombre: string,
  password: string,
  reinicio: boolean,
): Promise<ResultadoCorreo> {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("RESEND_FROM_EMAIL");
  if (!key || !from) return { ok: false, motivo: "no_configurado" };
  const appUrl = Deno.env.get("KIT_TO_DRIVE_APP_URL") || "https://kit-to-drive.vercel.app";
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from,
        to: [to],
        subject: reinicio ? "Tu contraseña de Kit-to-Drive fue restablecida" : "Tu acceso a Kit-to-Drive",
        html: htmlAcceso(to, nombre, password, appUrl, reinicio),
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!r.ok) {
      // Solo el código; el cuerpo de Resend podría repetir datos del mensaje.
      console.error("Resend rechazó el correo de acceso, status", r.status);
      return { ok: false, motivo: "rechazado" };
    }
    return { ok: true };
  } catch (e) {
    console.error("Correo de acceso:", e instanceof Error ? e.name : "error");
    return { ok: false, motivo: "red" };
  }
}

export const MENSAJE_CORREO: Record<string, string> = {
  no_configurado: "El envío de correos no está configurado (faltan RESEND_API_KEY y RESEND_FROM_EMAIL). No se cambió nada.",
  rechazado: "El proveedor de correo rechazó el envío. No se cambió nada.",
  red: "No se pudo contactar al proveedor de correo. No se cambió nada.",
};
