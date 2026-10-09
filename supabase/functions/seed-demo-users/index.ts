// Edge function DESHABILITADA en producción.
// Históricamente recreaba cuentas privilegiadas con contraseñas fijas y
// verify_jwt=false. Ahora: JWT obligatorio + rechazo por defecto.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = [
  "https://kit-to-drive.vercel.app",
  "http://localhost:5173",
  "http://localhost:3000",
];

function corsHeaders(req: Request) {
  const origin = req.headers.get("Origin") ?? "";
  const allow = ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-seed-secret",
    "Vary": "Origin",
  };
}

Deno.serve(async (req) => {
  const cors = corsHeaders(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // Kill-switch: sólo labs locales con ALLOW_DEMO_SEED=true + secreto.
  const allowSeed = Deno.env.get("ALLOW_DEMO_SEED") === "true";
  const expected = Deno.env.get("SEED_DEMO_USERS_SECRET") ?? "";
  const provided = req.headers.get("x-seed-secret") ?? "";

  if (!allowSeed || !expected || provided !== expected) {
    return new Response(
      JSON.stringify({
        error: "seed-demo-users deshabilitada. No disponible en producción.",
      }),
      { status: 410, headers: { ...cors, "Content-Type": "application/json" } },
    );
  }

  // Lab only: exigir caller admin global (además del secreto).
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...cors, "Content-Type": "application/json" },
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
        status: 401, headers: { ...cors, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: roleRow } = await admin
      .from("user_roles")
      .select("nivel, area")
      .eq("user_id", user.id)
      .maybeSingle();

    if (!(roleRow?.nivel === "admin" && roleRow?.area === "direccion")) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403, headers: { ...cors, "Content-Type": "application/json" },
      });
    }

    // Lab: no hay lista de passwords fijas en el bundle. El body debe traer
    // usuarios a crear (email, password, nombre, role). Sin body → no-op.
    const body = await req.json().catch(() => null) as
      | { users?: Array<{ email: string; password: string; nombre: string; role: string; codigo_vendedor?: string }> }
      | null;

    if (!body?.users?.length) {
      return new Response(JSON.stringify({ ok: true, created: [], existed: [], note: "sin usuarios en body" }), {
        headers: { ...cors, "Content-Type": "application/json" },
      });
    }

    const created: string[] = [];
    const existed: string[] = [];

    for (const d of body.users) {
      if (!d.email || !d.password || !d.nombre || !d.role) continue;
      if (d.password.length < 12) {
        return new Response(JSON.stringify({ error: `password corta para ${d.email}` }), {
          status: 400, headers: { ...cors, "Content-Type": "application/json" },
        });
      }

      const { data: listed } = await admin.auth.admin.listUsers({ page: 1, perPage: 200 });
      const ex = (listed?.users ?? []).find((u) => u.email?.toLowerCase() === d.email.toLowerCase());

      let userId: string;
      if (ex) {
        userId = ex.id;
        existed.push(d.email);
      } else {
        const { data, error } = await admin.auth.admin.createUser({
          email: d.email,
          password: d.password,
          email_confirm: true,
          user_metadata: { nombre_completo: d.nombre },
          app_metadata: { must_change_password: true },
        });
        if (error) throw error;
        userId = data.user!.id;
        created.push(d.email);
      }

      await admin.from("profiles").upsert({
        id: userId,
        nombre_completo: d.nombre,
        codigo_vendedor: d.codigo_vendedor ?? null,
        debe_cambiar_password: true,
      });
      await admin.from("user_roles").delete().eq("user_id", userId);
      await admin.from("user_roles").insert({ user_id: userId, role: d.role });
    }

    return new Response(JSON.stringify({ ok: true, created, existed }), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
