import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

    // Verificar que el caller sea admin
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

    // Verificar permisos del caller
    const { data: callerRole } = await supabaseAdmin
      .from("user_roles")
      .select("role, nivel, area")
      .eq("user_id", caller.id)
      .maybeSingle();
    
    const callerNivel = callerRole?.nivel ?? (callerRole?.role === "admin" ? "admin" : null);
    const callerArea = callerRole?.area ?? (callerRole?.role === "admin" ? "direccion" : null);
    
    if (callerNivel !== "admin") {
      return respond({ error: "Forbidden: solo un administrador puede actualizar usuarios" }, 403);
    }

    // Obtener datos del request
    const { user_id, nombre_completo, email, codigo_vendedor, activo, area, nivel } = await req.json();
    
    if (!user_id || typeof user_id !== "string") {
      return respond({ error: "user_id es obligatorio" }, 400);
    }

    // Verificar que el admin puede editar este usuario
    const { data: targetRole } = await supabaseAdmin
      .from("user_roles")
      .select("area")
      .eq("user_id", user_id)
      .maybeSingle();
    
    const esAdminGlobal = callerArea === "direccion";
    if (!esAdminGlobal && targetRole?.area !== callerArea) {
      return respond({ 
        error: "Solo puedes actualizar usuarios de tu propia área" 
      }, 403);
    }

    // 1. Actualizar auth.users (email en Supabase Auth)
    if (email) {
      const { error: authUpdateError } = await supabaseAdmin.auth.admin.updateUserById(
        user_id,
        { email: email.trim().toLowerCase() }
      );
      
      if (authUpdateError) {
        return respond({ 
          error: `Error actualizando auth.users: ${authUpdateError.message}` 
        }, 400);
      }
    }

    // 2. Actualizar profiles
    const { error: profileError } = await supabaseAdmin
      .from("profiles")
      .update({
        nombre_completo: nombre_completo?.trim() || null,
        email: email?.trim() || null,
        codigo_vendedor: codigo_vendedor?.trim() || null,
        activo: activo ?? true,
      })
      .eq("id", user_id);

    if (profileError) {
      return respond({ 
        error: `Error actualizando profiles: ${profileError.message}` 
      }, 500);
    }

    // 3. Actualizar user_roles si se proporcionan
    if (area && nivel) {
      // Importar función rolLegacy (deberías tenerla disponible)
      const LEGACY_ROLE: Record<string, Record<string, string>> = {
        comercial: { operador: "ventas", supervisor: "coordinador_ventas", admin: "director_ventas" },
        fabrica: { operador: "fabrica", supervisor: "fabrica", admin: "fabrica" },
        almacen_logistica: { operador: "logistica", supervisor: "logistica", admin: "logistica" },
        administracion: { operador: "finanzas", supervisor: "admin_financiero", admin: "admin_financiero" },
        compras: { operador: "compras", supervisor: "compras", admin: "compras" },
        direccion: { operador: "coordinador", supervisor: "coordinador", admin: "admin" },
      };
      
      const role = LEGACY_ROLE[area]?.[nivel] || "ventas";

      // Eliminar roles existentes y crear nuevo
      await supabaseAdmin.from("user_roles").delete().eq("user_id", user_id);
      
      const { error: roleError } = await supabaseAdmin
        .from("user_roles")
        .insert({
          user_id,
          area,
          nivel,
          role,
        });

      if (roleError) {
        return respond({ 
          error: `Error actualizando user_roles: ${roleError.message}` 
        }, 500);
      }
    }

    return respond({ 
      success: true,
      message: "Usuario actualizado correctamente",
      updated: { email, nombre_completo, area, nivel, activo }
    });

  } catch (error) {
    console.error("Error en admin-update-user:", error);
    return respond({ 
      error: error instanceof Error ? error.message : "Error inesperado" 
    }, 500);
  }
});
