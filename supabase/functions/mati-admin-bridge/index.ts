/**
 * Puente de administración para mati-admin / mati-api.
 *
 * Kit-to-Drive se administra desde el panel de Mati (mati-admin). Esta edge
 * function es el contrato HTTP que mati-api debe llamar con un secreto
 * compartido (MATI_ADMIN_BRIDGE_SECRET), no con un JWT de usuario local.
 *
 * Rutas (después de /functions/v1/mati-admin-bridge):
 *   GET    /health
 *   GET    /meta
 *   GET    /users
 *   GET    /users/:id
 *   POST   /users
 *   PATCH  /users/:id
 *   POST   /users/:id/activate
 *   POST   /users/:id/deactivate
 *   POST   /users/:id/reset-password
 *   GET    /config
 *   PATCH  /config
 *
 * Auth: header `Authorization: Bearer <MATI_ADMIN_BRIDGE_SECRET>`
 *    o  header `x-mati-bridge-secret: <MATI_ADMIN_BRIDGE_SECRET>`
 */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-mati-bridge-secret",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS",
};

const AREAS = ["comercial", "fabrica", "almacen_logistica", "administracion", "direccion"] as const;
const NIVELES = ["operador", "supervisor", "admin"] as const;
type Area = (typeof AREAS)[number];
type Nivel = (typeof NIVELES)[number];

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const rolLegacy = (a: Area, n: Nivel) => {
  if (a === "comercial") return n === "admin" ? "director_ventas" : n === "supervisor" ? "coordinador_ventas" : "ventas";
  if (a === "fabrica") return "fabrica";
  if (a === "almacen_logistica") return "logistica";
  if (a === "administracion") return n === "operador" ? "finanzas" : "admin_financiero";
  return n === "admin" ? "admin" : "coordinador";
};

function adminClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}

function secretOk(req: Request): boolean {
  const expected = Deno.env.get("MATI_ADMIN_BRIDGE_SECRET");
  if (!expected) return false;
  const bearer = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "").trim();
  const header = req.headers.get("x-mati-bridge-secret")?.trim();
  return bearer === expected || header === expected;
}

/** Extrae el path relativo a la función (soporta invocación directa y con /functions/v1/...). */
function relativePath(req: Request): string {
  const url = new URL(req.url);
  const marker = "/mati-admin-bridge";
  const idx = url.pathname.indexOf(marker);
  const rest = idx >= 0 ? url.pathname.slice(idx + marker.length) : url.pathname;
  return rest.replace(/\/+$/, "") || "/";
}

async function listUsers(admin: ReturnType<typeof adminClient>) {
  const [{ data: profiles, error: pErr }, { data: roles, error: rErr }] = await Promise.all([
    admin.from("profiles").select("id, email, nombre_completo, codigo_vendedor, activo").order("nombre_completo"),
    admin.from("user_roles").select("user_id, area, nivel, role"),
  ]);
  if (pErr) throw new Error(pErr.message);
  if (rErr) throw new Error(rErr.message);
  return (profiles ?? []).map((p) => {
    const r = (roles ?? []).find((x) => x.user_id === p.id);
    return {
      id: p.id,
      email: p.email,
      nombre_completo: p.nombre_completo,
      codigo_vendedor: p.codigo_vendedor,
      activo: p.activo,
      area: r?.area ?? null,
      nivel: r?.nivel ?? null,
      role: r?.role ?? null,
    };
  });
}

async function getUser(admin: ReturnType<typeof adminClient>, id: string) {
  const { data: profile, error } = await admin
    .from("profiles")
    .select("id, email, nombre_completo, codigo_vendedor, activo")
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!profile) return null;
  const { data: role } = await admin.from("user_roles").select("area, nivel, role").eq("user_id", id).maybeSingle();
  return { ...profile, area: role?.area ?? null, nivel: role?.nivel ?? null, role: role?.role ?? null };
}

async function upsertRole(admin: ReturnType<typeof adminClient>, userId: string, area: Area, nivel: Nivel) {
  await admin.from("user_roles").delete().eq("user_id", userId);
  const { error } = await admin.from("user_roles").insert({
    user_id: userId,
    area,
    nivel,
    role: rolLegacy(area, nivel),
  });
  if (error) throw new Error(error.message);
}

async function createUser(admin: ReturnType<typeof adminClient>, body: Record<string, unknown>) {
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  const nombre_completo = String(body.nombre_completo ?? "").trim();
  const area = body.area as Area;
  const nivel = body.nivel as Nivel;
  const codigo_vendedor = body.codigo_vendedor ? String(body.codigo_vendedor).trim() : null;
  const force_password_change = body.force_password_change === true;

  if (!email || !password || !nombre_completo) {
    return json({ error: "email, password y nombre_completo son obligatorios" }, 400);
  }
  if (password.length < 8) {
    return json({ error: "La contraseña debe tener al menos 8 caracteres" }, 400);
  }
  if (!AREAS.includes(area) || !NIVELES.includes(nivel)) {
    return json({ error: "area o nivel inválidos" }, 400);
  }

  const { data: list, error: listErr } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (listErr) return json({ error: listErr.message }, 500);

  const existente = (list?.users ?? []).find((u) => u.email?.toLowerCase() === email);
  const userMetadata = {
    must_change_password: force_password_change,
    full_name: nombre_completo,
    managed_by: "mati-admin",
  };

  let uid: string;
  if (existente) {
    const { error: updateErr } = await admin.auth.admin.updateUserById(existente.id, {
      password,
      email_confirm: true,
      user_metadata: { ...(existente.user_metadata || {}), ...userMetadata },
    });
    if (updateErr) return json({ error: updateErr.message }, 400);
    uid = existente.id;
  } else {
    const { data: newUser, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: userMetadata,
    });
    if (createErr) return json({ error: createErr.message }, 400);
    uid = newUser.user!.id;
  }

  const { error: profErr } = await admin.from("profiles").upsert({
    id: uid,
    email,
    nombre_completo,
    codigo_vendedor,
    activo: true,
  });
  if (profErr) return json({ error: profErr.message }, 500);

  await upsertRole(admin, uid, area, nivel);
  const user = await getUser(admin, uid);
  return json({ user }, 200);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    if (!Deno.env.get("MATI_ADMIN_BRIDGE_SECRET")) {
      return json({
        error: "Bridge no configurado: falta el secreto MATI_ADMIN_BRIDGE_SECRET en la edge function",
        code: "BRIDGE_NOT_CONFIGURED",
      }, 503);
    }
    if (!secretOk(req)) {
      return json({ error: "Unauthorized" }, 401);
    }

    const admin = adminClient();
    const path = relativePath(req);
    const method = req.method.toUpperCase();

    if (method === "GET" && path === "/health") {
      return json({
        status: "ok",
        system: "kit-to-drive",
        brand: "mati",
        project_id: Deno.env.get("SUPABASE_URL")?.match(/https:\/\/([^.]+)/)?.[1] ?? null,
        timestamp: Date.now(),
      });
    }

    if (method === "GET" && path === "/meta") {
      return json({
        system: "kit-to-drive",
        brand: "mati",
        areas: AREAS,
        niveles: NIVELES,
        admin_ui: "https://mati-admin.vercel.app",
        app_ui: "https://kit-to-drive.vercel.app",
        modelo: "area × nivel (role legacy derivado)",
      });
    }

    if (method === "GET" && path === "/users") {
      return json({ users: await listUsers(admin) });
    }

    const userMatch = path.match(/^\/users\/([^/]+)(?:\/(activate|deactivate|reset-password))?$/);
    if (userMatch) {
      const userId = decodeURIComponent(userMatch[1]);
      const action = userMatch[2];

      if (method === "GET" && !action) {
        const user = await getUser(admin, userId);
        if (!user) return json({ error: "Usuario no encontrado" }, 404);
        return json({ user });
      }

      if (method === "PATCH" && !action) {
        const body = await req.json();
        const patch: Record<string, unknown> = {};
        if (typeof body.nombre_completo === "string") patch.nombre_completo = body.nombre_completo.trim();
        if (typeof body.email === "string") patch.email = body.email.trim().toLowerCase() || null;
        if (typeof body.codigo_vendedor === "string") patch.codigo_vendedor = body.codigo_vendedor.trim() || null;
        if (typeof body.activo === "boolean") patch.activo = body.activo;

        if (Object.keys(patch).length) {
          const { error } = await admin.from("profiles").update(patch).eq("id", userId);
          if (error) return json({ error: error.message }, 400);
        }

        if (body.area || body.nivel) {
          const current = await getUser(admin, userId);
          const area = (body.area ?? current?.area) as Area;
          const nivel = (body.nivel ?? current?.nivel) as Nivel;
          if (!AREAS.includes(area) || !NIVELES.includes(nivel)) {
            return json({ error: "area o nivel inválidos" }, 400);
          }
          await upsertRole(admin, userId, area, nivel);
        }

        return json({ user: await getUser(admin, userId) });
      }

      if (method === "POST" && action === "activate") {
        const { error } = await admin.from("profiles").update({ activo: true }).eq("id", userId);
        if (error) return json({ error: error.message }, 400);
        return json({ user: await getUser(admin, userId) });
      }

      if (method === "POST" && action === "deactivate") {
        const { error } = await admin.from("profiles").update({ activo: false }).eq("id", userId);
        if (error) return json({ error: error.message }, 400);
        return json({ user: await getUser(admin, userId) });
      }

      if (method === "POST" && action === "reset-password") {
        const body = await req.json();
        const password = String(body.password ?? "");
        if (password.length < 8) {
          return json({ error: "La contraseña debe tener al menos 8 caracteres" }, 400);
        }
        const { error } = await admin.auth.admin.updateUserById(userId, {
          password,
          user_metadata: {
            must_change_password: body.force_password_change !== false,
          },
        });
        if (error) return json({ error: error.message }, 400);
        return json({ ok: true, user_id: userId });
      }
    }

    if (method === "POST" && path === "/users") {
      return await createUser(admin, await req.json());
    }

    if (method === "GET" && path === "/config") {
      const { data, error } = await admin.from("config_general").select("*").eq("id", 1).maybeSingle();
      if (error) return json({ error: error.message }, 500);
      return json({ config: data });
    }

    if (method === "PATCH" && path === "/config") {
      const body = await req.json();
      const allowed = [
        "empresa_nombre",
        "capacidad_diaria",
        "plazo_max_credito_dias",
        "limite_ya_armados",
      ];
      const patch: Record<string, unknown> = {};
      for (const key of allowed) {
        if (key in body) patch[key] = body[key];
      }
      if (!Object.keys(patch).length) {
        return json({ error: `Ningún campo permitido. Usa: ${allowed.join(", ")}` }, 400);
      }
      const { data, error } = await admin.from("config_general").update(patch).eq("id", 1).select("*").maybeSingle();
      if (error) return json({ error: error.message }, 400);
      return json({ config: data });
    }

    return json({ error: "Ruta no encontrada", path, method }, 404);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message }, 500);
  }
});
