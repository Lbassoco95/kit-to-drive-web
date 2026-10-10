/**
 * Puente de administración MATI Admin ↔ Kit-to-Drive (v2).
 *
 * Lo llama SOLO mati-api, de servidor a servidor, con un secreto compartido
 * (MATI_ADMIN_BRIDGE_SECRET). No es para navegadores: no responde CORS.
 *
 * Auth: `Authorization: Bearer <secreto>` o `x-mati-bridge-secret: <secreto>`.
 *
 * Rutas (después de /functions/v1/mati-admin-bridge):
 *   GET    /health
 *   GET    /meta
 *   GET    /app/status
 *   GET    /users                       POST /users
 *   GET    /users/:id                   PATCH /users/:id
 *   POST   /users/:id/activate          POST /users/:id/deactivate
 *   POST   /users/:id/reset-password
 *   GET    /config                      PATCH /config
 *   GET    /modules                     PUT /modules/:clave   { activo }
 *   GET    /tickets?estado=&limit=      GET /tickets/:id
 *   PATCH  /tickets/:id                 POST /tickets/:id/messages
 *   GET    /audit?limit=
 *
 * Toda acción que cambia algo queda en public.bridge_bitacora (sin contraseñas),
 * con el actor que mandó mati-api en `x-mati-actor`.
 */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { autorizarAlta, enviarAcceso, generarPassword, MENSAJE_CORREO } from "../_shared/acceso.ts";

const AREAS = ["comercial", "fabrica", "almacen_logistica", "administracion", "compras", "direccion"] as const;
const NIVELES = ["operador", "supervisor", "admin"] as const;
type Area = (typeof AREAS)[number];
type Nivel = (typeof NIVELES)[number];

const TICKET_ESTADOS = ["abierto", "en_progreso", "resuelto", "cerrado"] as const;
const TICKET_PRIORIDADES = ["baja", "media", "alta", "urgente"] as const;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MODULO_RE = /^[A-Za-z][A-Za-z0-9]{1,40}$/;
const MAX_BODY_BYTES = 64 * 1024;

class HttpError extends Error {
  constructor(public status: number, message: string, public code?: string) {
    super(message);
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

// El cliente lleva el actor (quién pidió la acción desde MATI Admin) para la bitácora.
type Admin = ReturnType<typeof adminClient> & { actor?: string | null };

function adminClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

// ── Autenticación ───────────────────────────────────────────────────────────

/** Comparación en tiempo constante: compara los SHA-256, no el texto crudo. */
async function safeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const x = new Uint8Array(ha);
  const y = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function secretOk(req: Request, expected: string): Promise<boolean> {
  const bearer = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "").trim() ?? "";
  const header = req.headers.get("x-mati-bridge-secret")?.trim() ?? "";
  const [a, b] = await Promise.all([safeEqual(bearer, expected), safeEqual(header, expected)]);
  return a || b;
}

// ── Utilidades ──────────────────────────────────────────────────────────────

async function readJson(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) throw new HttpError(413, "Cuerpo demasiado grande");
  if (!text.trim()) return {};
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("no objeto");
    }
    return parsed as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "JSON inválido");
  }
}

function requireUuid(value: string, what = "id"): string {
  if (!UUID_RE.test(value)) throw new HttpError(400, `${what} inválido`);
  return value;
}

function str(value: unknown, field: string, max: number, required = false): string | null {
  if (value === undefined || value === null || value === "") {
    if (required) throw new HttpError(400, `${field} es obligatorio`);
    return null;
  }
  if (typeof value !== "string") throw new HttpError(400, `${field} debe ser texto`);
  const v = value.trim();
  if (required && !v) throw new HttpError(400, `${field} es obligatorio`);
  if (v.length > max) throw new HttpError(400, `${field} es demasiado largo (máx. ${max})`);
  return v || null;
}

const rolLegacy = (a: Area, n: Nivel): string => {
  if (a === "comercial") return n === "admin" ? "director_ventas" : n === "supervisor" ? "coordinador_ventas" : "ventas";
  if (a === "fabrica") return "fabrica";
  if (a === "almacen_logistica") return "logistica";
  if (a === "administracion") return n === "operador" ? "finanzas" : "admin_financiero";
  if (a === "compras") return "compras";
  return n === "admin" ? "admin" : "coordinador";
};

function parseAreaNivel(area: unknown, nivel: unknown): { area: Area; nivel: Nivel } {
  if (!AREAS.includes(area as Area) || !NIVELES.includes(nivel as Nivel)) {
    throw new HttpError(400, "area o nivel inválidos");
  }
  return { area: area as Area, nivel: nivel as Nivel };
}

/** Bitácora: nunca debe recibir contraseñas ni secretos. Si falla, no tumba la acción. */
async function audit(admin: Admin, accion: string, objetivo: string | null, detalle: Record<string, unknown> = {}) {
  try {
    const { error } = await admin
      .from("bridge_bitacora")
      .insert({ accion, objetivo, detalle: { ...detalle, actor: admin.actor ?? null } });
    if (error) console.error("bridge_bitacora:", error.message);
  } catch (e) {
    console.error("bridge_bitacora:", e instanceof Error ? e.message : String(e));
  }
}

// ── Usuarios ────────────────────────────────────────────────────────────────

const PROFILE_COLS = "id, email, nombre_completo, codigo_vendedor, activo";

async function listUsers(admin: Admin) {
  const [{ data: profiles, error: pErr }, { data: roles, error: rErr }] = await Promise.all([
    admin.from("profiles").select(PROFILE_COLS).order("nombre_completo"),
    admin.from("user_roles").select("user_id, area, nivel, role"),
  ]);
  if (pErr) throw new Error(pErr.message);
  if (rErr) throw new Error(rErr.message);
  const byUser = new Map((roles ?? []).map((r) => [r.user_id, r]));
  return (profiles ?? []).map((p) => {
    const r = byUser.get(p.id);
    return { ...p, area: r?.area ?? null, nivel: r?.nivel ?? null, role: r?.role ?? null };
  });
}

type UserRow = {
  id: string;
  email: string | null;
  nombre_completo: string | null;
  codigo_vendedor: string | null;
  activo: boolean;
  area: string | null;
  nivel: string | null;
  role: string | null;
};

async function getUser(admin: Admin, id: string): Promise<UserRow | null> {
  const { data: profile, error } = await admin.from("profiles").select(PROFILE_COLS).eq("id", id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!profile) return null;
  const { data: role } = await admin.from("user_roles").select("area, nivel, role").eq("user_id", id).maybeSingle();
  return { ...(profile as Omit<UserRow, "area" | "nivel" | "role">), area: role?.area ?? null, nivel: role?.nivel ?? null, role: role?.role ?? null };
}

/** Evita dejar el sistema sin ningún administrador global activo. */
async function assertNoSeQuedaSinAdmin(admin: Admin, userId: string) {
  const { data: roles, error } = await admin
    .from("user_roles")
    .select("user_id")
    .eq("area", "direccion")
    .eq("nivel", "admin");
  if (error) throw new Error(error.message);
  const ids = (roles ?? []).map((r) => r.user_id);
  if (!ids.includes(userId)) return; // no es admin global: no hay riesgo
  const { data: activos, error: aErr } = await admin.from("profiles").select("id").in("id", ids).eq("activo", true);
  if (aErr) throw new Error(aErr.message);
  const otros = (activos ?? []).filter((p) => p.id !== userId);
  if (otros.length === 0) {
    throw new HttpError(409, "No se puede: es el último administrador global activo", "LAST_GLOBAL_ADMIN");
  }
}

async function setRole(admin: Admin, userId: string, area: Area, nivel: Nivel) {
  const { error } = await admin
    .from("user_roles")
    .upsert({ user_id: userId, area, nivel, role: rolLegacy(area, nivel) }, { onConflict: "user_id" });
  if (error) throw new Error(error.message);
}

async function createUser(admin: Admin, body: Record<string, unknown>) {
  const email = (str(body.email, "email", 254, true) as string).toLowerCase();
  // La contraseña la genera el puente y viaja solo por correo; si el cliente manda una, se ignora.
  const nombre = str(body.nombre_completo, "nombre_completo", 120, true) as string;
  const codigo = str(body.codigo_vendedor, "codigo_vendedor", 40);
  const forzar = true; // siempre se exige cambiar la contraseña temporal al primer ingreso
  const { area, nivel } = parseAreaNivel(body.area, body.nivel);

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new HttpError(400, "email inválido");

  // Nunca pisa la contraseña de una cuenta que ya existe.
  const { data: existente } = await admin.from("profiles").select("id").ilike("email", email).maybeSingle();
  if (existente) throw new HttpError(409, "Ya existe un usuario con ese correo", "EMAIL_EXISTS");

  // El correo va PRIMERO: si no sale, no se crea nada y nadie queda con una cuenta sin forma de entrar.
  const password = generarPassword();
  const envio = await enviarAcceso(email, nombre, password, false);
  if (!envio.ok) throw new HttpError(424, MENSAJE_CORREO[envio.motivo], "CORREO_FALLO"); // 424: mati-api lo reenvía con su mensaje

  // El candado de la base solo deja pasar altas autorizadas (el registro público sigue cerrado).
  await autorizarAlta(admin, email);
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    // El flag de privilegio va en app_metadata (sólo Admin API); el front lo lee de ahí
    // y de profiles.debe_cambiar_password.
    app_metadata: { must_change_password: forzar, created_via_admin: true, managed_by: "mati-admin-bridge" },
    user_metadata: { full_name: nombre, must_change_password: false },
  });
  if (createErr || !created.user) {
    const msg = createErr?.message ?? "No se pudo crear el usuario";
    throw new HttpError(/already|registered|exists/i.test(msg) ? 409 : 400, msg);
  }
  const uid = created.user.id;

  try {
    const { error: profErr } = await admin.from("profiles").upsert({
      id: uid,
      email,
      nombre_completo: nombre,
      codigo_vendedor: codigo,
      activo: true,
      debe_cambiar_password: forzar,
    });
    if (profErr) throw new Error(profErr.message);
    await setRole(admin, uid, area, nivel);
  } catch (e) {
    // Sin perfil o sin rol la cuenta queda inservible: se deshace la alta.
    await admin.auth.admin.deleteUser(uid);
    throw new HttpError(500, `No se pudo completar el alta: ${e instanceof Error ? e.message : String(e)}`);
  }

  await audit(admin, "user.create", uid, { email, area, nivel, forzar_cambio_password: forzar, acceso_por_correo: true });
  return json({ user: await getUser(admin, uid), correo: { enviado: true } }, 201);
}

async function patchUser(admin: Admin, userId: string, body: Record<string, unknown>) {
  const current = await getUser(admin, userId);
  if (!current) throw new HttpError(404, "Usuario no encontrado");

  const patch: Record<string, unknown> = {};
  if (body.nombre_completo !== undefined) patch.nombre_completo = str(body.nombre_completo, "nombre_completo", 120, true);
  if (body.codigo_vendedor !== undefined) patch.codigo_vendedor = str(body.codigo_vendedor, "codigo_vendedor", 40);
  if (body.activo !== undefined) {
    if (typeof body.activo !== "boolean") throw new HttpError(400, "activo debe ser booleano");
    patch.activo = body.activo;
  }
  let nuevoEmail: string | null = null;
  if (body.email !== undefined) {
    nuevoEmail = (str(body.email, "email", 254, true) as string).toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(nuevoEmail)) throw new HttpError(400, "email inválido");
  }

  const cambiaRol = body.area !== undefined || body.nivel !== undefined;
  const destino = cambiaRol
    ? parseAreaNivel(body.area ?? current.area, body.nivel ?? current.nivel)
    : null;

  // Salvaguarda: no desactivar ni degradar al último admin global.
  const dejaDeSerAdminGlobal = destino && !(destino.area === "direccion" && destino.nivel === "admin");
  if (patch.activo === false || dejaDeSerAdminGlobal) await assertNoSeQuedaSinAdmin(admin, userId);

  if (nuevoEmail && nuevoEmail !== (current.email ?? "").toLowerCase()) {
    const { data: choque } = await admin.from("profiles").select("id").ilike("email", nuevoEmail).neq("id", userId).maybeSingle();
    if (choque) throw new HttpError(409, "Ya existe un usuario con ese correo", "EMAIL_EXISTS");
    // Primero Auth (si falla, no se toca el perfil): evita que auth.users y profiles se desfasen.
    const { error: authErr } = await admin.auth.admin.updateUserById(userId, { email: nuevoEmail, email_confirm: true });
    if (authErr) throw new HttpError(400, `No se pudo cambiar el correo: ${authErr.message}`);
    patch.email = nuevoEmail;
  }

  if (Object.keys(patch).length) {
    const { error } = await admin.from("profiles").update(patch).eq("id", userId);
    if (error) throw new HttpError(400, error.message);
  }
  if (destino) await setRole(admin, userId, destino.area, destino.nivel);

  await audit(admin, "user.update", userId, { campos: [...Object.keys(patch), ...(destino ? ["area", "nivel"] : [])], destino });
  return json({ user: await getUser(admin, userId) });
}

async function setActivo(admin: Admin, userId: string, activo: boolean) {
  const current = await getUser(admin, userId);
  if (!current) throw new HttpError(404, "Usuario no encontrado");
  if (!activo) await assertNoSeQuedaSinAdmin(admin, userId);
  const { error } = await admin.from("profiles").update({ activo }).eq("id", userId);
  if (error) throw new HttpError(400, error.message);
  await audit(admin, activo ? "user.activate" : "user.deactivate", userId, {});
  return json({ user: await getUser(admin, userId) });
}

async function resetPassword(admin: Admin, userId: string, body: Record<string, unknown>) {
  if (!(await getUser(admin, userId))) throw new HttpError(404, "Usuario no encontrado");
  const { data: target, error: tErr } = await admin.auth.admin.getUserById(userId);
  if (tErr || !target.user) throw new HttpError(404, "Usuario no encontrado");

  const email = target.user.email;
  if (!email) throw new HttpError(400, "La persona no tiene correo registrado");
  const nombre = ((target.user.user_metadata as Record<string, unknown> | undefined)?.full_name as string | undefined) || email;

  // Se genera aquí y viaja solo por correo. Si el correo no sale, NO se cambia la contraseña
  // (si no, la persona quedaría sin poder entrar y nadie conocería la nueva).
  const password = generarPassword();
  const envio = await enviarAcceso(email, nombre, password, true);
  if (!envio.ok) throw new HttpError(424, MENSAJE_CORREO[envio.motivo], "CORREO_FALLO"); // 424: mati-api lo reenvía con su mensaje

  const { error } = await admin.auth.admin.updateUserById(userId, {
    password,
    app_metadata: { ...(target.user.app_metadata || {}), must_change_password: true },
    user_metadata: { ...(target.user.user_metadata || {}), must_change_password: false },
  });
  if (error) throw new HttpError(400, error.message);
  const { error: pErr } = await admin.from("profiles").update({ debe_cambiar_password: true }).eq("id", userId);
  if (pErr) throw new HttpError(500, pErr.message);

  await audit(admin, "user.reset_password", userId, { acceso_por_correo: true });
  return json({ ok: true, user_id: userId, correo: { enviado: true } });
}

// ── Configuración ───────────────────────────────────────────────────────────

const CONFIG_INT_FIELDS = ["capacidad_diaria", "plazo_max_credito_dias", "limite_ya_armados"] as const;

async function patchConfig(admin: Admin, body: Record<string, unknown>) {
  const patch: Record<string, unknown> = {};
  if (body.empresa_nombre !== undefined) patch.empresa_nombre = str(body.empresa_nombre, "empresa_nombre", 120, true);
  for (const f of CONFIG_INT_FIELDS) {
    if (body[f] === undefined) continue;
    const n = body[f];
    if (typeof n !== "number" || !Number.isInteger(n) || n < 0 || n > 100000) {
      throw new HttpError(400, `${f} debe ser un entero entre 0 y 100000`);
    }
    patch[f] = n;
  }
  if (!Object.keys(patch).length) {
    throw new HttpError(400, `Ningún campo permitido. Usa: empresa_nombre, ${CONFIG_INT_FIELDS.join(", ")}`);
  }
  const { data, error } = await admin.from("config_general").update(patch).eq("id", 1).select("*").maybeSingle();
  if (error) throw new HttpError(400, error.message);
  await audit(admin, "config.update", "config_general", { campos: Object.keys(patch), valores: patch });
  return json({ config: data });
}

// ── Módulos ─────────────────────────────────────────────────────────────────

async function setModulo(admin: Admin, clave: string, body: Record<string, unknown>) {
  if (!MODULO_RE.test(clave)) throw new HttpError(400, "clave de módulo inválida");
  if (typeof body.activo !== "boolean") throw new HttpError(400, "activo debe ser booleano");

  const { data: mod, error } = await admin.from("app_modulos").select("clave, protegido, activo").eq("clave", clave).maybeSingle();
  if (error) throw new Error(error.message);
  if (!mod) throw new HttpError(404, "Módulo no encontrado");
  if (mod.protegido && body.activo === false) {
    throw new HttpError(409, "Ese módulo está protegido y no se puede apagar", "MODULE_PROTECTED");
  }

  const { data: updated, error: uErr } = await admin
    .from("app_modulos")
    .update({ activo: body.activo, actualizado_at: new Date().toISOString(), actualizado_por: "mati-admin" })
    .eq("clave", clave)
    .select("*")
    .maybeSingle();
  if (uErr) throw new HttpError(400, uErr.message);
  await audit(admin, body.activo ? "module.enable" : "module.disable", clave, { antes: mod.activo, despues: body.activo });
  return json({ modulo: updated });
}

// ── Soporte ─────────────────────────────────────────────────────────────────

async function listTickets(admin: Admin, url: URL) {
  const estado = url.searchParams.get("estado");
  const limitRaw = Number(url.searchParams.get("limit") ?? 50);
  const limit = Number.isInteger(limitRaw) ? Math.min(Math.max(limitRaw, 1), 200) : 50;
  let q = admin
    .from("soporte_tickets")
    .select("id, asunto, estado, prioridad, modulo, creado_por, creado_por_nombre, created_at, updated_at")
    .order("created_at", { ascending: false })
    .limit(limit);
  if (estado) {
    if (!TICKET_ESTADOS.includes(estado as (typeof TICKET_ESTADOS)[number])) throw new HttpError(400, "estado inválido");
    q = q.eq("estado", estado);
  }
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return json({ tickets: data ?? [] });
}

async function getTicket(admin: Admin, id: string) {
  const { data: ticket, error } = await admin.from("soporte_tickets").select("*").eq("id", id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!ticket) throw new HttpError(404, "Ticket no encontrado");
  const { data: mensajes, error: mErr } = await admin
    .from("soporte_mensajes")
    .select("id, autor_tipo, autor_nombre, mensaje, created_at")
    .eq("ticket_id", id)
    .order("created_at");
  if (mErr) throw new Error(mErr.message);
  return json({ ticket, mensajes: mensajes ?? [] });
}

async function patchTicket(admin: Admin, id: string, body: Record<string, unknown>) {
  const patch: Record<string, unknown> = {};
  if (body.estado !== undefined) {
    if (!TICKET_ESTADOS.includes(body.estado as (typeof TICKET_ESTADOS)[number])) throw new HttpError(400, "estado inválido");
    patch.estado = body.estado;
  }
  if (body.prioridad !== undefined) {
    if (!TICKET_PRIORIDADES.includes(body.prioridad as (typeof TICKET_PRIORIDADES)[number])) throw new HttpError(400, "prioridad inválida");
    patch.prioridad = body.prioridad;
  }
  if (!Object.keys(patch).length) throw new HttpError(400, "Nada que actualizar (estado, prioridad)");
  patch.updated_at = new Date().toISOString();
  const { data, error } = await admin.from("soporte_tickets").update(patch).eq("id", id).select("*").maybeSingle();
  if (error) throw new HttpError(400, error.message);
  if (!data) throw new HttpError(404, "Ticket no encontrado");
  await audit(admin, "ticket.update", id, patch);
  return json({ ticket: data });
}

async function addTicketMessage(admin: Admin, id: string, body: Record<string, unknown>) {
  const mensaje = str(body.mensaje, "mensaje", 5000, true) as string;
  const autor = str(body.autor_nombre, "autor_nombre", 120) ?? "Soporte MATI";
  const { data: ticket } = await admin.from("soporte_tickets").select("id").eq("id", id).maybeSingle();
  if (!ticket) throw new HttpError(404, "Ticket no encontrado");
  const { data, error } = await admin
    .from("soporte_mensajes")
    .insert({ ticket_id: id, autor_tipo: "soporte", autor_nombre: autor, mensaje })
    .select("id, autor_tipo, autor_nombre, mensaje, created_at")
    .single();
  if (error) throw new HttpError(400, error.message);
  await admin.from("soporte_tickets").update({ updated_at: new Date().toISOString() }).eq("id", id);
  await audit(admin, "ticket.reply", id, { autor });
  return json({ mensaje: data }, 201);
}

// ── Estado general ──────────────────────────────────────────────────────────

async function appStatus(admin: Admin) {
  const count = async (table: string, filter?: (q: any) => any) => {
    let q = admin.from(table).select("*", { count: "exact", head: true });
    if (filter) q = filter(q);
    const { count: c, error } = await q;
    if (error) throw new Error(error.message);
    return c ?? 0;
  };
  const [usuariosActivos, modulosActivos, modulosTotal, ticketsAbiertos] = await Promise.all([
    count("profiles", (q) => q.eq("activo", true)),
    count("app_modulos", (q) => q.eq("activo", true)),
    count("app_modulos"),
    count("soporte_tickets", (q) => q.in("estado", ["abierto", "en_progreso"])),
  ]);
  return json({
    system: "kit-to-drive",
    bridge: "v2",
    usuarios_activos: usuariosActivos,
    modulos: { activos: modulosActivos, total: modulosTotal },
    tickets_abiertos: ticketsAbiertos,
    timestamp: Date.now(),
  });
}

// ── Enrutado ────────────────────────────────────────────────────────────────

function relativePath(req: Request): string {
  const url = new URL(req.url);
  const marker = "/mati-admin-bridge";
  const idx = url.pathname.indexOf(marker);
  const rest = idx >= 0 ? url.pathname.slice(idx + marker.length) : url.pathname;
  return rest.replace(/\/+$/, "") || "/";
}

async function route(req: Request, admin: Admin): Promise<Response> {
  const url = new URL(req.url);
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
      bridge: "v2",
      areas: AREAS,
      niveles: NIVELES,
      ticket_estados: TICKET_ESTADOS,
      ticket_prioridades: TICKET_PRIORIDADES,
      app_ui: "https://kit-to-drive.vercel.app",
      modelo: "area × nivel (role legacy derivado)",
    });
  }
  if (method === "GET" && path === "/app/status") return await appStatus(admin);

  if (method === "GET" && path === "/users") return json({ users: await listUsers(admin) });
  if (method === "POST" && path === "/users") return await createUser(admin, await readJson(req));

  const userMatch = path.match(/^\/users\/([^/]+)(?:\/(activate|deactivate|reset-password))?$/);
  if (userMatch) {
    const userId = requireUuid(decodeURIComponent(userMatch[1]), "id de usuario");
    const action = userMatch[2];
    if (!action && method === "GET") {
      const user = await getUser(admin, userId);
      if (!user) throw new HttpError(404, "Usuario no encontrado");
      return json({ user });
    }
    if (!action && method === "PATCH") return await patchUser(admin, userId, await readJson(req));
    if (action === "activate" && method === "POST") return await setActivo(admin, userId, true);
    if (action === "deactivate" && method === "POST") return await setActivo(admin, userId, false);
    if (action === "reset-password" && method === "POST") return await resetPassword(admin, userId, await readJson(req));
  }

  if (method === "GET" && path === "/config") {
    const { data, error } = await admin.from("config_general").select("*").eq("id", 1).maybeSingle();
    if (error) throw new Error(error.message);
    return json({ config: data });
  }
  if (method === "PATCH" && path === "/config") return await patchConfig(admin, await readJson(req));

  if (method === "GET" && path === "/modules") {
    const { data, error } = await admin.from("app_modulos").select("*").order("nombre");
    if (error) throw new Error(error.message);
    return json({ modulos: data ?? [] });
  }
  const modMatch = path.match(/^\/modules\/([^/]+)$/);
  if (modMatch && method === "PUT") return await setModulo(admin, decodeURIComponent(modMatch[1]), await readJson(req));

  if (method === "GET" && path === "/tickets") return await listTickets(admin, url);
  const tkMatch = path.match(/^\/tickets\/([^/]+)(?:\/(messages))?$/);
  if (tkMatch) {
    const id = requireUuid(decodeURIComponent(tkMatch[1]), "id de ticket");
    if (!tkMatch[2] && method === "GET") return await getTicket(admin, id);
    if (!tkMatch[2] && method === "PATCH") return await patchTicket(admin, id, await readJson(req));
    if (tkMatch[2] === "messages" && method === "POST") return await addTicketMessage(admin, id, await readJson(req));
  }

  if (method === "GET" && path === "/audit") {
    const limitRaw = Number(url.searchParams.get("limit") ?? 50);
    const limit = Number.isInteger(limitRaw) ? Math.min(Math.max(limitRaw, 1), 200) : 50;
    const { data, error } = await admin.from("bridge_bitacora").select("*").order("at", { ascending: false }).limit(limit);
    if (error) throw new Error(error.message);
    return json({ bitacora: data ?? [] });
  }

  throw new HttpError(404, "Ruta no encontrada");
}

serve(async (req) => {
  // Servidor a servidor: sin CORS. Un navegador no debería poder llamar esto.
  if (req.method === "OPTIONS") return new Response(null, { status: 405 });

  try {
    const expected = Deno.env.get("MATI_ADMIN_BRIDGE_SECRET");
    if (!expected) {
      return json({ error: "Bridge no configurado: falta MATI_ADMIN_BRIDGE_SECRET", code: "BRIDGE_NOT_CONFIGURED" }, 503);
    }
    if (!(await secretOk(req, expected))) {
      console.warn("bridge: intento sin credencial válida", req.method, relativePath(req));
      return json({ error: "Unauthorized" }, 401);
    }
    // Quién pidió la acción desde MATI Admin (lo manda mati-api; sólo informativo).
    const actor = (req.headers.get("x-mati-actor") ?? "").trim().slice(0, 120) || null;
    return await route(req, Object.assign(adminClient(), { actor }));
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message, ...(err.code ? { code: err.code } : {}) }, err.status);
    console.error("bridge error:", err instanceof Error ? err.message : String(err));
    return json({ error: "Error interno" }, 500);
  }
});
