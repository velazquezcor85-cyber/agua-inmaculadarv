-- =====================================================================
-- AGUA INMACULADA · APP DE CONTROL · FASE 1 (PLANTA + PANEL DE DUEÑOS)
-- Ejecutar completo en Supabase > SQL Editor
-- =====================================================================

-- ---------- PERFILES Y ROLES ----------
create table if not exists public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  rol text not null default 'ventanilla' check (rol in ('dueno','ventanilla','repartidor')),
  activo boolean not null default false,
  creado_en timestamptz not null default now()
);

create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from public.perfiles where id = auth.uid() and activo
$$;

create or replace function public.es_dueno() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol = 'dueno' from public.perfiles where id = auth.uid() and activo), false)
$$;

-- Crear perfil automáticamente al dar de alta un usuario
create or replace function public.nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (id, nombre, rol, activo)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email, '@', 1)),
          'ventanilla', false)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists trg_nuevo_usuario on auth.users;
create trigger trg_nuevo_usuario after insert on auth.users
for each row execute function public.nuevo_usuario();

-- ---------- CONFIGURACIÓN ----------
create table if not exists public.config (
  clave text primary key,
  valor numeric,
  texto text,
  descripcion text
);

insert into public.config (clave, valor, descripcion) values
  ('caja_chica_planta', 350, 'Fondo de caja chica de planta (pesos)'),
  ('caja_chica_moto', 250, 'Fondo de caja chica del repartidor en moto (pesos)'),
  ('meta_diaria_garrafones', 83, 'Meta diaria de garrafones (2,500 al mes)'),
  ('costo_pipa', 1700, 'Costo por pipa (pesos)'),
  ('litros_pipa', 10000, 'Litros por pipa'),
  ('tolerancia_litros', 40, 'Diferencia de litros permitida por turno antes de marcar alerta'),
  ('tolerancia_caja', 10, 'Diferencia de caja permitida (pesos) antes de marcar alerta')
on conflict (clave) do nothing;

insert into public.config (clave, texto, descripcion) values
  ('medidor_unidad', 'litros', 'Unidad del medidor de agua: litros o m3')
on conflict (clave) do nothing;

-- ---------- INVENTARIO: ARTÍCULOS ----------
create table if not exists public.articulos (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  tipo text not null check (tipo in ('insumo','garrafon','hielo','limpieza','sanitizacion','equipo')),
  unidad text not null default 'pieza',
  existencia numeric not null default 0,
  minimo numeric not null default 0,
  costo_unitario numeric not null default 0,
  marca text, modelo text, numero_serie text,
  fecha_compra date, valor_compra numeric,
  notas text,
  activo boolean not null default true
);

insert into public.articulos (nombre, tipo, unidad, minimo, costo_unitario, notas) values
  ('Tapa', 'insumo', 'pieza', 500, 0.51, 'Tapa rosca R56, bolsa de 1,000 a 513.90'),
  ('Liner', 'insumo', 'pieza', 500, 0.09, 'Liner, bolsa de 500'),
  ('Sello de garantía', 'insumo', 'pieza', 500, 0.17, 'Sello térmico, paquete de 1,000'),
  ('Garrafón nuevo (envase)', 'garrafon', 'pieza', 10, 78.50, 'Garrafón diamante 19-20 L'),
  ('Hielo grande', 'hielo', 'bolsa', 5, 0, 'Capturar costo de compra'),
  ('Hielo chico', 'hielo', 'bolsa', 5, 0, 'Capturar costo de compra')
on conflict (nombre) do nothing;

-- ---------- PRODUCTOS DE VENTA ----------
create table if not exists public.productos (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  precio numeric not null,
  precio_domicilio numeric,
  litros_producto numeric not null default 0,   -- litros que salen del medidor
  litros_consumo numeric not null default 0,    -- litros de pipa incluyendo rechazo
  cuenta_garrafon boolean not null default false,
  iva_tasa numeric not null default 0,
  costo_extra numeric not null default 0,       -- costo adicional por unidad (ej. minerales alcalina)
  orden int not null default 0,
  color text default '#1BA6C9',
  activo boolean not null default true
);

insert into public.productos (nombre, precio, precio_domicilio, litros_producto, litros_consumo, cuenta_garrafon, iva_tasa, orden, color) values
  ('Relleno garrafón', 23, 28, 20, 22, true, 0, 1, '#1BA6C9'),
  ('Garrafón nuevo', 150, 150, 20, 22, true, 0, 2, '#E85A9B'),
  ('Agua alcalina', 53, 57, 20, 25, true, 0, 3, '#2E7D5B'),
  ('Hielo grande', 38, 38, 0, 0, false, 0.16, 4, '#5C6BC0'),
  ('Hielo chico', 28, 28, 0, 0, false, 0.16, 5, '#7986CB')
on conflict (nombre) do nothing;

-- Qué artículos descuenta cada producto vendido
create table if not exists public.producto_insumos (
  producto_id bigint references public.productos(id) on delete cascade,
  articulo_id bigint references public.articulos(id) on delete cascade,
  cantidad numeric not null default 1,
  primary key (producto_id, articulo_id)
);

insert into public.producto_insumos (producto_id, articulo_id, cantidad)
select p.id, a.id, 1 from public.productos p, public.articulos a
where (p.nombre in ('Relleno garrafón','Garrafón nuevo','Agua alcalina') and a.nombre in ('Tapa','Liner','Sello de garantía'))
   or (p.nombre = 'Garrafón nuevo' and a.nombre = 'Garrafón nuevo (envase)')
   or (p.nombre = 'Hielo grande' and a.nombre = 'Hielo grande')
   or (p.nombre = 'Hielo chico' and a.nombre = 'Hielo chico')
on conflict do nothing;

-- ---------- CLIENTES (con datos fiscales) ----------
create table if not exists public.clientes (
  id bigint generated always as identity primary key,
  tipo text not null default 'domicilio' check (tipo in ('domicilio','empresa','restaurante','distribuidor')),
  nombre text not null,
  telefono text,
  domicilio text,
  maps_url text,
  precio_especial numeric,          -- solo lo autoriza el dueño
  rfc text, razon_social text, regimen_fiscal text, cp_fiscal text,
  uso_cfdi text, correo_factura text, constancia_path text,
  garrafones_prestados int not null default 0,
  notas text,
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

-- ---------- TURNOS (apertura / cierre / arqueo) ----------
create table if not exists public.turnos (
  id bigint generated always as identity primary key,
  usuario_id uuid not null references public.perfiles(id) default auth.uid(),
  tipo text not null default 'planta' check (tipo in ('planta','camioneta','moto')),
  abierto_en timestamptz not null default now(),
  cerrado_en timestamptz,
  caja_inicial numeric not null,
  caja_inicial_ok boolean not null default true,
  medidor_inicial numeric,
  medidor_final numeric,
  foto_medidor_ini text, foto_medidor_fin text, foto_caja_fin text,
  garrafones_nuevos_ini int, garrafones_nuevos_fin int,
  -- calculados al cierre
  efectivo_contado numeric,
  efectivo_esperado numeric,
  diferencia_caja numeric,
  ventas_efectivo numeric, ventas_transferencia numeric,
  gastos_caja numeric,
  litros_medidor numeric, litros_vendidos numeric, diferencia_litros numeric,
  garrafones_vendidos int, garrafones_nuevos_vendidos int, diferencia_garrafones_nuevos int,
  notas_apertura text, notas_cierre text,
  estado text not null default 'abierto' check (estado in ('abierto','cerrado'))
);

create unique index if not exists un_turno_abierto_por_usuario
  on public.turnos (usuario_id) where estado = 'abierto';

-- ---------- VENTAS ----------
create table if not exists public.ventas (
  id bigint generated always as identity primary key,
  turno_id bigint not null references public.turnos(id),
  usuario_id uuid not null references public.perfiles(id) default auth.uid(),
  cliente_id bigint references public.clientes(id),
  canal text not null default 'planta' check (canal in ('planta','domicilio','empresa','repartidor')),
  fecha timestamptz not null default now(),
  forma_pago text not null check (forma_pago in ('efectivo','transferencia','credito')),
  total numeric not null default 0,
  cancelada boolean not null default false,
  cancelada_por uuid references public.perfiles(id),
  cancelada_en timestamptz,
  motivo_cancelacion text,
  facturada boolean not null default false,
  folio_factura text
);

create table if not exists public.venta_detalle (
  id bigint generated always as identity primary key,
  venta_id bigint not null references public.ventas(id) on delete cascade,
  producto_id bigint not null references public.productos(id),
  cantidad numeric not null check (cantidad > 0),
  precio_unitario numeric not null,
  importe numeric not null,
  litros_producto numeric not null default 0,
  litros_consumo numeric not null default 0,
  iva_tasa numeric not null default 0
);

-- ---------- PIPAS ----------
create table if not exists public.pipas (
  id bigint generated always as identity primary key,
  fecha timestamptz not null default now(),
  litros numeric not null,
  costo numeric not null,
  proveedor text,
  turno_id bigint references public.turnos(id),
  usuario_id uuid references public.perfiles(id) default auth.uid(),
  foto text,
  notas text
);

-- ---------- COMPRAS Y SALIDAS DE CAJA ----------
create table if not exists public.gastos (
  id bigint generated always as identity primary key,
  fecha timestamptz not null default now(),
  categoria text not null check (categoria in ('insumo','limpieza','sanitizacion','garrafon','hielo','mantenimiento','otro')),
  articulo_id bigint references public.articulos(id),
  descripcion text not null,
  cantidad numeric,
  monto numeric not null,
  proveedor text,
  con_factura boolean not null default false,
  pagado_de_caja boolean not null default false,
  turno_id bigint references public.turnos(id),
  usuario_id uuid references public.perfiles(id) default auth.uid(),
  foto text
);

-- ---------- MOVIMIENTOS DE INVENTARIO ----------
create table if not exists public.movimientos (
  id bigint generated always as identity primary key,
  fecha timestamptz not null default now(),
  articulo_id bigint not null references public.articulos(id),
  tipo text not null check (tipo in ('entrada','salida','ajuste','merma')),
  cantidad numeric not null,      -- positivo; el tipo indica si suma o resta (ajuste = existencia nueva)
  motivo text,
  venta_id bigint references public.ventas(id) on delete set null,
  gasto_id bigint references public.gastos(id) on delete set null,
  turno_id bigint references public.turnos(id),
  usuario_id uuid references public.perfiles(id) default auth.uid()
);

create or replace function public.aplicar_movimiento() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tipo = 'entrada' then
    update articulos set existencia = existencia + new.cantidad where id = new.articulo_id;
  elsif new.tipo in ('salida','merma') then
    update articulos set existencia = existencia - new.cantidad where id = new.articulo_id;
  elsif new.tipo = 'ajuste' then
    update articulos set existencia = new.cantidad where id = new.articulo_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_aplicar_movimiento on public.movimientos;
create trigger trg_aplicar_movimiento after insert on public.movimientos
for each row execute function public.aplicar_movimiento();

-- Compras con artículo → entrada a inventario y costo actualizado
create or replace function public.gasto_a_inventario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.articulo_id is not null and coalesce(new.cantidad,0) > 0 then
    insert into movimientos (articulo_id, tipo, cantidad, motivo, gasto_id, turno_id, usuario_id)
    values (new.articulo_id, 'entrada', new.cantidad, 'Compra: ' || new.descripcion, new.id, new.turno_id, new.usuario_id);
    update articulos set costo_unitario = round(new.monto / new.cantidad, 4) where id = new.articulo_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_gasto_inventario on public.gastos;
create trigger trg_gasto_inventario after insert on public.gastos
for each row execute function public.gasto_a_inventario();

-- ---------- GASTOS FIJOS (para utilidad real) ----------
create table if not exists public.gastos_fijos (
  id bigint generated always as identity primary key,
  concepto text not null,
  monto_mensual numeric not null,
  categoria text not null default 'operacion' check (categoria in ('operacion','personal','reparto','deuda','franquicia','otro')),
  dia_pago text,
  activo boolean not null default true
);

insert into public.gastos_fijos (concepto, monto_mensual, categoria, dia_pago)
select * from (values
  ('Renta de planta', 6750::numeric, 'operacion', 'Del 1 al 5'),
  ('Luz (promedio mensual)', 492, 'operacion', 'Bimestral día 10'),
  ('Sueldo Yara', 6400, 'personal', 'Semanal'),
  ('Sueldo Norma', 6400, 'personal', 'Semanal'),
  ('Sueldo Javier', 13000, 'reparto', 'Semanal (3,000)'),
  ('Camioneta (mensualidad)', 12645.75, 'reparto', 'Día 15'),
  ('Gasolina camioneta', 3200, 'reparto', 'Mensual'),
  ('Gasolina moto', 1400, 'reparto', 'Mensual'),
  ('Mecánico', 700, 'reparto', 'Mensual'),
  ('Franquicia (anualidad 13,000)', 1083.33, 'franquicia', 'Anual'),
  ('Impuestos', 44, 'otro', 'Mensual')
) v(concepto, monto, cat, dia)
where not exists (select 1 from public.gastos_fijos);

-- ---------- BITÁCORA SANITARIA Y MANTENIMIENTO ----------
create table if not exists public.bitacora (
  id bigint generated always as identity primary key,
  fecha timestamptz not null default now(),
  tipo text not null check (tipo in ('sanitaria','mantenimiento','merma_garrafon','incidencia')),
  actividad text not null,
  cantidad numeric,
  usuario_id uuid references public.perfiles(id) default auth.uid(),
  foto text,
  notas text
);

create table if not exists public.mantenimientos (
  id bigint generated always as identity primary key,
  actividad text not null,
  cada_dias int not null,
  ultima_fecha date,
  costo_aprox numeric,
  activo boolean not null default true
);

insert into public.mantenimientos (actividad, cada_dias)
select * from (values
  ('Cambio de membranas de ósmosis', 365),
  ('Cambio de filtros de sedimento', 60),
  ('Cambio de carbón activado', 180),
  ('Cambio de lámpara UV', 365),
  ('Análisis de laboratorio del agua', 180),
  ('Lavado y sanitización de tinacos', 90)
) v(a, d)
where not exists (select 1 from public.mantenimientos);
