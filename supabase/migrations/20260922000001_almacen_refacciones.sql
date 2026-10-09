-- ============================================================================
-- Almacén de refacciones para venta (lista de precios DAZON)
-- ----------------------------------------------------------------------------
-- Catálogo normalizado: código nuevo (canónico) + código antiguo, descripción
-- separada de compatibilidades con unidades/motos, stock y precio.
-- Visibilidad restringida por allowlist (Polo + Martín y quien se agregue).
-- Tabla de movimientos lista para análisis de ventas por compatibilidad.
-- Re-ejecutable / idempotente.
-- ============================================================================

-- Acceso al módulo (solo correos / usuarios autorizados) ---------------------
CREATE TABLE IF NOT EXISTS public.almacen_refacciones_acceso (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  nombre TEXT,
  activo BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT almacen_refacciones_acceso_email_unico UNIQUE (email)
);

CREATE INDEX IF NOT EXISTS idx_almacen_refacciones_acceso_email
  ON public.almacen_refacciones_acceso (lower(email));
CREATE INDEX IF NOT EXISTS idx_almacen_refacciones_acceso_user
  ON public.almacen_refacciones_acceso (user_id)
  WHERE user_id IS NOT NULL;

ALTER TABLE public.almacen_refacciones_acceso ENABLE ROW LEVEL SECURITY;

-- Catálogo de unidades / motos compatibles ----------------------------------
CREATE TABLE IF NOT EXISTS public.almacen_refacciones_unidades (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre TEXT NOT NULL,
  nombre_normalizado TEXT NOT NULL,
  tipo_unidad TEXT, -- motoneta | trabajo | motocarro | atv | universal | otro
  marca_familia TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT almacen_refacciones_unidades_norm_unico UNIQUE (nombre_normalizado)
);

ALTER TABLE public.almacen_refacciones_unidades ENABLE ROW LEVEL SECURITY;

-- Productos (código nuevo es la identidad canónica) -------------------------
CREATE TABLE IF NOT EXISTS public.almacen_refacciones_productos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo_nuevo TEXT NOT NULL,
  codigo_antiguo TEXT,
  clave_completa TEXT NOT NULL,
  clave_simplificada TEXT,
  linea_catalogo TEXT NOT NULL, -- linea_dorada | ref_motocarro | linea_azul
  marca TEXT,
  categoria TEXT,
  descripcion TEXT NOT NULL,
  descripcion_corta TEXT,
  unidad_medida TEXT,
  piezas_por_caja TEXT,
  precio NUMERIC(12, 2),
  stock INTEGER NOT NULL DEFAULT 0,
  visible_venta BOOLEAN NOT NULL DEFAULT true,
  no_lista INTEGER,
  fuente_archivo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT almacen_refacciones_productos_codigo_nuevo_unico UNIQUE (codigo_nuevo)
);

CREATE INDEX IF NOT EXISTS idx_almacen_ref_prod_antiguo
  ON public.almacen_refacciones_productos (codigo_antiguo)
  WHERE codigo_antiguo IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_almacen_ref_prod_linea
  ON public.almacen_refacciones_productos (linea_catalogo);
CREATE INDEX IF NOT EXISTS idx_almacen_ref_prod_marca
  ON public.almacen_refacciones_productos (marca);
CREATE INDEX IF NOT EXISTS idx_almacen_ref_prod_categoria
  ON public.almacen_refacciones_productos (categoria);
CREATE INDEX IF NOT EXISTS idx_almacen_ref_prod_visible
  ON public.almacen_refacciones_productos (visible_venta);
CREATE INDEX IF NOT EXISTS idx_almacen_ref_prod_busqueda
  ON public.almacen_refacciones_productos
  USING gin (
    to_tsvector(
      'simple',
      coalesce(codigo_nuevo, '') || ' ' ||
      coalesce(codigo_antiguo, '') || ' ' ||
      coalesce(descripcion, '') || ' ' ||
      coalesce(categoria, '') || ' ' ||
      coalesce(marca, '')
    )
  );

ALTER TABLE public.almacen_refacciones_productos ENABLE ROW LEVEL SECURITY;

-- Todos los códigos que apuntan a un producto (nuevo, antiguo, alias) -------
CREATE TABLE IF NOT EXISTS public.almacen_refacciones_codigos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  producto_id UUID NOT NULL REFERENCES public.almacen_refacciones_productos(id) ON DELETE CASCADE,
  codigo TEXT NOT NULL,
  tipo TEXT NOT NULL CHECK (tipo IN ('nuevo', 'antiguo', 'alias')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT almacen_refacciones_codigos_codigo_unico UNIQUE (codigo)
);

CREATE INDEX IF NOT EXISTS idx_almacen_ref_codigos_producto
  ON public.almacen_refacciones_codigos (producto_id);

ALTER TABLE public.almacen_refacciones_codigos ENABLE ROW LEVEL SECURITY;

-- Compatibilidad producto ↔ unidad -----------------------------------------
CREATE TABLE IF NOT EXISTS public.almacen_refacciones_producto_compat (
  producto_id UUID NOT NULL REFERENCES public.almacen_refacciones_productos(id) ON DELETE CASCADE,
  unidad_id UUID NOT NULL REFERENCES public.almacen_refacciones_unidades(id) ON DELETE CASCADE,
  texto_origen TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (producto_id, unidad_id)
);

CREATE INDEX IF NOT EXISTS idx_almacen_ref_compat_unidad
  ON public.almacen_refacciones_producto_compat (unidad_id);

ALTER TABLE public.almacen_refacciones_producto_compat ENABLE ROW LEVEL SECURITY;

-- Movimientos (base para análisis: qué compatibilidad compran más) ----------
CREATE TABLE IF NOT EXISTS public.almacen_refacciones_movimientos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  producto_id UUID NOT NULL REFERENCES public.almacen_refacciones_productos(id),
  tipo TEXT NOT NULL CHECK (tipo IN ('venta', 'entrada', 'ajuste', 'salida')),
  cantidad INTEGER NOT NULL CHECK (cantidad <> 0),
  precio_unitario NUMERIC(12, 2),
  unidad_compatible_id UUID REFERENCES public.almacen_refacciones_unidades(id),
  cliente_id UUID REFERENCES public.clientes(id) ON DELETE SET NULL,
  notas TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_almacen_ref_mov_producto
  ON public.almacen_refacciones_movimientos (producto_id);
CREATE INDEX IF NOT EXISTS idx_almacen_ref_mov_unidad
  ON public.almacen_refacciones_movimientos (unidad_compatible_id)
  WHERE unidad_compatible_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_almacen_ref_mov_tipo_fecha
  ON public.almacen_refacciones_movimientos (tipo, created_at DESC);

ALTER TABLE public.almacen_refacciones_movimientos ENABLE ROW LEVEL SECURITY;

-- Triggers updated_at -------------------------------------------------------
DROP TRIGGER IF EXISTS trg_almacen_ref_acceso_updated ON public.almacen_refacciones_acceso;
CREATE TRIGGER trg_almacen_ref_acceso_updated
  BEFORE UPDATE ON public.almacen_refacciones_acceso
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_almacen_ref_prod_updated ON public.almacen_refacciones_productos;
CREATE TRIGGER trg_almacen_ref_prod_updated
  BEFORE UPDATE ON public.almacen_refacciones_productos
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ¿El usuario actual puede ver/usar el módulo? ------------------------------
CREATE OR REPLACE FUNCTION public.puede_ver_almacen_refacciones(_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.almacen_refacciones_acceso a
    WHERE a.activo
      AND (
        a.user_id = _user_id
        OR lower(a.email) = lower(coalesce(
          (SELECT email FROM auth.users WHERE id = _user_id),
          ''
        ))
      )
  );
$$;

REVOKE ALL ON FUNCTION public.puede_ver_almacen_refacciones(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.puede_ver_almacen_refacciones(UUID) TO authenticated;

-- RLS: sólo allowlist -------------------------------------------------------
DROP POLICY IF EXISTS "ref_acceso_leer" ON public.almacen_refacciones_acceso;
CREATE POLICY "ref_acceso_leer" ON public.almacen_refacciones_acceso
  FOR SELECT TO authenticated
  USING (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_acceso_escribir" ON public.almacen_refacciones_acceso;
CREATE POLICY "ref_acceso_escribir" ON public.almacen_refacciones_acceso
  FOR ALL TO authenticated
  USING (public.puede_ver_almacen_refacciones())
  WITH CHECK (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_unidades_leer" ON public.almacen_refacciones_unidades;
CREATE POLICY "ref_unidades_leer" ON public.almacen_refacciones_unidades
  FOR SELECT TO authenticated
  USING (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_unidades_escribir" ON public.almacen_refacciones_unidades;
CREATE POLICY "ref_unidades_escribir" ON public.almacen_refacciones_unidades
  FOR ALL TO authenticated
  USING (public.puede_ver_almacen_refacciones())
  WITH CHECK (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_prod_leer" ON public.almacen_refacciones_productos;
CREATE POLICY "ref_prod_leer" ON public.almacen_refacciones_productos
  FOR SELECT TO authenticated
  USING (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_prod_escribir" ON public.almacen_refacciones_productos;
CREATE POLICY "ref_prod_escribir" ON public.almacen_refacciones_productos
  FOR ALL TO authenticated
  USING (public.puede_ver_almacen_refacciones())
  WITH CHECK (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_codigos_leer" ON public.almacen_refacciones_codigos;
CREATE POLICY "ref_codigos_leer" ON public.almacen_refacciones_codigos
  FOR SELECT TO authenticated
  USING (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_codigos_escribir" ON public.almacen_refacciones_codigos;
CREATE POLICY "ref_codigos_escribir" ON public.almacen_refacciones_codigos
  FOR ALL TO authenticated
  USING (public.puede_ver_almacen_refacciones())
  WITH CHECK (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_compat_leer" ON public.almacen_refacciones_producto_compat;
CREATE POLICY "ref_compat_leer" ON public.almacen_refacciones_producto_compat
  FOR SELECT TO authenticated
  USING (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_compat_escribir" ON public.almacen_refacciones_producto_compat;
CREATE POLICY "ref_compat_escribir" ON public.almacen_refacciones_producto_compat
  FOR ALL TO authenticated
  USING (public.puede_ver_almacen_refacciones())
  WITH CHECK (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_mov_leer" ON public.almacen_refacciones_movimientos;
CREATE POLICY "ref_mov_leer" ON public.almacen_refacciones_movimientos
  FOR SELECT TO authenticated
  USING (public.puede_ver_almacen_refacciones());

DROP POLICY IF EXISTS "ref_mov_escribir" ON public.almacen_refacciones_movimientos;
CREATE POLICY "ref_mov_escribir" ON public.almacen_refacciones_movimientos
  FOR INSERT TO authenticated
  WITH CHECK (public.puede_ver_almacen_refacciones());

-- Vista de consulta con conteo de compatibilidades --------------------------
CREATE OR REPLACE VIEW public.v_almacen_refacciones
WITH (security_invoker = true) AS
SELECT
  p.id,
  p.codigo_nuevo,
  p.codigo_antiguo,
  p.clave_completa,
  p.clave_simplificada,
  p.linea_catalogo,
  p.marca,
  p.categoria,
  p.descripcion,
  p.descripcion_corta,
  p.unidad_medida,
  p.piezas_por_caja,
  p.precio,
  p.stock,
  p.visible_venta,
  p.no_lista,
  p.fuente_archivo,
  p.created_at,
  p.updated_at,
  coalesce(c.num_compat, 0)::INTEGER AS num_compatibilidades
FROM public.almacen_refacciones_productos p
LEFT JOIN (
  SELECT producto_id, count(*)::INTEGER AS num_compat
  FROM public.almacen_refacciones_producto_compat
  GROUP BY producto_id
) c ON c.producto_id = p.id;

GRANT SELECT ON public.v_almacen_refacciones TO authenticated;

-- Importación / upsert masivo desde lista de precios ------------------------
CREATE OR REPLACE FUNCTION public.importar_almacen_refacciones(_items JSONB)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item JSONB;
  prod_id UUID;
  v_codigo_nuevo TEXT;
  v_codigo_antiguo TEXT;
  v_clave TEXT;
  compat JSONB;
  unidad_txt TEXT;
  unidad_norm TEXT;
  unidad_id UUID;
  procesados INTEGER := 0;
  compat_count INTEGER := 0;
  codigos_count INTEGER := 0;
BEGIN
  IF coalesce(auth.role(), '') = 'anon' THEN
    RAISE EXCEPTION 'Sin acceso al almacén de refacciones';
  END IF;
  IF auth.uid() IS NOT NULL AND NOT public.puede_ver_almacen_refacciones() THEN
    RAISE EXCEPTION 'Sin acceso al almacén de refacciones';
  END IF;

  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' THEN
    RAISE EXCEPTION 'Se espera un arreglo JSON de productos';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(_items)
  LOOP
    v_codigo_nuevo := nullif(trim(item->>'codigo_nuevo'), '');
    IF v_codigo_nuevo IS NULL THEN
      CONTINUE;
    END IF;
    v_codigo_antiguo := nullif(trim(item->>'codigo_antiguo'), '');
    v_clave := coalesce(nullif(trim(item->>'clave_completa'), ''), v_codigo_nuevo);

    INSERT INTO public.almacen_refacciones_productos (
      codigo_nuevo, codigo_antiguo, clave_completa, clave_simplificada,
      linea_catalogo, marca, categoria, descripcion, descripcion_corta,
      unidad_medida, piezas_por_caja, precio, stock, visible_venta,
      no_lista, fuente_archivo
    ) VALUES (
      v_codigo_nuevo,
      v_codigo_antiguo,
      v_clave,
      nullif(trim(item->>'clave_simplificada'), ''),
      coalesce(nullif(trim(item->>'linea_catalogo'), ''), 'linea_dorada'),
      nullif(trim(item->>'marca'), ''),
      nullif(trim(item->>'categoria'), ''),
      coalesce(nullif(trim(item->>'descripcion'), ''), v_codigo_nuevo),
      nullif(trim(item->>'descripcion_corta'), ''),
      nullif(trim(item->>'unidad_medida'), ''),
      nullif(trim(item->>'piezas_por_caja'), ''),
      NULLIF(item->>'precio', '')::NUMERIC,
      coalesce(NULLIF(item->>'stock', '')::INTEGER, 0),
      coalesce((item->>'visible_venta')::BOOLEAN, true),
      NULLIF(item->>'no_lista', '')::INTEGER,
      nullif(trim(item->>'fuente_archivo'), '')
    )
    ON CONFLICT (codigo_nuevo) DO UPDATE SET
      codigo_antiguo = EXCLUDED.codigo_antiguo,
      clave_completa = EXCLUDED.clave_completa,
      clave_simplificada = EXCLUDED.clave_simplificada,
      linea_catalogo = EXCLUDED.linea_catalogo,
      marca = EXCLUDED.marca,
      categoria = EXCLUDED.categoria,
      descripcion = EXCLUDED.descripcion,
      descripcion_corta = EXCLUDED.descripcion_corta,
      unidad_medida = EXCLUDED.unidad_medida,
      piezas_por_caja = EXCLUDED.piezas_por_caja,
      precio = EXCLUDED.precio,
      stock = EXCLUDED.stock,
      visible_venta = EXCLUDED.visible_venta,
      no_lista = EXCLUDED.no_lista,
      fuente_archivo = EXCLUDED.fuente_archivo,
      updated_at = now()
    RETURNING id INTO prod_id;

    INSERT INTO public.almacen_refacciones_codigos (producto_id, codigo, tipo)
    VALUES (prod_id, v_codigo_nuevo, 'nuevo')
    ON CONFLICT (codigo) DO UPDATE SET
      producto_id = EXCLUDED.producto_id,
      tipo = 'nuevo';
    codigos_count := codigos_count + 1;

    IF v_codigo_antiguo IS NOT NULL AND v_codigo_antiguo <> v_codigo_nuevo THEN
      -- No sobrescribe un código que ya es "nuevo" canónico de otro producto.
      INSERT INTO public.almacen_refacciones_codigos (producto_id, codigo, tipo)
      VALUES (prod_id, v_codigo_antiguo, 'antiguo')
      ON CONFLICT (codigo) DO UPDATE SET
        producto_id = EXCLUDED.producto_id,
        tipo = 'antiguo'
      WHERE public.almacen_refacciones_codigos.tipo <> 'nuevo';
      codigos_count := codigos_count + 1;
    END IF;

    DELETE FROM public.almacen_refacciones_producto_compat WHERE producto_id = prod_id;

    compat := item->'compatibilidades';
    IF compat IS NOT NULL AND jsonb_typeof(compat) = 'array' THEN
      FOR unidad_txt IN
        SELECT nullif(trim(value), '')
        FROM jsonb_array_elements_text(compat) AS t(value)
      LOOP
        IF unidad_txt IS NULL THEN CONTINUE; END IF;
        unidad_norm := lower(regexp_replace(unidad_txt, '\s+', ' ', 'g'));

        INSERT INTO public.almacen_refacciones_unidades (nombre, nombre_normalizado, tipo_unidad, marca_familia)
        VALUES (
          unidad_txt,
          unidad_norm,
          nullif(trim(item->>'tipo_unidad_sugerido'), ''),
          nullif(trim(item->>'marca'), '')
        )
        ON CONFLICT (nombre_normalizado) DO UPDATE SET
          nombre = EXCLUDED.nombre;

        SELECT id INTO unidad_id
        FROM public.almacen_refacciones_unidades
        WHERE nombre_normalizado = unidad_norm;

        INSERT INTO public.almacen_refacciones_producto_compat (producto_id, unidad_id, texto_origen)
        VALUES (prod_id, unidad_id, unidad_txt)
        ON CONFLICT DO NOTHING;
        compat_count := compat_count + 1;
      END LOOP;
    END IF;

    procesados := procesados + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'procesados', procesados,
    'codigos', codigos_count,
    'compatibilidades', compat_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.importar_almacen_refacciones(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.importar_almacen_refacciones(JSONB) TO authenticated;

-- Allowlist inicial: Polo (dueño) + hueco listo para Martín ------------------
INSERT INTO public.almacen_refacciones_acceso (email, nombre, user_id, activo)
SELECT 'leo.bassoco@yoltik.mx', 'Polo Bassoco', u.id, true
FROM auth.users u WHERE lower(u.email) = 'leo.bassoco@yoltik.mx'
ON CONFLICT (email) DO UPDATE SET
  user_id = EXCLUDED.user_id,
  nombre = EXCLUDED.nombre,
  activo = true;

INSERT INTO public.almacen_refacciones_acceso (email, nombre, user_id, activo)
SELECT 'leo.bassoco@kawiil.mx', 'Polo Bassoco', u.id, true
FROM auth.users u WHERE lower(u.email) = 'leo.bassoco@kawiil.mx'
ON CONFLICT (email) DO UPDATE SET
  user_id = COALESCE(EXCLUDED.user_id, public.almacen_refacciones_acceso.user_id),
  nombre = EXCLUDED.nombre,
  activo = true;

-- Si kawiil no tiene usuario aún, dejar el correo listo
INSERT INTO public.almacen_refacciones_acceso (email, nombre, activo)
VALUES ('leo.bassoco@kawiil.mx', 'Polo Bassoco', true)
ON CONFLICT (email) DO NOTHING;

INSERT INTO public.almacen_refacciones_acceso (email, nombre, activo)
VALUES ('martin@dazon.demo', 'Martín (pendiente de alta)', true)
ON CONFLICT (email) DO UPDATE SET nombre = EXCLUDED.nombre, activo = true;

-- Si ya existe algún usuario Martín, enlazarlo
UPDATE public.almacen_refacciones_acceso a
SET user_id = u.id,
    email = u.email,
    nombre = coalesce(a.nombre, p.nombre_completo, 'Martín')
FROM auth.users u
LEFT JOIN public.profiles p ON p.id = u.id
WHERE a.email IN ('martin@dazon.demo', 'martin@dazon.com')
  AND (
    lower(u.email) LIKE 'martin%@%'
    OR lower(coalesce(p.nombre_completo, '')) LIKE '%mart%n%'
  )
  AND a.user_id IS DISTINCT FROM u.id;
