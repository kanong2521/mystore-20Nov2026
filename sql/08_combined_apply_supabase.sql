-- =====================================================================
-- 08_combined_apply_supabase.sql
-- สคริปต์รวม 06_realtime_date_sync.sql + 07_staff_users.sql สำหรับวางรันครั้งเดียวใน Supabase SQL Editor
-- ปลอดภัยต่อข้อมูลเดิม (Non-destructive) และรันซ้ำได้ (Idempotent)
-- =====================================================================

begin;

-- =====================================================================
-- 06_realtime_date_sync.sql : อัปเดตฐานข้อมูลเดิมให้ใช้วันเวลาจริง (Asia/Bangkok) แบบไม่ทำลายข้อมูล
-- รันใน Supabase SQL Editor ได้ทั้งไฟล์ และรันซ้ำได้ (Idempotent)
--
-- สิ่งที่สคริปต์นี้ทำ:
--   1. เพิ่มคอลัมน์ app_config.auto_realtime (ค่าเริ่มต้น true) และตั้ง app_config.as_of = วันปัจจุบัน BKK
--   2. สร้าง/อัปเดต public._effective_as_of() คืนวันที่อ้างอิงที่ทันสมัยเสมอเมื่อ auto_realtime = true
--   3. อัปเดต view ทั้ง 4 ตัว (v_stock_by_sku, v_near_expiry, v_expired_with_stock, v_drug_catalog)
--      ให้คำนวณวันหมดอายุเทียบ _effective_as_of() (security_invoker = true + สิทธิ์ SELECT ครบ)
--   4. อัปเดตฟังก์ชัน sell_drug, stock_receive, stock_set_status, dispense_return, config_set_as_of
--      ให้ใช้วันเวลาจริง Asia/Bangkok และคงสิทธิ์ execute เฉพาะ service_role เท่านั้น
--   5. ซ่อมวันที่ของรายการหลัง seed (ตั้งแต่ D0151 เช่น D0151, D0152, D0153) ที่ค้างเป็น 2026-11-02
--      ให้เป็นวันปัจจุบัน พร้อมคงเวลาเดิมและบันทึกประวัติลง change_log
-- =====================================================================

-- 1) เพิ่มคอลัมน์ auto_realtime และอัปเดต app_config.as_of เป็นวันจริง (Asia/Bangkok)
alter table public.app_config add column if not exists auto_realtime boolean not null default true;
alter table public.drugs add column if not exists is_active boolean not null default true;

update public.app_config
   set as_of = (now() at time zone 'Asia/Bangkok')::date,
       auto_realtime = true
 where id = 1;

-- 2) ฟังก์ชันช่วยวันอ้างอิงจริงและตัวช่วยพื้นฐาน
create or replace function public._today_bkk() returns date
language sql stable set search_path = public
as $$ select (now() at time zone 'Asia/Bangkok')::date $$;

create or replace function public._effective_as_of() returns date
language sql stable set search_path = public
as $$
  select case
    when c.auto_realtime then greatest(c.as_of, (now() at time zone 'Asia/Bangkok')::date)
    else c.as_of
  end
  from public.app_config c
  where c.id = 1
$$;
grant execute on function public._effective_as_of() to anon, authenticated, service_role;

create or replace function public._require_by(p_by text) returns text
language plpgsql set search_path = public
as $$
begin
  if coalesce(trim(p_by), '') = '' then
    raise exception 'ต้องระบุรหัสเภสัชกรผู้บันทึก';
  end if;
  return upper(trim(p_by));
end $$;

create or replace function public._log(
  p_table text, p_record text, p_field text, p_old jsonb, p_new jsonb,
  p_reason text, p_by text, p_severity smallint default 3, p_status text default 'แก้แล้ว'
) returns void
language sql set search_path = public
as $$
  insert into change_log (file, record_id, field, old_value, new_value, reason,
                          severity, status, changed_by, changed_on)
  values (p_table, p_record, p_field, p_old, p_new, p_reason,
          p_severity, p_status, p_by, _today_bkk());
$$;

-- 3) อัปเดต view ทั้ง 4 ตัวให้เทียบวันหมดอายุกับ _effective_as_of()
create or replace view public.v_stock_by_sku with (security_invoker = true) as
select
    d.sku,
    d.generic_name,
    d.strength,
    d.reorder_level,
    coalesce(
        sum(s.qty_on_hand) filter (
            where s.status = 'active' and s.expiry >= c.eff_as_of
        ), 0
    )::int as usable_qty,
    coalesce(
        sum(s.qty_on_hand) filter (where s.status = 'quarantine'), 0
    )::int as quarantine_qty
from public.drugs d
join public.stock s on s.sku = d.sku
cross join (select public._effective_as_of() as eff_as_of) c
group by d.sku, d.generic_name, d.strength, d.reorder_level;

create or replace view public.v_near_expiry with (security_invoker = true) as
select s.stock_id, s.sku, s.lot, s.expiry, s.qty_on_hand, (s.expiry - c.eff_as_of) as days_left
from public.stock s
cross join (select public._effective_as_of() as eff_as_of) c
where s.status = 'active'
  and s.qty_on_hand > 0
  and s.expiry between c.eff_as_of and c.eff_as_of + 90;

create or replace view public.v_expired_with_stock with (security_invoker = true) as
select s.stock_id, s.sku, s.lot, s.expiry, s.qty_on_hand, s.status, s.qty_on_hand * s.unit_cost as value
from public.stock s
cross join (select public._effective_as_of() as eff_as_of) c
where s.qty_on_hand > 0
  and s.expiry < c.eff_as_of;

create or replace view public.v_drug_catalog with (security_invoker = true) as
select d.*,
       count(s.stock_id)::int as lot_count,
       coalesce(sum(s.qty_on_hand) filter (
         where s.status = 'active' and s.expiry >= c.eff_as_of), 0)::int as usable_qty,
       coalesce(sum(s.qty_on_hand) filter (where s.status = 'quarantine'), 0)::int as quarantine_qty
from public.drugs d
left join public.stock s on s.sku = d.sku
cross join (select public._effective_as_of() as eff_as_of) c
group by d.sku;

grant select on public.v_stock_by_sku, public.v_near_expiry, public.v_expired_with_stock, public.v_drug_catalog to anon, authenticated;
grant all on public.v_stock_by_sku, public.v_near_expiry, public.v_expired_with_stock, public.v_drug_catalog to service_role;

-- 4) อัปเดต sell_drug() ให้บันทึกวันเวลาจริงและตรวจวันหมดอายุเทียบ _effective_as_of()
create or replace function public.sell_drug(
  p_sku             text,
  p_qty             integer,
  p_patient_code    text,
  p_pharmacist_code text
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_as_of  date;
  v_now    timestamp;
  v_usable integer;
  v_need   integer;
  v_take   integer;
  v_lot    record;
  v_id     text;
  v_lines  jsonb := '[]'::jsonb;
begin
  if p_qty is null or p_qty <= 0 then
    raise exception 'จำนวนต้องเป็นจำนวนเต็มมากกว่า 0';
  end if;
  if coalesce(trim(p_patient_code), '') = '' or coalesce(trim(p_pharmacist_code), '') = '' then
    raise exception 'ต้องระบุรหัสผู้ป่วยและรหัสเภสัชกร';
  end if;
  if not exists (select 1 from drugs where sku = p_sku) then
    raise exception 'ไม่พบรหัสยา %', p_sku;
  end if;

  v_now := date_trunc('second', now() at time zone 'Asia/Bangkok');
  v_as_of := coalesce(public._effective_as_of(), v_now::date);

  -- ล็อกล็อตที่ใช้ได้ของยาตัวนี้ กันสองคนขายพร้อมกัน
  perform 1 from stock
   where sku = p_sku and status = 'active' and expiry >= v_as_of and qty_on_hand > 0
   order by expiry, stock_id
   for update;

  select coalesce(sum(qty_on_hand), 0) into v_usable
    from stock
   where sku = p_sku and status = 'active' and expiry >= v_as_of and qty_on_hand > 0;

  if v_usable = 0 then
    raise exception 'ไม่มียาที่ใช้ได้ (ไม่มีล็อตที่ยังไม่หมดอายุและมีของ) รหัสยา %', p_sku;
  end if;
  if v_usable < p_qty then
    raise exception 'ยอดใช้ได้ไม่พอ ต้องการ % แต่มี %', p_qty, v_usable;
  end if;

  v_need := p_qty;
  for v_lot in
    select stock_id, lot, qty_on_hand from stock
     where sku = p_sku and status = 'active' and expiry >= v_as_of and qty_on_hand > 0
     order by expiry, stock_id
  loop
    exit when v_need = 0;
    v_take := least(v_need, v_lot.qty_on_hand);

    update stock set qty_on_hand = qty_on_hand - v_take
     where stock_id = v_lot.stock_id;

    v_id := 'D' || lpad(nextval('dispense_seq')::text, 4, '0');
    insert into dispense_log
      (dispense_id, datetime, sku, lot, qty, patient_code, pharmacist_code)
    values
      (v_id, v_now, p_sku, v_lot.lot, v_take, upper(trim(p_patient_code)), upper(trim(p_pharmacist_code)));

    v_lines := v_lines || jsonb_build_object('dispense_id', v_id, 'lot', v_lot.lot, 'qty', v_take);
    v_need := v_need - v_take;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'lines', v_lines,
    'usable_before', v_usable,
    'usable_after', v_usable - p_qty
  );
end;
$$;

-- 5) อัปเดต stock_receive, stock_set_status, dispense_return และ config_set_as_of
create or replace function public.stock_receive(
  p_sku text, p_lot text, p_received_date date, p_expiry date,
  p_qty integer, p_unit_cost numeric, p_by text
) returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by    text := _require_by(p_by);
  v_as_of date;
  v_act   boolean;
  v_id    text;
  v_row   stock;
begin
  v_as_of := coalesce(public._effective_as_of(), _today_bkk());
  select is_active into v_act from drugs where sku = p_sku;
  if not found then raise exception 'ไม่พบรหัสยา %', p_sku; end if;
  if not v_act then raise exception 'ยา % ถูกปิดใช้งาน เปิดใช้งานก่อนรับเข้า', p_sku; end if;
  if coalesce(trim(p_lot), '') = '' then raise exception 'ต้องระบุเลขล็อต'; end if;
  if p_received_date is null or p_expiry is null then raise exception 'ต้องระบุวันรับเข้าและวันหมดอายุ'; end if;
  if p_received_date > v_as_of then
    raise exception 'วันรับเข้า % อยู่หลังวันอ้างอิงของระบบ %', p_received_date, v_as_of;
  end if;
  if p_expiry <= p_received_date then raise exception 'วันหมดอายุต้องอยู่หลังวันรับเข้า'; end if;
  if p_expiry < v_as_of then raise exception 'ล็อตนี้หมดอายุแล้ว ณ % ไม่รับเข้าเป็นของจ่ายได้', v_as_of; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'จำนวนรับเข้าต้องเป็นจำนวนเต็มมากกว่า 0'; end if;
  if p_unit_cost is null or p_unit_cost <= 0 then raise exception 'ราคาทุนต่อหน่วยต้องมากกว่า 0'; end if;
  if exists (select 1 from stock where sku = p_sku and lot = upper(trim(p_lot))) then
    raise exception 'ล็อต % ของยา % มีอยู่แล้ว ใช้การปรับยอดแทนการรับซ้ำ', upper(trim(p_lot)), p_sku;
  end if;

  v_id := 'S' || lpad(nextval('stock_seq')::text, 3, '0');
  insert into stock (stock_id, sku, lot, received_date, expiry, qty_on_hand, unit_cost, status)
  values (v_id, p_sku, upper(trim(p_lot)), p_received_date, p_expiry, p_qty, p_unit_cost, 'active')
  returning * into v_row;

  perform _log('stock', v_id, '(ทั้งรายการ)', null, to_jsonb(v_row), 'รับยาเข้าล็อตใหม่', v_by);
  return jsonb_build_object('ok', true, 'stock', to_jsonb(v_row));
end $$;

create or replace function public.stock_set_status(p_stock_id text, p_status text, p_reason text, p_by text)
returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by    text := _require_by(p_by);
  v_as_of date;
  v_old   stock;
  v_adj   text;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'ต้องระบุเหตุผล'; end if;
  if p_status not in ('active', 'quarantine', 'written_off') then
    raise exception 'สถานะ % ไม่ถูกต้อง', p_status;
  end if;
  v_as_of := coalesce(public._effective_as_of(), _today_bkk());
  select * into v_old from stock where stock_id = p_stock_id for update;
  if not found then raise exception 'ไม่พบล็อต %', p_stock_id; end if;
  if v_old.status = p_status then raise exception 'ล็อต % เป็น % อยู่แล้ว', p_stock_id, p_status; end if;
  if v_old.status = 'written_off' then raise exception 'ล็อตที่ตัดจำหน่ายแล้วเปลี่ยนสถานะไม่ได้'; end if;

  if p_status = 'active' then
    if v_old.expiry is null then
      raise exception 'ล็อต % ยังไม่มีวันหมดอายุ แก้ตามฉลากก่อนปล่อยใช้', p_stock_id;
    end if;
    if v_old.expiry <= v_old.received_date then
      raise exception 'วันหมดอายุ % อยู่ก่อนวันรับเข้า % ตรวจฉลากและแก้ก่อนปล่อยใช้',
        v_old.expiry, v_old.received_date;
    end if;
    if v_old.expiry < v_as_of then
      raise exception 'ล็อต % หมดอายุแล้ว (%) ปล่อยใช้ไม่ได้ ให้ตัดจำหน่าย', p_stock_id, v_old.expiry;
    end if;
  end if;

  if p_status = 'written_off' and v_old.qty_on_hand > 0 then
    v_adj := 'ADJ-' || lpad(nextval('adj_seq')::text, 3, '0');
    insert into stock_adjustments (adjustment_id, adj_date, stock_id, qty_change, reason, value, status, note)
    values (v_adj, _today_bkk(), p_stock_id, -v_old.qty_on_hand, 'writeoff',
            v_old.qty_on_hand * v_old.unit_cost, 'completed', trim(p_reason));
    update stock set qty_on_hand = 0 where stock_id = p_stock_id;
    perform _log('stock', p_stock_id, 'qty_on_hand', to_jsonb(v_old.qty_on_hand), '0'::jsonb,
                 'ตัดจำหน่าย อ้างอิง ' || v_adj, v_by, 1::smallint);
  end if;

  update stock set status = p_status where stock_id = p_stock_id;
  perform _log('stock', p_stock_id, 'status', to_jsonb(v_old.status), to_jsonb(p_status),
               trim(p_reason), v_by, 1::smallint);
  return jsonb_build_object('ok', true, 'stock_id', p_stock_id, 'status', p_status, 'adjustment_id', v_adj);
end $$;

create or replace function public.dispense_return(p_dispense_id text, p_qty integer, p_reason text, p_by text)
returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by    text := _require_by(p_by);
  v_as_of date;
  v_now   timestamp;
  v_orig  dispense_log;
  v_lot   stock;
  v_done  int;
  v_id    text;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'ต้องระบุเหตุผลที่คืน'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'จำนวนคืนต้องเป็นจำนวนเต็มมากกว่า 0'; end if;
  v_now := date_trunc('second', now() at time zone 'Asia/Bangkok');
  v_as_of := coalesce(public._effective_as_of(), v_now::date);

  select * into v_orig from dispense_log where dispense_id = p_dispense_id for update;
  if not found then raise exception 'ไม่พบรายการจ่าย %', p_dispense_id; end if;
  if v_orig.type <> 'dispense' then raise exception 'รายการ % ไม่ใช่การจ่ายยา (%)', p_dispense_id, v_orig.type; end if;

  select coalesce(sum(qty), 0) into v_done from dispense_log
   where ref_dispense_id = p_dispense_id and type = 'return';
  if v_done + p_qty > v_orig.qty then
    raise exception 'คืนเกินจำนวนที่จ่าย จ่ายไป % คืนแล้ว % คืนได้อีกไม่เกิน %',
      v_orig.qty, v_done, v_orig.qty - v_done;
  end if;

  select * into v_lot from stock where sku = v_orig.sku and lot = v_orig.lot for update;
  if v_lot.status <> 'active' then
    raise exception 'ล็อต % อยู่ในสถานะ % คืนเข้าล็อตเดิมไม่ได้ ติดต่อผู้ดูแล', v_lot.lot, v_lot.status;
  end if;
  if v_lot.expiry < v_as_of then
    raise exception 'ล็อต % หมดอายุแล้ว (%) ไม่รับคืนเข้าชั้นจ่าย', v_lot.lot, v_lot.expiry;
  end if;

  update stock set qty_on_hand = qty_on_hand + p_qty where stock_id = v_lot.stock_id;
  v_id := 'D' || lpad(nextval('dispense_seq')::text, 4, '0');
  insert into dispense_log (dispense_id, datetime, sku, lot, qty, patient_code, pharmacist_code, type, ref_dispense_id)
  values (v_id, v_now, v_orig.sku, v_orig.lot, p_qty, v_orig.patient_code, v_by, 'return', p_dispense_id);

  perform _log('dispense_log', v_id, '(ทั้งรายการ)', null,
               jsonb_build_object('type', 'return', 'ref', p_dispense_id, 'qty', p_qty),
               trim(p_reason), v_by, 2::smallint);
  return jsonb_build_object('ok', true, 'dispense_id', v_id, 'ref_dispense_id', p_dispense_id,
                            'qty', p_qty, 'returnable_left', v_orig.qty - v_done - p_qty);
end $$;

create or replace function public.config_set_as_of(p_as_of date, p_by text) returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by   text := _require_by(p_by);
  v_old  date;
  v_auto boolean := (p_as_of = _today_bkk());
begin
  if p_as_of is null then raise exception 'ต้องระบุวันที่'; end if;
  select as_of into v_old from app_config where id = 1 for update;
  update app_config set as_of = p_as_of, auto_realtime = v_auto where id = 1;
  perform _log('app_config', '1', 'as_of', to_jsonb(v_old), to_jsonb(p_as_of),
               case when v_auto then 'ปรับวันอ้างอิงเป็นวันปัจจุบัน (เปิดโหมดอัปเดตวันจริงอัตโนมัติ)'
                    else 'กำหนดวันอ้างอิงของระบบแบบคงที่' end, v_by);
  return jsonb_build_object('ok', true, 'as_of', p_as_of, 'auto_realtime', v_auto);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public._today_bkk()',
    'public._require_by(text)',
    'public._log(text, text, text, jsonb, jsonb, text, text, smallint, text)',
    'public.sell_drug(text, integer, text, text)',
    'public.stock_receive(text, text, date, date, integer, numeric, text)',
    'public.stock_set_status(text, text, text, text)',
    'public.dispense_return(text, integer, text, text)',
    'public.config_set_as_of(date, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- 6) ซ่อมวันที่ของรายการหลัง seed (ตั้งแต่ D0151 เช่น D0151, D0152, D0153) ที่บันทึกค้างเป็น 2026-11-02
do $$
declare
  r        record;
  v_today  date := (now() at time zone 'Asia/Bangkok')::date;
  v_new_dt timestamp;
begin
  for r in
    select dispense_id, datetime
      from public.dispense_log
     where dispense_id ~ '^D[0-9]+$'
       and substring(dispense_id from 2)::int >= 151
       and datetime::date = date '2026-11-02'
     order by substring(dispense_id from 2)::int
  loop
    v_new_dt := v_today + r.datetime::time;
    update public.dispense_log set datetime = v_new_dt where dispense_id = r.dispense_id;
    perform public._log(
      'dispense_log',
      r.dispense_id,
      'datetime',
      to_jsonb(r.datetime),
      to_jsonb(v_new_dt),
      'ปรับแก้ log ที่บันทึกวันอ้างอิงเดิม (2026-11-02) ให้ตรงวันจริง ' || to_char(v_today, 'YYYY-MM-DD'),
      'SYSTEM',
      3::smallint
    );
  end loop;
end $$;

-- =====================================================================
-- 07_staff_users.sql : ทะเบียนผู้ปฏิบัติงาน (รหัสเภสัชกร / ผู้ช่วย / ผู้ดูแล) และฟังก์ชันจัดการสิทธิ์
-- รันใน Supabase SQL Editor ได้ทั้งไฟล์ และรันซ้ำได้ (Idempotent / ไม่ทำลายข้อมูลเดิม)
-- ต้องมีฟังก์ชัน _today_bkk(), _require_by(), _log() จาก crud.sql หรือ 06_realtime_date_sync.sql
-- =====================================================================

-- 1) ตารางทะเบียนผู้ปฏิบัติงาน
create table if not exists public.staff_users (
  user_code  text primary key,
  full_name  text not null,
  role       text not null default 'pharmacist',
  license_no text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_code_format check (user_code ~ '^[A-Z]{2,6}-[0-9]{2,4}$'),
  constraint staff_name_nonempty check (length(trim(full_name)) > 0),
  constraint staff_role_valid check (role in ('pharmacist', 'assistant', 'admin'))
);

grant select on public.staff_users to anon, authenticated;
grant all on public.staff_users to service_role;

alter table public.staff_users enable row level security;
drop policy if exists read_staff_users on public.staff_users;
create policy read_staff_users on public.staff_users
  for select to anon, authenticated using (true);

-- 2) นำเข้าข้อมูลเริ่มต้น (RX-01, RX-02, RX-03, ADM-01) และรหัสอื่นที่ปรากฏใน dispense_log
insert into public.staff_users (user_code, full_name, role, license_no, is_active) values
  ('RX-01',  'เภสัชกรปฏิบัติการ 1', 'pharmacist', 'ภ.30001', true),
  ('RX-02',  'เภสัชกรปฏิบัติการ 2', 'pharmacist', 'ภ.30002', true),
  ('RX-03',  'เภสัชกรปฏิบัติการ 3', 'pharmacist', 'ภ.30003', true),
  ('ADM-01', 'ผู้ดูแลระบบหลัก',    'admin',      null,      true)
on conflict (user_code) do nothing;

insert into public.staff_users (user_code, full_name, role, is_active)
select distinct
       upper(trim(pharmacist_code)) as code,
       'ผู้ปฏิบัติงาน ' || upper(trim(pharmacist_code)),
       'pharmacist',
       true
  from public.dispense_log
 where upper(trim(coalesce(pharmacist_code, ''))) ~ '^[A-Z]{2,6}-[0-9]{2,4}$'
on conflict (user_code) do nothing;

-- 3) ปรับ pharmacist_code ที่ยังเป็นตัวพิมพ์เล็ก (เช่น rx-01) ให้เป็นตัวพิมพ์ใหญ่สม่ำเสมอ
do $$
declare r record;
begin
  for r in
    select dispense_id, pharmacist_code, upper(trim(pharmacist_code)) as norm_code
      from public.dispense_log
     where pharmacist_code is not null
       and pharmacist_code <> upper(trim(pharmacist_code))
     order by dispense_id
  loop
    update public.dispense_log set pharmacist_code = r.norm_code where dispense_id = r.dispense_id;
    perform public._log(
      'dispense_log',
      r.dispense_id,
      'pharmacist_code',
      to_jsonb(r.pharmacist_code),
      to_jsonb(r.norm_code),
      'ปรับรหัสผู้ปฏิบัติงานเป็นตัวพิมพ์ใหญ่ตามมาตรฐานระบบ',
      'SYSTEM',
      3::smallint
    );
  end loop;
end $$;

-- 4) ฟังก์ชันจัดการทะเบียนผู้ปฏิบัติงาน (service_role เท่านั้น)
create or replace function public.staff_create(p jsonb, p_by text) returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by      text := _require_by(p_by);
  v_code    text := upper(trim(coalesce(p->>'user_code', '')));
  v_name    text := trim(coalesce(p->>'full_name', ''));
  v_role    text := lower(coalesce(nullif(trim(p->>'role'), ''), 'pharmacist'));
  v_license text := nullif(trim(coalesce(p->>'license_no', '')), '');
  v_row     staff_users;
begin
  if v_code = '' or v_code !~ '^[A-Z]{2,6}-[0-9]{2,4}$' then
    raise exception 'รหัสผู้ปฏิบัติงานต้องอยู่ในรูปแบบ เช่น RX-01, PH-04 หรือ ADM-01 (A-Z 2-6 ตัว ขีด - และตัวเลข 2-4 หลัก)';
  end if;
  if v_name = '' then
    raise exception 'ต้องระบุชื่อ-สกุลของผู้ปฏิบัติงาน';
  end if;
  if v_role not in ('pharmacist', 'assistant', 'admin') then
    raise exception 'บทบาท % ไม่ถูกต้อง (ใช้ได้เฉพาะ pharmacist, assistant, admin)', v_role;
  end if;
  if exists (select 1 from staff_users where user_code = v_code) then
    raise exception 'มีรหัสผู้ปฏิบัติงาน % อยู่แล้ว', v_code;
  end if;

  insert into staff_users (user_code, full_name, role, license_no, is_active)
  values (v_code, v_name, v_role, v_license, true)
  returning * into v_row;

  perform _log('staff_users', v_code, '(ทั้งรายการ)', null, to_jsonb(v_row), 'เพิ่มผู้ปฏิบัติงานใหม่', v_by);
  return jsonb_build_object('ok', true, 'user', to_jsonb(v_row));
end $$;

create or replace function public.staff_update(p_code text, p jsonb, p_reason text, p_by text) returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by   text := _require_by(p_by);
  v_code text := upper(trim(coalesce(p_code, '')));
  v_old  staff_users;
  v_new  staff_users;
  k      text;
  v_n    int := 0;
begin
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'ต้องระบุเหตุผลที่แก้ไข';
  end if;
  select * into v_old from staff_users where user_code = v_code for update;
  if not found then
    raise exception 'ไม่พบรหัสผู้ปฏิบัติงาน %', v_code;
  end if;

  for k in select jsonb_object_keys(p) loop
    if k not in ('full_name', 'role', 'license_no') then
      raise exception 'แก้ช่อง % ไม่ได้', k;
    end if;
    if k = 'full_name' and coalesce(trim(p->>'full_name'), '') = '' then
      raise exception 'ชื่อ-สกุลห้ามว่าง';
    end if;
    if k = 'role' and lower(trim(coalesce(p->>'role', ''))) not in ('pharmacist', 'assistant', 'admin') then
      raise exception 'บทบาทไม่ถูกต้อง (ใช้ได้เฉพาะ pharmacist, assistant, admin)';
    end if;
  end loop;

  update staff_users set
    full_name  = coalesce(nullif(trim(p->>'full_name'), ''), full_name),
    role       = coalesce(nullif(lower(trim(p->>'role')), ''), role),
    license_no = case
                   when p ? 'license_no' then nullif(trim(coalesce(p->>'license_no', '')), '')
                   else license_no
                 end,
    updated_at = now()
  where user_code = v_code
  returning * into v_new;

  for k in select jsonb_object_keys(p) loop
    if to_jsonb(v_old)->k is distinct from to_jsonb(v_new)->k then
      perform _log('staff_users', v_code, k, to_jsonb(v_old)->k, to_jsonb(v_new)->k, trim(p_reason), v_by);
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'changed_fields', v_n, 'user', to_jsonb(v_new));
end $$;

create or replace function public.staff_set_active(p_code text, p_active boolean, p_reason text, p_by text)
returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by           text := _require_by(p_by);
  v_code         text := upper(trim(coalesce(p_code, '')));
  v_old          staff_users;
  v_other_active int;
begin
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'ต้องระบุเหตุผล';
  end if;
  if p_active is null then
    raise exception 'ต้องระบุสถานะเปิด/ปิดใช้งาน';
  end if;
  select * into v_old from staff_users where user_code = v_code for update;
  if not found then
    raise exception 'ไม่พบรหัสผู้ปฏิบัติงาน %', v_code;
  end if;
  if v_old.is_active = p_active then
    raise exception 'ผู้ปฏิบัติงาน % %อยู่แล้ว', v_code, case when p_active then 'เปิดใช้งาน' else 'ปิดใช้งาน' end;
  end if;
  if not p_active then
    select count(*) into v_other_active
      from staff_users
     where is_active = true and user_code <> v_code;
    if v_other_active = 0 then
      raise exception 'ปิดใช้งานไม่ได้ ต้องมีผู้ปฏิบัติงานที่ใช้งานอยู่อย่างน้อย 1 คน';
    end if;
  end if;

  update staff_users set is_active = p_active, updated_at = now() where user_code = v_code;
  perform _log('staff_users', v_code, 'is_active', to_jsonb(v_old.is_active), to_jsonb(p_active), trim(p_reason), v_by);
  return jsonb_build_object('ok', true, 'user_code', v_code, 'is_active', p_active);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.staff_create(jsonb, text)',
    'public.staff_update(text, jsonb, text, text)',
    'public.staff_set_active(text, boolean, text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

commit;

-- ตรวจสอบผลหลังรันทันที (Read-only Verification)
select
  c.id,
  c.as_of,
  c.auto_realtime,
  public._effective_as_of() as effective_as_of,
  date_trunc('second', now() at time zone 'Asia/Bangkok') as bangkok_now
from public.app_config c
where c.id = 1;

select user_code, full_name, role, license_no, is_active
from public.staff_users
order by user_code;

select dispense_id, datetime, sku, lot, qty, patient_code, pharmacist_code, type
from public.dispense_log
where dispense_id ~ '^D[0-9]+$' and substring(dispense_id from 2)::int >= 150
order by substring(dispense_id from 2)::int desc;
