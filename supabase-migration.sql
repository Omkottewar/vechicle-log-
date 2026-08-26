-- ═══════════════════════════════════════════════════════════════════════════
--  VehicleLog — schema migration for the new entry form
--  Run this in Supabase → SQL Editor → New query → Run.
--  Safe to re-run: every statement is idempotent.
--
--  Nothing is deleted. The 9 fields dropped from the UI (owner_name,
--  gate_pass_number, transaction_type, weight, diesel, advance,
--  driver_amount, owner_amount) keep their columns and their data — the app
--  simply stops reading and writing them. See cleanup-old-columns.sql if you
--  ever decide to drop them for real.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1. Rename Godown Name → Warehouse (data preserved) ─────────────────────
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vehicle_transactions'
      and column_name = 'godown_name'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vehicle_transactions'
      and column_name = 'warehouse'
  ) then
    alter table public.vehicle_transactions rename column godown_name to warehouse;
  end if;
end $$;


-- ── 2. New columns ─────────────────────────────────────────────────────────
alter table public.vehicle_transactions
  add column if not exists warehouse    text,              -- no-op if renamed above
  add column if not exists party_name   text,              -- AS Logistics / Grace Logistics / Neeta Enterprises
  add column if not exists dispatch_in  text,              -- free-text place name
  add column if not exists lr_no        text,              -- lorry receipt no.
  add column if not exists quantity     numeric(14,3),
  add column if not exists unit         text,              -- canonical unit name, e.g. 'Kilogram'
  add column if not exists rate         numeric(14,2),     -- per-unit rate, OR the flat charge when ftl = true
  add column if not exists ftl          boolean not null default false,
  add column if not exists total_amount numeric(14,2);     -- ftl ? rate : quantity × rate (editable in the UI)


-- ── 3. Helpful indexes for the filters ─────────────────────────────────────
create index if not exists vt_date_idx       on public.vehicle_transactions (date desc);
create index if not exists vt_warehouse_idx  on public.vehicle_transactions (warehouse);
create index if not exists vt_party_idx      on public.vehicle_transactions (party_name);
create index if not exists vt_unit_idx       on public.vehicle_transactions (unit);
create index if not exists vt_lr_no_idx      on public.vehicle_transactions (lower(lr_no));


-- ── 4. Units registry ──────────────────────────────────────────────────────
-- Case / Box / Kg - Kilogram / Bundle are built into the app, so this table
-- only needs to hold the units you add yourself. Storing them here means a
-- unit added on one device shows up for everyone.
create table if not exists public.units (
  id         bigserial primary key,
  name       text not null,          -- proper-cased full name, e.g. 'Metric Ton'
  alias      text,                   -- short form shown first, e.g. 'MT'  →  "MT - Metric Ton"
  created_at timestamptz not null default now()
);

-- Case-insensitive uniqueness on the name.
create unique index if not exists units_name_lower_idx on public.units (lower(name));

alter table public.units enable row level security;

-- The app talks to Supabase with the anon key, so anon needs read + insert.
drop policy if exists "units_select_anon" on public.units;
create policy "units_select_anon" on public.units for select using (true);

drop policy if exists "units_insert_anon" on public.units;
create policy "units_insert_anon" on public.units for insert with check (true);


-- ── 5. Optional: backfill total_amount for any pre-existing rows ────────────
-- Old records have no quantity/rate, so this normally updates 0 rows.
-- Mirrors the UI rule: a full truck load is charged flat, everything else per unit.
update public.vehicle_transactions
   set total_amount = case when ftl then round(rate, 2)
                           else round(quantity * rate, 2) end
 where total_amount is null
   and rate is not null
   and (ftl or quantity is not null);
