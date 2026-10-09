import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const JSON_HEADERS = { ...CORS, "Content-Type": "application/json" };

const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });

const generateTemporaryPassword = () => {
  const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const lower = "abcdefghijkmnopqrstuvwxyz";
  const digits = "23456789";
  const symbols = "!@#$%&*";
  const all = upper + lower + digits + symbols;
  const random = (characters: string) => characters[crypto.getRandomValues(new Uint32Array(1))[0] % characters.length];
  const password = [random(upper), random(lower), random(digits), random(symbols)];
  while (password.length < 14) password.push(random(all));
  for (let i = password.length - 1; i > 0; i--) {
    const j = crypto.getRandomValues(new Uint32Array(1))[0] % (i + 1);
    [password[i], password[j]] = [password[j], password[i]];
  }
  return password.join("");
};

// 🆕 Función para enviar email con Resend
const sendPasswordEmail = async (email: string, password: string, userName: string) => {
  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  
  if (!RESEND_API_KEY) {
    console.warn("RESEND_API_KEY no configurada, email no enviado");
    return { success: false, error: "RESEND_API_KEY no configurada" };
  }

  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Dazon Mex <noreply@dazon.demo>", // 🔴 CAMBIAR por tu dominio real
        to: [email],
        subject: "Nueva contraseña temporal - Kit to Drive",
        html: `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
            <h2 style="color: #032b62;">Nueva Contraseña Temporal</h2>
            <p>Hola ${userName},</p>
            <p>Se ha generado una nueva contraseña temporal para tu cuenta:</p>
            <div style="background-color: #f3f4f6; padding: 15px; border-radius: 8px; margin: 20px 0;">
              <code style="font-size: 18px; font-weight: bold; color: #032b62;">${password}</code>
            </div>
            <p><strong>⚠️ Importante:</strong></p>
            <ul>
              <li>Deberás cambiar esta contraseña al iniciar sesión</li>
              <li>Por seguridad, no compartas esta contraseña</li>
              <li>Esta contraseña es temporal y debe ser cambiada</li>
            </ul>
            <p>Si no solicitaste este cambio, contacta a un administrador inmediatamente.</p>
            <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 30px 0;">
            <p style="color: #6b7280; font-size: 12px;">
              Dazon Mex - Sistema de Control de Producción<br>
              Este es un correo automático, por favor no respondas.
            </p>
          </div>
        `,
      }),
    });

    const data = await response.json();
    
    if (!response.ok) {
      console.error("Error enviando email con Resend:", data);
      return { success: false, error: data.message || "Error al enviar email" };
    }

    console.log("Email enviado exitosamente:", data);
    return { success: true, emailId: data.id };
  } catch (error) {
    console.error("Error al enviar email:", error);
    return { success: false, error: error instanceof Error ? error.message : "Error desconocido" };
  }
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return respond({ error: "Unauthorized" }, 401);

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user: caller }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !caller) return respond({ error: "Unauthorized" }, 401);

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: callerRole } = await supabaseAdmin
      .from("user_roles")
      .select("role, nivel, area")
      .eq("user_id", caller.id)
      .maybeSingle();
    const callerNivel = callerRole?.nivel ?? (callerRole?.role === "admin" ? "admin" : null);
    const callerArea = callerRole?.area ?? (callerRole?.role === "admin" ? "direccion" : null);
    if (callerNivel !== "admin") return respond({ error: "Forbidden: solo un administrador puede restablecer contraseñas" }, 403);

    const { user_id, send_email } = await req.json(); // 🆕 Agregado send_email param
    if (!user_id || typeof user_id !== "string") return respond({ error: "user_id es obligatorio" }, 400);

    const { data: targetRole } = await supabaseAdmin
      .from("user_roles")
      .select("area")
      .eq("user_id", user_id)
      .maybeSingle();
    const esAdminGlobal = callerArea === "direccion";
    if (!esAdminGlobal && targetRole?.area !== callerArea) {
      return respond({ error: "Solo puedes restablecer contraseñas de usuarios de tu propia área" }, 403);
    }

    const { data: target, error: targetError } = await supabaseAdmin.auth.admin.getUserById(user_id);
    if (targetError || !target.user) return respond({ error: "Usuario no encontrado" }, 404);

    const temporaryPassword = generateTemporaryPassword();
    const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(user_id, {
      password: temporaryPassword,
      app_metadata: {
        ...(target.user.app_metadata || {}),
        must_change_password: true,
      },
      user_metadata: {
        ...(target.user.user_metadata || {}),
        must_change_password: true,
      },
    });
    if (updateError) return respond({ error: updateError.message }, 400);

    const { error: profileError } = await supabaseAdmin
      .from("profiles")
      .update({ debe_cambiar_password: true })
      .eq("id", user_id);
    if (profileError) return respond({ error: profileError.message }, 500);

    // 🆕 Enviar email si se solicita
    let emailResult = null;
    if (send_email === true) {
      const { data: profile } = await supabaseAdmin
        .from("profiles")
        .select("nombre_completo")
        .eq("id", user_id)
        .single();
      
      emailResult = await sendPasswordEmail(
        target.user.email!,
        temporaryPassword,
        profile?.nombre_completo || "Usuario"
      );
    }

    return respond({ 
      temporary_password: temporaryPassword,
      email_sent: emailResult?.success || false,
      email_error: emailResult?.error || null
    });
  } catch (error) {
    return respond({ error: error instanceof Error ? error.message : "Error inesperado" }, 500);
  }
});
