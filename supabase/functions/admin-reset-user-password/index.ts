import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { enviarAcceso, generarPassword, MENSAJE_CORREO } from "../_shared/acceso.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const JSON_HEADERS = { ...CORS, "Content-Type": "application/json" };

const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });

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

    const { user_id } = await req.json();
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

    const email = target.user.email;
    if (!email) return respond({ error: "La persona no tiene correo registrado" }, 400);
    const { data: perfil } = await supabaseAdmin.from("profiles").select("nombre_completo").eq("id", user_id).maybeSingle();

    // La contraseña la genera esta función y viaja solo por correo; nadie la ve.
    // El correo va PRIMERO: si no sale, no se cambia nada (la persona sigue pudiendo entrar).
    const temporaryPassword = generarPassword();
    const envio = await enviarAcceso(email, perfil?.nombre_completo || email, temporaryPassword, true);
    if (!envio.ok) {
      return respond({ error: MENSAJE_CORREO[envio.motivo], code: "CORREO_FALLO" }, envio.motivo === "no_configurado" ? 503 : 502);
    }

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

    return respond({ ok: true, correo: { enviado: true } });
  } catch (error) {
    return respond({ error: error instanceof Error ? error.message : "Error inesperado" }, 500);
  }
});
