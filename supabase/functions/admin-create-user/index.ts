import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
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
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}

serve(async (req) => {
  const CORS = corsHeaders(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    // 1. Verificar que el que llama es admin
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response("Unauthorized", { status: 401, headers: CORS });

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user: caller }, error: authErr } = await supabaseClient.auth.getUser();
    if (authErr || !caller) return new Response("Unauthorized", { status: 401, headers: CORS });

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data: roleRow } = await supabaseAdmin
      .from("user_roles")
      .select("role, nivel, area")
      .eq("user_id", caller.id)
      .single();

    const callerNivel = roleRow?.nivel ?? (roleRow?.role === "admin" ? "admin" : null);
    const callerArea = roleRow?.area ?? (roleRow?.role === "admin" ? "direccion" : null);
    const esAdminGlobal = callerNivel === "admin" && callerArea === "direccion";

    if (callerNivel !== "admin") {
      return new Response(JSON.stringify({ error: "Forbidden: solo un administrador puede crear usuarios" }), {
        status: 403, headers: { ...CORS, "Content-Type": "application/json" }
      });
    }

    const body = await req.json();
    const { email, password, nombre_completo, codigo_vendedor, force_password_change } = body;

    if (!email || !password || !nombre_completo) {
      return new Response(JSON.stringify({ error: "email, password y nombre_completo son obligatorios" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" }
      });
    }

    const mustChangePassword = force_password_change === true;

    const AREAS = ["comercial", "fabrica", "almacen_logistica", "administracion", "compras", "direccion"];
    const NIVELES = ["operador", "supervisor", "admin"];

    const desdeRolLegacy = (role: string) => {
      switch (role) {
        case "admin":              return { area: "direccion",         nivel: "admin"      };
        case "director_ventas":    return { area: "comercial",         nivel: "admin"      };
        case "coordinador_ventas":
        case "coordinador":        return { area: "comercial",         nivel: "supervisor" };
        case "ventas":
        case "auxiliar_ventas":    return { area: "comercial",         nivel: "operador"   };
        case "fabrica":            return { area: "fabrica",           nivel: "operador"   };
        case "logistica":          return { area: "almacen_logistica", nivel: "operador"   };
        case "admin_financiero":   return { area: "administracion",    nivel: "admin"      };
        case "finanzas":           return { area: "administracion",    nivel: "operador"   };
        case "compras":            return { area: "compras",           nivel: "operador"   };
        default:                   return null;
      }
    };

    let area = body.area;
    let nivel = body.nivel;
    if (!area || !nivel) {
      const equivalente = body.role ? desdeRolLegacy(body.role) : null;
      if (!equivalente) {
        return new Response(JSON.stringify({ error: "area y nivel son obligatorios" }), {
          status: 400, headers: { ...CORS, "Content-Type": "application/json" }
        });
      }
      area = area ?? equivalente.area;
      nivel = nivel ?? equivalente.nivel;
    }

    if (!AREAS.includes(area)) {
      return new Response(JSON.stringify({ error: "Área inválida" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" }
      });
    }
    if (!NIVELES.includes(nivel)) {
      return new Response(JSON.stringify({ error: "Tipo de usuario inválido" }), {
        status: 400, headers: { ...CORS, "Content-Type": "application/json" }
      });
    }

    if (!esAdminGlobal && area !== callerArea) {
      return new Response(JSON.stringify({ error: "Solo puedes crear usuarios de tu propia área" }), {
        status: 403, headers: { ...CORS, "Content-Type": "application/json" }
      });
    }

    const rolLegacy = (a: string, n: string) => {
      if (a === "comercial") return n === "admin" ? "director_ventas" : n === "supervisor" ? "coordinador_ventas" : "ventas";
      if (a === "fabrica") return "fabrica";
      if (a === "almacen_logistica") return "logistica";
      if (a === "administracion") return n === "operador" ? "finanzas" : "admin_financiero";
      if (a === "compras") return "compras";
      return n === "admin" ? "admin" : "coordinador";
    };
    const rolDerivado = rolLegacy(area, nivel);

    // Buscar por email sin volcar 1000 usuarios: paginar hasta encontrar o agotar.
    let existente: { id: string; user_metadata?: Record<string, unknown>; app_metadata?: Record<string, unknown> } | undefined;
    for (let page = 1; page <= 10 && !existente; page++) {
      const { data: list, error: listErr } = await supabaseAdmin.auth.admin.listUsers({ page, perPage: 200 });
      if (listErr) {
        return new Response(JSON.stringify({ error: listErr.message }), {
          status: 500, headers: { ...CORS, "Content-Type": "application/json" }
        });
      }
      const users = list?.users ?? [];
      existente = users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
      if (users.length < 200) break;
    }

    let uid: string;

    // Flag de privilegio en app_metadata (solo Admin API); user_metadata es editable por el cliente.
    const appMeta = {
      must_change_password: mustChangePassword,
      created_via_admin: true,
      managed_by: "admin-create-user",
    };
    const userMeta = {
      full_name: nombre_completo.trim(),
      // limpia flag legacy editable por el cliente si existía
      must_change_password: false,
    };

    if (existente) {
      const { error: updateErr } = await supabaseAdmin.auth.admin.updateUserById(existente.id, {
        password,
        email_confirm: true,
        app_metadata: { ...(existente.app_metadata || {}), ...appMeta },
        user_metadata: { ...(existente.user_metadata || {}), ...userMeta },
      });
      if (updateErr) {
        return new Response(JSON.stringify({ error: updateErr.message }), {
          status: 400, headers: { ...CORS, "Content-Type": "application/json" }
        });
      }
      uid = existente.id;
    } else {
      const { data: newUser, error: createErr } = await supabaseAdmin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        app_metadata: appMeta,
        user_metadata: userMeta,
      });
      if (createErr) {
        return new Response(JSON.stringify({ error: createErr.message }), {
          status: 400, headers: { ...CORS, "Content-Type": "application/json" }
        });
      }
      uid = newUser.user!.id;
    }

    await supabaseAdmin.from("profiles").upsert({
      id: uid,
      email: email.toLowerCase().trim(),
      nombre_completo: nombre_completo.trim(),
      codigo_vendedor: codigo_vendedor?.trim() || null,
      activo: true,
      debe_cambiar_password: mustChangePassword,
    });

    await supabaseAdmin.from("user_roles").upsert({
      user_id: uid,
      area,
      nivel,
      role: rolDerivado,
    }, { onConflict: "user_id" });

    return new Response(JSON.stringify({ user_id: uid, email, nombre_completo, area, nivel, role: rolDerivado }), {
      status: 200, headers: { ...CORS, "Content-Type": "application/json" }
    });

  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return new Response(JSON.stringify({ error: message }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" }
    });
  }
});
