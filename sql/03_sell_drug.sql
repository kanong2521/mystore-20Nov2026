-- sell_drug.sql : ฟังก์ชันขายยา ทำงานเป็นธุรกรรมเดียว (ถ้าล้มเหลว ไม่มีอะไรถูกเปลี่ยน)
-- อัปเดต: ใช้วันเวลาจริงโซน Asia/Bangkok (now()) เสมอ และขายได้เฉพาะล็อต status = 'active' ที่ยังไม่หมดอายุ
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
  select case
           when coalesce((to_jsonb(c)->>'auto_realtime')::boolean, true)
             then greatest(c.as_of, v_now::date)
           else c.as_of
         end
    into v_as_of
    from app_config c
   where c.id = 1;
  v_as_of := coalesce(v_as_of, v_now::date);

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
     order by expiry, stock_id          -- หมดอายุก่อนจ่ายก่อน (FEFO)
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

-- ให้เรียกได้เฉพาะฝั่งเซิร์ฟเวอร์ (secret key) ไม่ให้เบราว์เซอร์เรียกตรง
revoke all on function public.sell_drug(text, integer, text, text) from public, anon, authenticated;
grant execute on function public.sell_drug(text, integer, text, text) to service_role;
