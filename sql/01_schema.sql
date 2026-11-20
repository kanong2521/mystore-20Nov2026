-- =====================================================================
-- schema.sql : ฐานข้อมูลร้านยาจำลอง สำหรับข้อมูลชุดที่ตรวจและแก้ไขแล้ว
-- รันใน Supabase SQL Editor ได้ทั้งไฟล์ในครั้งเดียว และรันซ้ำได้ (ใช้เป็นตัว reset)
-- ลำดับการรัน: schema.sql -> seed.sql -> sell_drug.sql
--
-- เข้ากันได้กับไฟล์ของ workshop วันที่ 2:
--   - ชื่อตาราง app_config, drugs, stock, dispense_log และชื่อ constraint เดิม
--   - api/data.js, api/dispense.js และ sell_drug.sql ใช้ได้โดยไม่ต้องแก้
--   - คอลัมน์ใหม่อยู่ท้ายตารางและมีค่าเริ่มต้น คำสั่ง insert แบบไม่ระบุคอลัมน์ใน bad_inserts.sql จึงยังใช้ได้
--
-- ส่วนที่เพิ่มจากฉบับเดิม:
--   - stock.status            active / quarantine / written_off
--   - dispense_log.type       dispense / return / void และ legacy_id
--   - stock_adjustments       การปรับยอดคลังที่ไม่ใช่การจ่ายยา
--   - incidents               อุบัติการณ์ด้านความปลอดภัยผู้ป่วย
--   - dispense_pending        รายการจ่ายที่ยังเข้าตารางหลักไม่ได้ (รอตรวจหลักฐาน)
--   - change_log              บันทึกการแก้ไขข้อมูลทุกครั้ง
--   - view สำหรับ dashboard และ GRANT สำหรับ Data API
-- ข้อมูลทั้งหมดเป็นข้อมูลจำลองเพื่อการเรียนเท่านั้น
-- =====================================================================

-- ---------- 0) ลบของเดิม (รันซ้ำได้) ----------
drop view if exists public.v_stock_by_sku,
public.v_near_expiry,
public.v_expired_with_stock,
public.v_below_reorder,
public.v_dispensed_from_expired,
public.v_open_items cascade;

drop function if exists public.sell_drug (text, integer, text, text);

drop function if exists public._effective_as_of () cascade;

drop table if exists public.change_log cascade;

drop table if exists public.dispense_pending cascade;

drop table if exists public.incidents cascade;

drop table if exists public.stock_adjustments cascade;

drop table if exists public.dispense_log cascade;

drop table if exists public.stock cascade;

drop table if exists public.drugs cascade;

drop table if exists public.app_config cascade;

drop sequence if exists public.dispense_seq;

-- ---------- 1) วันอ้างอิงของระบบ (ค่าเริ่มต้นใช้วันจริง Asia/Bangkok และอัปเดตอัตโนมัติ) ----------
create table public.app_config (
    id int primary key check (id = 1),
    as_of date not null,
    auto_realtime boolean not null default true
);

insert into public.app_config (id, as_of, auto_realtime)
values (1, (now() at time zone 'Asia/Bangkok')::date, true);

create or replace function public._effective_as_of () returns date
language sql stable set search_path = public
as $$
  select case
    when c.auto_realtime then greatest(c.as_of, (now() at time zone 'Asia/Bangkok')::date)
    else c.as_of
  end
  from public.app_config c
  where c.id = 1
$$;

-- ---------- 2) บัญชียา ----------
create table public.drugs (
    sku text primary key,
    generic_name text not null,
    strength text not null,
    dosage_form text not null,
    unit text not null,
    category text not null,
    atc_code text not null,
    reorder_level integer not null,
    constraint drugs_reorder_nonneg check (reorder_level >= 0)
);

-- ---------- 3) คลังรายล็อต ----------
-- expiry อนุญาตให้ว่างได้เฉพาะล็อตที่กักไว้ (quarantine) เช่น S022 ที่ยังไม่รู้วันหมดอายุ
-- และล็อตที่กักไว้ได้รับการยกเว้นกฎวันหมดอายุหลังวันรับเข้า เช่น S007 ที่รอตรวจฉลาก
create table public.stock (
    stock_id text primary key,
    sku text not null,
    lot text not null,
    received_date date not null,
    expiry date,
    qty_on_hand integer not null,
    unit_cost numeric(10, 2) not null,
    status text not null default 'active',
    constraint stock_sku_fk foreign key (sku) references public.drugs (sku),
    constraint stock_sku_lot_unique unique (sku, lot),
    constraint stock_qty_nonneg check (qty_on_hand >= 0),
    constraint stock_cost_positive check (unit_cost > 0),
    constraint stock_status_valid check (
        status in (
            'active',
            'quarantine',
            'written_off'
        )
    ),
    constraint stock_expiry_required check (
        expiry is not null
        or status = 'quarantine'
    ),
    constraint stock_expiry_after_recv check (
        expiry > received_date
        or status = 'quarantine'
    ),
    constraint stock_writeoff_empty check (
        status <> 'written_off'
        or qty_on_hand = 0
    )
);

create index stock_expiry_idx on public.stock (expiry);

-- ---------- 4) การจ่ายยา ----------
-- qty ต้องมากกว่า 0 ยกเว้นรายการที่ยกเลิก (void) ซึ่งเก็บค่าเดิมไว้เป็นหลักฐาน เช่น D0030 (0) และ D0093 (-10)
create table public.dispense_log (
    dispense_id text primary key,
    datetime timestamp not null,
    sku text not null,
    lot text not null,
    qty integer not null,
    patient_code text not null,
    pharmacist_code text not null,
    type text not null default 'dispense',
    legacy_id text,
    constraint dispense_qty_positive check (
        qty > 0
        or type = 'void'
    ),
    constraint dispense_type_valid check (
        type in ('dispense', 'return', 'void')
    ),
    constraint dispense_stock_fk foreign key (sku, lot) references public.stock (sku, lot)
);

create index dispense_sku_lot_idx on public.dispense_log (sku, lot);

create index dispense_datetime_idx on public.dispense_log (datetime);

-- เลขที่ใบจ่ายยาถัดไป (seed.sql ตั้งค่าต่อจากเลขสูงสุดที่มี)
create sequence public.dispense_seq start 1;

-- ---------- 5) การปรับยอดคลัง ----------
-- qty_change ว่างได้เฉพาะรายการที่ยังรอตรวจ (เช่น ADJ-003 รอนับยอดจริง)
create table public.stock_adjustments (
    adjustment_id text primary key,
    adj_date date not null,
    stock_id text not null references public.stock (stock_id),
    qty_change integer,
    reason text not null,
    value numeric(10, 2),
    status text not null,
    note text,
    constraint adj_status_valid check (
        status in ('completed', 'pending_review')
    ),
    constraint adj_qty_required check (
        qty_change is not null
        or status = 'pending_review'
    )
);

-- ---------- 6) อุบัติการณ์ ----------
-- อ้างไปยังรายการจ่ายทางเดียว (ไม่เก็บ incident_ref ใน dispense_log เพื่อไม่ให้อ้างกันเป็นวง)
create table public.incidents (
    incident_id text primary key,
    date_reported date not null,
    type text not null,
    dispense_id text not null references public.dispense_log (dispense_id),
    lot_expiry date,
    status text not null default 'open',
    actions_required text [] not null default '{}',
    constraint incident_status_valid check (status in ('open', 'closed'))
);

-- ---------- 7) รายการจ่ายที่รอตรวจหลักฐาน ----------
-- แถวที่ยังผ่าน constraint ของ dispense_log ไม่ได้ เก็บข้อมูลดิบไว้ครบ ไม่ทิ้ง
--   D0045: sku AMLO5 กับล็อต LS2505 ไม่ตรงกัน (ขัด dispense_stock_fk)
--   D0120: qty 2.5 ไม่ใช่จำนวนเต็ม
create table public.dispense_pending (
    dispense_id text primary key,
    raw jsonb not null,
    reason text not null,
    status text not null default 'pending_review'
);

-- ---------- 8) บันทึกการแก้ไข ----------
create table public.change_log (
    log_id bigint generated always as identity primary key,
    file text not null,
    record_id text not null,
    field text not null,
    old_value jsonb,
    new_value jsonb,
    reason text not null,
    severity smallint check (severity between 1 and 4),
    status text not null,
    changed_by text not null,
    changed_on date not null
);

-- ---------- 9) View สำหรับ dashboard ----------
-- security_invoker ทำให้ view เคารพ RLS ของผู้เรียก (ต้องใช้ PostgreSQL 15 ขึ้นไป)

-- ยอดใช้ได้ต่อ sku: เฉพาะล็อต active ที่ยังไม่หมดอายุ ณ _effective_as_of()
create view public.v_stock_by_sku
with (security_invoker = true) as
select
    d.sku,
    d.generic_name,
    d.strength,
    d.reorder_level,
    coalesce(
        sum(s.qty_on_hand) filter (
            where
                s.status = 'active'
                and s.expiry >= c.eff_as_of
        ),
        0
    )::int as usable_qty,
    coalesce(
        sum(s.qty_on_hand) filter (
            where
                s.status = 'quarantine'
        ),
        0
    )::int as quarantine_qty
from public.drugs d
    join public.stock s on s.sku = d.sku
    cross join (select public._effective_as_of() as eff_as_of) c
group by
    d.sku,
    d.generic_name,
    d.strength,
    d.reorder_level;

create view public.v_below_reorder
with (security_invoker = true) as
select *
from public.v_stock_by_sku
where
    usable_qty < reorder_level;

create view public.v_near_expiry
with (security_invoker = true) as
select s.stock_id, s.sku, s.lot, s.expiry, s.qty_on_hand, (s.expiry - c.eff_as_of) as days_left
from public.stock s
    cross join (select public._effective_as_of() as eff_as_of) c
where
    s.status = 'active'
    and s.qty_on_hand > 0
    and s.expiry between c.eff_as_of and c.eff_as_of + 90;

-- ล็อตหมดอายุที่ยังมีของ (รวมล็อตที่กักไว้ เพื่อให้เห็นมูลค่าที่เสี่ยง)
create view public.v_expired_with_stock
with (security_invoker = true) as
select s.stock_id, s.sku, s.lot, s.expiry, s.qty_on_hand, s.status, s.qty_on_hand * s.unit_cost as value
from public.stock s
    cross join (select public._effective_as_of() as eff_as_of) c
where
    s.qty_on_hand > 0
    and s.expiry < c.eff_as_of;

-- การจ่ายจากล็อตที่หมดอายุแล้ว ณ วันจ่าย (เป็นข้อมูลจริง ห้ามมี constraint ปฏิเสธ)
create view public.v_dispensed_from_expired
with (security_invoker = true) as
select l.dispense_id, l.datetime, l.sku, l.lot, l.qty, s.expiry, i.incident_id
from public.dispense_log l
    join public.stock s on s.sku = l.sku
    and s.lot = l.lot
    left join public.incidents i on i.dispense_id = l.dispense_id
where
    l.type = 'dispense'
    and l.datetime::date > s.expiry;

-- งานที่ยังค้าง รวมจากทุกตาราง
create view public.v_open_items
with (security_invoker = true) as
select
    'stock' as source,
    stock_id as record_id,
    'ล็อตถูกกักไว้ รอตรวจฉลาก' as detail
from public.stock
where
    status = 'quarantine'
union all
select 'dispense_pending', dispense_id, reason
from public.dispense_pending
where
    status = 'pending_review'
union all
select 'stock_adjustments', adjustment_id, note
from public.stock_adjustments
where
    status = 'pending_review'
union all
select 'incidents', incident_id, type
from public.incidents
where
    status = 'open';

-- ---------- 10) สิทธิ์ (GRANT) ----------
-- โปรเจกต์ Supabase ใหม่ต้องให้สิทธิ์ใน Postgres ชัดเจน Data API จึงจะเห็นตาราง
grant usage on schema public to anon, authenticated, service_role;

grant select on all tables in schema public to anon, authenticated;

grant all on all tables in schema public to service_role;

grant usage, select on sequence public.dispense_seq to service_role;

grant execute on function public._effective_as_of () to anon, authenticated, service_role;

-- ---------- 11) Row Level Security: key สิทธิ์ต่ำอ่านได้อย่างเดียว ----------
alter table public.app_config enable row level security;

alter table public.drugs enable row level security;

alter table public.stock enable row level security;

alter table public.dispense_log enable row level security;

alter table public.stock_adjustments enable row level security;

alter table public.incidents enable row level security;

alter table public.dispense_pending enable row level security;

alter table public.change_log enable row level security;

create policy read_app_config on public.app_config for
select to anon, authenticated using (true);

create policy read_drugs on public.drugs for
select to anon, authenticated using (true);

create policy read_stock on public.stock for
select to anon, authenticated using (true);

create policy read_dispense_log on public.dispense_log for
select to anon, authenticated using (true);

create policy read_stock_adjustments on public.stock_adjustments for
select to anon, authenticated using (true);

create policy read_incidents on public.incidents for
select to anon, authenticated using (true);

create policy read_dispense_pending on public.dispense_pending for
select to anon, authenticated using (true);

create policy read_change_log on public.change_log for
select to anon, authenticated using (true);