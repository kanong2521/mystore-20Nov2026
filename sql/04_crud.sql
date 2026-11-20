-- =====================================================================
-- crud.sql : ฟังก์ชันเพิ่ม แก้ไข และเปลี่ยนสถานะข้อมูล สำหรับหน้าจัดการ (admin)
-- ลำดับการรัน: schema.sql -> seed.sql -> sell_drug.sql -> crud.sql
-- รันซ้ำได้ (ใช้ร่วมกับการ reset เดิม)
--
-- หลักการ
--   - ทุกการเขียนทำผ่านฟังก์ชัน เป็นธุรกรรมเดียว พร้อมบันทึก change_log ในธุรกรรมเดียวกัน
--   - เรียกได้เฉพาะฝั่งเซิร์ฟเวอร์ (secret key) เหมือน sell_drug
--   - ไม่มีการลบจริง: ยาใช้ปิดใช้งาน ล็อตใช้เปลี่ยนสถานะ การจ่ายใช้ void หรือ return
--   - ข้อความผิดพลาดเป็นภาษาไทย (raise exception = รหัส P0001 ที่ api ส่งต่อให้ผู้ใช้ได้)
--   - วันที่จ่าย/คืนยาใช้ as_of (เหมือน sell_drug) ส่วนวันที่บันทึกงานธุรการใช้วันจริง (เหมือน seed)
-- ข้อมูลทั้งหมดเป็นข้อมูลจำลองเพื่อการเรียนเท่านั้น
-- =====================================================================

-- ---------- 0) ปรับโครงสร้างเพิ่มเติม ----------
-- ยาปิดใช้งานแทนการลบ (คอลัมน์ท้ายตาราง มีค่าเริ่มต้น จึงไม่กระทบ insert เดิม)
alter table public.drugs add column if not exists is_active boolean not null default true;

-- รองรับโหมดวันจริงอัตโนมัติใน app_config (ปลอดภัยเมื่อรันทับฐานเดิมที่ยังไม่มีคอลัมน์)
alter table public.app_config add column if not exists auto_realtime boolean not null default true;

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

-- รายการคืนยาอ้างกลับไปยังรายการจ่ายเดิม
alter table public.dispense_log add column if not exists ref_dispense_id text
  references public.dispense_log (dispense_id);
alter table public.dispense_log drop constraint if exists dispense_return_has_ref;
alter table public.dispense_log add constraint dispense_return_has_ref
  check (type <> 'return' or ref_dispense_id is not null);

-- สถานะของรายการรอตรวจ
alter table public.dispense_pending drop constraint if exists pending_status_valid;
alter table public.dispense_pending add constraint pending_status_valid
  check (status in ('pending_review', 'resolved', 'rejected'));

-- เลขที่เอกสารใหม่ (ห้ามใช้ max+1 เพราะสองคนบันทึกพร้อมกันจะได้เลขซ้ำ)
create sequence if not exists public.stock_seq;
create sequence if not exists public.adj_seq;
select setval('public.stock_seq',
  greatest(40, coalesce((select max(substring(stock_id from 2)::int) from public.stock), 0)), true);
select setval('public.adj_seq',
  coalesce((select max(substring(adjustment_id from 5)::int) from public.stock_adjustments), 1),
  exists (select 1 from public.stock_adjustments));   -- ADJ-003 -> ถัดไป ADJ-004

-- ---------- 1) view สำหรับหน้าจัดการบัญชียา ----------
-- ไม่แก้ view เดิมของ dashboard: v_stock_by_sku ใช้ inner join จึงแสดงเฉพาะยาที่มีล็อต
-- (บัญชียามี 100 รายการ แต่มีล็อตเพียง 30 ถ้าเปลี่ยนเป็น left join รายการต่ำกว่าจุดสั่งซื้อจะเพิ่มจาก 2 เป็น 72
--  และตัวเลขไม่ตรงเฉลยวันที่ 2) หน้าจัดการจึงใช้ view นี้แทน ซึ่งแสดงยาทุกตัว รวมยาที่ยังไม่มีล็อต
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

-- ---------- 2) ตัวช่วยภายใน ----------
create or replace function public._today_bkk() returns date
language sql stable set search_path = public
as $$ select (now() at time zone 'Asia/Bangkok')::date $$;

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

-- ---------- 3) บัญชียา ----------
-- เพิ่มยาใหม่ p = {"sku","generic_name","strength","dosage_form","unit","category","atc_code","reorder_level"}
create or replace function public.drug_create(p jsonb, p_by text) returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by  text := _require_by(p_by);
  v_sku text := upper(trim(coalesce(p->>'sku', '')));
  v_row drugs;
  k     text;
begin
  foreach k in array array['sku','generic_name','strength','dosage_form','unit','category','atc_code'] loop
    if coalesce(trim(p->>k), '') = '' then
      raise exception 'ต้องกรอก % ', k;
    end if;
  end loop;
  if v_sku !~ '^[A-Z0-9-]{2,20}$' then
    raise exception 'รหัสยาใช้ได้เฉพาะ A-Z 0-9 และ - ยาว 2-20 ตัว';
  end if;
  if (p->>'reorder_level') is null or (p->>'reorder_level') !~ '^\d+$' then
    raise exception 'จุดสั่งซื้อต้องเป็นจำนวนเต็มตั้งแต่ 0 ขึ้นไป';
  end if;
  if exists (select 1 from drugs where sku = v_sku) then
    raise exception 'มีรหัสยา % อยู่แล้ว', v_sku;
  end if;

  insert into drugs (sku, generic_name, strength, dosage_form, unit, category, atc_code, reorder_level)
  values (v_sku, trim(p->>'generic_name'), trim(p->>'strength'), trim(p->>'dosage_form'),
          trim(p->>'unit'), trim(p->>'category'), upper(trim(p->>'atc_code')),
          (p->>'reorder_level')::int)
  returning * into v_row;

  perform _log('drugs', v_sku, '(ทั้งรายการ)', null, to_jsonb(v_row), 'เพิ่มยาใหม่', v_by);
  return jsonb_build_object('ok', true, 'drug', to_jsonb(v_row));
end $$;

-- แก้ไขยา ส่งเฉพาะช่องที่จะแก้ แก้ sku ไม่ได้ (ล็อตและประวัติการจ่ายอ้างอยู่)
create or replace function public.drug_update(p_sku text, p jsonb, p_reason text, p_by text) returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by  text := _require_by(p_by);
  v_old drugs;
  v_new drugs;
  k     text;
  v_n   int := 0;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'ต้องระบุเหตุผลที่แก้ไข'; end if;
  select * into v_old from drugs where sku = p_sku for update;
  if not found then raise exception 'ไม่พบรหัสยา %', p_sku; end if;

  for k in select jsonb_object_keys(p) loop
    if k not in ('generic_name','strength','dosage_form','unit','category','atc_code','reorder_level') then
      raise exception 'แก้ช่อง % ไม่ได้', k;
    end if;
    if k = 'reorder_level' and (p->>k) !~ '^\d+$' then
      raise exception 'จุดสั่งซื้อต้องเป็นจำนวนเต็มตั้งแต่ 0 ขึ้นไป';
    end if;
    if k <> 'reorder_level' and coalesce(trim(p->>k), '') = '' then
      raise exception 'ช่อง % ห้ามว่าง', k;
    end if;
  end loop;

  update drugs set
    generic_name  = coalesce(trim(p->>'generic_name'), generic_name),
    strength      = coalesce(trim(p->>'strength'), strength),
    dosage_form   = coalesce(trim(p->>'dosage_form'), dosage_form),
    unit          = coalesce(trim(p->>'unit'), unit),
    category      = coalesce(trim(p->>'category'), category),
    atc_code      = coalesce(upper(trim(p->>'atc_code')), atc_code),
    reorder_level = coalesce((p->>'reorder_level')::int, reorder_level)
  where sku = p_sku
  returning * into v_new;

  for k in select jsonb_object_keys(p) loop
    if to_jsonb(v_old)->k is distinct from to_jsonb(v_new)->k then
      perform _log('drugs', p_sku, k, to_jsonb(v_old)->k, to_jsonb(v_new)->k, trim(p_reason), v_by);
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'changed_fields', v_n, 'drug', to_jsonb(v_new));
end $$;

-- ปิด/เปิดใช้งานยา (แทนการลบ) ปิดไม่ได้ถ้ายังมีของในล็อต active หรือ quarantine
create or replace function public.drug_set_active(p_sku text, p_active boolean, p_reason text, p_by text)
returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by  text := _require_by(p_by);
  v_old boolean;
  v_left int;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'ต้องระบุเหตุผล'; end if;
  select is_active into v_old from drugs where sku = p_sku for update;
  if not found then raise exception 'ไม่พบรหัสยา %', p_sku; end if;
  if v_old = p_active then
    raise exception 'ยา % %อยู่แล้ว', p_sku, case when p_active then 'เปิดใช้งาน' else 'ปิดใช้งาน' end;
  end if;
  if not p_active then
    select coalesce(sum(qty_on_hand), 0) into v_left from stock
     where sku = p_sku and status in ('active', 'quarantine');
    if v_left > 0 then
      raise exception 'ปิดใช้งานไม่ได้ ยังมียา % เหลือในคลัง % หน่วย ต้องจ่ายหมดหรือตัดจำหน่ายก่อน', p_sku, v_left;
    end if;
  end if;
  update drugs set is_active = p_active where sku = p_sku;
  perform _log('drugs', p_sku, 'is_active', to_jsonb(v_old), to_jsonb(p_active), trim(p_reason), v_by);
  return jsonb_build_object('ok', true, 'sku', p_sku, 'is_active', p_active);
end $$;

-- ---------- 4) คลังรายล็อต ----------
-- รับยาเข้าล็อตใหม่ ได้เลขล็อตในระบบ S0xx
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

-- แก้วันหมดอายุตามฉลากจริง ทำได้เฉพาะล็อตที่กักไว้ (เช่น S007, S022)
create or replace function public.stock_fix_expiry(p_stock_id text, p_expiry date, p_reason text, p_by text)
returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by  text := _require_by(p_by);
  v_old stock;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'ต้องระบุเหตุผล เช่น ตรวจฉลากแล้ว'; end if;
  select * into v_old from stock where stock_id = p_stock_id for update;
  if not found then raise exception 'ไม่พบล็อต %', p_stock_id; end if;
  if v_old.status <> 'quarantine' then
    raise exception 'แก้วันหมดอายุได้เฉพาะล็อตที่กักไว้ ให้กักล็อต % ก่อน', p_stock_id;
  end if;
  if p_expiry is null or p_expiry <= v_old.received_date then
    raise exception 'วันหมดอายุต้องอยู่หลังวันรับเข้า %', v_old.received_date;
  end if;
  update stock set expiry = p_expiry where stock_id = p_stock_id;
  perform _log('stock', p_stock_id, 'expiry', to_jsonb(v_old.expiry), to_jsonb(p_expiry),
               trim(p_reason), v_by, 1::smallint);
  return jsonb_build_object('ok', true, 'stock_id', p_stock_id, 'expiry', p_expiry);
end $$;

-- เปลี่ยนสถานะล็อต
--   active -> quarantine        กักไว้ หยุดจ่าย
--   quarantine -> active        ปล่อยใช้ ต้องมีวันหมดอายุที่ถูกต้องและยังไม่หมดอายุ
--   active/quarantine -> written_off  ตัดจำหน่าย ถ้ามีของ สร้าง stock_adjustments ตัดยอดให้ในธุรกรรมเดียว
--   written_off -> อื่นใด       ไม่ได้
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

-- ---------- 5) คืนยาและยกเลิกรายการจ่าย ----------
-- คืนยา: เพิ่มแถว type = 'return' อ้างรายการเดิม และคืนยอดเข้าล็อตเดิมเป็นของจ่ายได้
-- คืนรวมทุกครั้งได้ไม่เกินจำนวนที่จ่าย
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
  values (v_id, v_now,
          v_orig.sku, v_orig.lot, p_qty, v_orig.patient_code, v_by, 'return', p_dispense_id);
  perform _log('dispense_log', v_id, '(ทั้งรายการ)', null,
               jsonb_build_object('type', 'return', 'ref', p_dispense_id, 'qty', p_qty),
               trim(p_reason), v_by, 2::smallint);
  return jsonb_build_object('ok', true, 'dispense_id', v_id, 'ref_dispense_id', p_dispense_id,
                            'qty', p_qty, 'returnable_left', v_orig.qty - v_done - p_qty);
end $$;

-- ยกเลิกรายการจ่ายที่บันทึกผิด: เปลี่ยน type เป็น void และคืนยอดเข้าล็อตเดิม
-- ทำไม่ได้ถ้ามีการคืนยาของรายการนี้แล้ว หรือมีอุบัติการณ์อ้างอยู่
create or replace function public.dispense_void(p_dispense_id text, p_reason text, p_by text)
returns jsonb
language plpgsql set search_path = public
as $$
declare
  v_by   text := _require_by(p_by);
  v_orig dispense_log;
  v_lot  stock;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'ต้องระบุเหตุผลที่ยกเลิก'; end if;
  select * into v_orig from dispense_log where dispense_id = p_dispense_id for update;
  if not found then raise exception 'ไม่พบรายการจ่าย %', p_dispense_id; end if;
  if v_orig.type <> 'dispense' then raise exception 'รายการ % เป็น % อยู่แล้ว', p_dispense_id, v_orig.type; end if;
  if exists (select 1 from dispense_log where ref_dispense_id = p_dispense_id) then
    raise exception 'รายการ % มีการคืนยาแล้ว ยกเลิกไม่ได้', p_dispense_id;
  end if;
  if exists (select 1 from incidents where dispense_id = p_dispense_id) then
    raise exception 'รายการ % มีอุบัติการณ์อ้างอยู่ ห้ามยกเลิกเพราะเป็นหลักฐาน', p_dispense_id;
  end if;

  select * into v_lot from stock where sku = v_orig.sku and lot = v_orig.lot for update;
  if v_lot.status = 'written_off' then
    raise exception 'ล็อต % ตัดจำหน่ายแล้ว คืนยอดไม่ได้ ติดต่อผู้ดูแล', v_lot.lot;
  end if;

  update stock set qty_on_hand = qty_on_hand + v_orig.qty where stock_id = v_lot.stock_id;
  update dispense_log set type = 'void' where dispense_id = p_dispense_id;
  perform _log('dispense_log', p_dispense_id, 'type', '"dispense"'::jsonb, '"void"'::jsonb,
               trim(p_reason) || ' (คืนยอด ' || v_orig.qty || ' เข้าล็อต ' || v_lot.lot || ')', v_by, 2::smallint);
  return jsonb_build_object('ok', true, 'dispense_id', p_dispense_id, 'restored_qty', v_orig.qty, 'lot', v_lot.lot);
end $$;

-- ---------- 6) app_config: เลื่อนวันอ้างอิง (ใช้ตอนสอนหรือปรับเป็นวันนี้) ----------
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

-- ---------- 7) สิทธิ์: เรียกได้เฉพาะ secret key (service_role) ----------
do $$
declare f text;
begin
  foreach f in array array[
    'public._today_bkk()',
    'public._require_by(text)',
    'public._log(text, text, text, jsonb, jsonb, text, text, smallint, text)',
    'public.drug_create(jsonb, text)',
    'public.drug_update(text, jsonb, text, text)',
    'public.drug_set_active(text, boolean, text, text)',
    'public.stock_receive(text, text, date, date, integer, numeric, text)',
    'public.stock_fix_expiry(text, date, text, text)',
    'public.stock_set_status(text, text, text, text)',
    'public.dispense_return(text, integer, text, text)',
    'public.dispense_void(text, text, text)',
    'public.config_set_as_of(date, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant usage, select on sequence public.stock_seq, public.adj_seq to service_role;
grant select on public.v_drug_catalog to anon, authenticated;
grant all on public.v_drug_catalog to service_role;
