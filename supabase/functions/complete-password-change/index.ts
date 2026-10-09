// Cambia la contraseña del caller Y limpia must_change_password en
// app_metadata + profiles.debe_cambiar_password de forma atómica (Admin API).
// El cliente NO puede limpiar el flag sin enviar una password nueva.
// IMPORTANTE: updateUserById con password revoca refresh tokens → el cliente
// debe cerrar sesión local y pedir re-login (reauth_required: true).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = [
  "https://kit-to-drive.vercel.app",
  "http://localhost:5173",
  "http://localhost:3000",
];

function isAllowedOrigin(origin: string): boolean {
  if (!origin) return false;
  if (ALLOWED_ORIGINS.includes(origin)) return true;
  try {
    const { hostname, protocol } = new URL(origin);
    if (protocol !== "https:" && protocol !== "http:") return false;
    // Previews de Vercel del mismo proyecto (p. ej. kit-to-drive-xxx.vercel.app)
    if (hostname.endsWith(".vercel.app") && hostname.includes("kit-to-drive")) return true;
    return false;
  } catch {
    return false;
  }
}

function corsHeaders(req: Request) {
  const origin = req.headers.get("Origin") ?? "";
  const allow = isAllowedOrigin(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}

serve(async (req) => {
  const CORS = corsHeaders(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const body = await req.json().catch(() => ({})) as { password?: string };
    const password = typeof body.password === "string" ? body.password : "";
    if (password.length < 8) {
      return new Response(JSON.stringify({ error: "password inválida (mínimo 8 caracteres)" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
    if (/dazon/i.test(password) || password.includes("1234")) {
      return new Response(JSON.stringify({ error: "Elige una contraseña más segura" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Atómico: set password + clear flags. Sin password en body → 400 (arriba).
    // Nota: esto revoca refresh tokens del usuario.
    const { error: updErr } = await admin.auth.admin.updateUserById(user.id, {
      password,
      app_metadata: {
        ...(user.app_metadata || {}),
        must_change_password: false,
      },
      user_metadata: {
        ...(user.user_metadata || {}),
        must_change_password: false,
      },
    });
    if (updErr) {
      return new Response(JSON.stringify({ error: updErr.message }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // RPC SECURITY DEFINER (service_role): más fiable que UPDATE directo + trigger.
    const { error: profErr } = await admin.rpc("admin_clear_debe_cambiar_password", {
      _user_id: user.id,
    });
    if (profErr) {
      // Fallback: UPDATE directo (service_role → auth.uid() null → trigger OK).
      const { error: updProfErr } = await admin
        .from("profiles")
        .update({ debe_cambiar_password: false })
        .eq("id", user.id);
      if (updProfErr) {
        return new Response(JSON.stringify({ error: updProfErr.message }), {
          status: 500, headers: { ...CORS, "Content-Type": "application/json" },
        });
      }
    }

    return new Response(JSON.stringify({ ok: true, reauth_required: true }), {
      status: 200, headers: { ...CORS, "Content-Type": "application/json" },
    });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message ?? String(err) }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
