-- =====================================================================
-- crud_tests.sql : กรณีทดสอบ C1-C21 สำหรับ crud.sql
-- วิธีใช้: reset ครบ 4 ไฟล์ (schema -> seed -> sell_drug -> crud) แล้ววางไฟล์นี้ทั้งไฟล์
--          ใน Supabase SQL Editor กด Run ครั้งเดียว ผลเป็นตาราง 21 แถว ทุกแถวต้องเป็น PASS
-- ไม่มีคำสั่งเฉพาะ psql (\set, \echo) จึงรันได้ทั้งใน SQL Editor และ psql
-- การทดสอบเปลี่ยนข้อมูลจริง หลังทดสอบให้ reset ใหม่ก่อนสอน
-- =====================================================================

create temp table if not exists t_result (no text, name text, expect text, got text, result text);
truncate t_result;

do $$
declare
  j   jsonb;
  n   int;
begin
  ------------------------------------------------------------------ ต้องสำเร็จ
  -- C1 เพิ่มยาใหม่
  begin
    j := drug_create('{"sku":"vite400","generic_name":"Vitamin E","strength":"400 IU","dosage_form":"capsule","unit":"capsule","category":"วิตามินและเกลือแร่","atc_code":"A11HA03","reorder_level":50}', 'RX-01');
    insert into t_result values ('C1', 'เพิ่มยาใหม่ (sku เป็นตัวใหญ่)', 'VITE400', j->'drug'->>'sku',
      case when j->'drug'->>'sku' = 'VITE400' then 'PASS' else 'FAIL' end);
  exception when others then insert into t_result values ('C1', 'เพิ่มยาใหม่', 'สำเร็จ', sqlerrm, 'FAIL'); end;

  -- C2 ยาใหม่ที่ยังไม่มีล็อตต้องเห็นใน v_drug_catalog
  select lot_count into n from v_drug_catalog where sku = 'VITE400';
  insert into t_result values ('C2', 'ยาใหม่เห็นใน v_drug_catalog', 'lot_count 0', coalesce('lot_count ' || n, 'ไม่พบ'),
    case when n = 0 then 'PASS' else 'FAIL' end);

  -- C3 แก้จุดสั่งซื้อ
  begin
    j := drug_update('VITE400', '{"reorder_level":40}', 'ปรับตามยอดขายจริง', 'RX-01');
    insert into t_result values ('C3', 'แก้จุดสั่งซื้อ', '40', j->'drug'->>'reorder_level',
      case when j->'drug'->>'reorder_level' = '40' then 'PASS' else 'FAIL' end);
  exception when others then insert into t_result values ('C3', 'แก้จุดสั่งซื้อ', 'สำเร็จ', sqlerrm, 'FAIL'); end;

  -- C4 รับเข้าล็อตใหม่
  begin
    j := stock_receive('VITE400', 've2611', '2026-11-01', '2028-10-31', 120, 2.5, 'RX-01');
    insert into t_result values ('C4', 'รับเข้าล็อตใหม่', 'S050', j->'stock'->>'stock_id',
      case when j->'stock'->>'stock_id' = 'S050' then 'PASS' else 'FAIL' end);
  exception when others then insert into t_result values ('C4', 'รับเข้าล็อตใหม่', 'สำเร็จ', sqlerrm, 'FAIL'); end;

  -- C5 แก้วันหมดอายุ S007 ตามฉลาก แล้วปล่อยใช้
  begin
    perform stock_fix_expiry('S007', '2028-03-31', 'ตรวจฉลากแล้ว ปีที่พิมพ์ผิด', 'RX-02');
    j := stock_set_status('S007', 'active', 'ตรวจฉลากแล้ว', 'RX-02');
    insert into t_result values ('C5', 'แก้วันหมดอายุ S007 แล้วปล่อยใช้', 'active', j->>'status',
      case when j->>'status' = 'active' then 'PASS' else 'FAIL' end);
  exception when others then insert into t_result values ('C5', 'แก้วันหมดอายุ S007 แล้วปล่อยใช้', 'สำเร็จ', sqlerrm, 'FAIL'); end;

  -- C6 ตัดจำหน่ายล็อตที่ยังมีของ
  begin
    j := stock_set_status('S029', 'written_off', 'ทดสอบตัดจำหน่าย', 'RX-02');
    select qty_on_hand into n from stock where stock_id = 'S029';
    insert into t_result values ('C6', 'ตัดจำหน่าย S029', 'ADJ-004, qty 0', (j->>'adjustment_id') || ', qty ' || n,
      case when j->>'adjustment_id' = 'ADJ-004' and n = 0 then 'PASS' else 'FAIL' end);
  exception when others then insert into t_result values ('C6', 'ตัดจำหน่าย S029', 'สำเร็จ', sqlerrm, 'FAIL'); end;

  -- C7 คืนยาบางส่วน D0115 (จ่าย 20) คืน 5
  begin
    j := dispense_return('D0115', 5, 'ผู้ป่วยแพ้ยา', 'RX-03');
    insert into t_result values ('C7', 'คืนยา D0115 จำนวน 5', 'คืนได้อีก 15', 'คืนได้อีก ' || (j->>'returnable_left'),
      case when j->>'returnable_left' = '15' then 'PASS' else 'FAIL' end);
  exception when others then insert into t_result values ('C7', 'คืนยา D0115 จำนวน 5', 'สำเร็จ', sqlerrm, 'FAIL'); end;

  -- C8 ยกเลิก D0117 (30 จาก AX2509) ยอด S030 ต้องเพิ่ม 30
  begin
    select qty_on_hand into n from stock where stock_id = 'S030';
    perform dispense_void('D0117', 'บันทึกซ้ำ', 'RX-03');
    insert into t_result
      select 'C8', 'ยกเลิก D0117 คืนยอด S030', (n + 30)::text, qty_on_hand::text,
             case when qty_on_hand = n + 30 then 'PASS' else 'FAIL' end
        from stock where stock_id = 'S030';
  exception when others then insert into t_result values ('C8', 'ยกเลิก D0117', 'สำเร็จ', sqlerrm, 'FAIL'); end;

  -- C9 ปิดใช้งานยาที่ไม่มีของเหลือ
  begin
    perform drug_create('{"sku":"TEST1","generic_name":"Test","strength":"1 mg","dosage_form":"tablet","unit":"tablet","category":"ทดสอบ","atc_code":"X","reorder_level":0}', 'RX-01');
    j := drug_set_active('TEST1', false, 'ทดสอบ', 'RX-01');
    insert into t_result values ('C9', 'ปิดใช้งานยาที่ไม่มีของ', 'false', j->>'is_active',
      case when j->>'is_active' = 'false' then 'PASS' else 'FAIL' end);
  exception when others then insert into t_result values ('C9', 'ปิดใช้งานยาที่ไม่มีของ', 'สำเร็จ', sqlerrm, 'FAIL'); end;
end $$;

-- ------------------------------------------------------------------ ต้องถูกปฏิเสธ
-- แต่ละกรณีต้อง error ด้วยข้อความที่มีคำที่คาดไว้ และข้อมูลต้องไม่เปลี่ยน (ฐานข้อมูลยกเลิกเฉพาะคำสั่งนั้น)
do $$
declare
  c record;
begin
  for c in select * from (values
    ('C10', 'รหัสยาซ้ำ',                     'มีรหัสยา',
       $q$select drug_create('{"sku":"PARA500","generic_name":"x","strength":"x","dosage_form":"x","unit":"x","category":"x","atc_code":"x","reorder_level":1}', 'RX-01')$q$),
    ('C11', 'แก้ sku',                        'แก้ช่อง sku ไม่ได้',
       $q$select drug_update('PARA500', '{"sku":"PARA5"}', 'x', 'RX-01')$q$),
    ('C12', 'ปิดใช้งานยาที่ยังมีของ',          'ปิดใช้งานไม่ได้',
       $q$select drug_set_active('PARA500', false, 'x', 'RX-01')$q$),
    ('C13', 'รับล็อตซ้ำ',                      'มีอยู่แล้ว',
       $q$select stock_receive('PARA500', 'PA2509', '2026-10-01', '2028-01-01', 10, 1, 'RX-01')$q$),
    ('C14', 'รับล็อตที่หมดอายุแล้ว',           'หมดอายุแล้ว',
       $q$select stock_receive('PARA500', 'PAOLD', '2026-01-01', '2026-10-01', 10, 1, 'RX-01')$q$),
    ('C15', 'ปล่อยใช้ S022 ที่ไม่มีวันหมดอายุ', 'ยังไม่มีวันหมดอายุ',
       $q$select stock_set_status('S022', 'active', 'x', 'RX-01')$q$),
    ('C16', 'แก้วันหมดอายุล็อต active',        'เฉพาะล็อตที่กักไว้',
       $q$select stock_fix_expiry('S009', '2029-01-01', 'x', 'RX-01')$q$),
    ('C17', 'คืนเกินจำนวน D0115',              'คืนเกินจำนวน',
       $q$select dispense_return('D0115', 16, 'x', 'RX-03')$q$),
    ('C18', 'ยกเลิก D0014 ที่มีอุบัติการณ์',     'มีอุบัติการณ์',
       $q$select dispense_void('D0014', 'x', 'RX-03')$q$),
    ('C19', 'ยกเลิก D0115 ที่มีการคืนแล้ว',      'มีการคืนยาแล้ว',
       $q$select dispense_void('D0115', 'x', 'RX-03')$q$),
    ('C20', 'ไม่ระบุผู้บันทึก',                  'ต้องระบุรหัสเภสัชกร',
       $q$select stock_set_status('S009', 'quarantine', 'x', '  ')$q$)
  ) as t(no, name, expect, q)
  loop
    begin
      execute c.q;
      insert into t_result values (c.no, c.name, 'ถูกปฏิเสธ: ' || c.expect, 'สำเร็จ (ไม่ควรสำเร็จ)', 'FAIL');
    exception when others then
      insert into t_result values (c.no, c.name, 'ถูกปฏิเสธ: ' || c.expect, sqlerrm,
        case when position(c.expect in sqlerrm) > 0 then 'PASS' else 'FAIL' end);
    end;
  end loop;
end $$;

-- C21 key สิทธิ์ต่ำ (publishable key = role anon) ต้องเรียกฟังก์ชันเขียนข้อมูลไม่ได้
insert into t_result
select 'C21', 'anon เรียกฟังก์ชันเขียนไม่ได้', 'ไม่มีสิทธิ์ทุกฟังก์ชัน',
       count(*) filter (where has_function_privilege('anon', p.oid, 'execute')) || ' ฟังก์ชันที่ anon เรียกได้',
       case when count(*) filter (where has_function_privilege('anon', p.oid, 'execute')) = 0
             and count(*) >= 8 then 'PASS' else 'FAIL' end
from pg_proc p join pg_namespace s on s.oid = p.pronamespace
where s.nspname = 'public'
  and p.proname in ('drug_create','drug_update','drug_set_active','stock_receive','stock_fix_expiry',
                    'stock_set_status','dispense_return','dispense_void','config_set_as_of');

-- ผลรวม: ทุกแถวต้องเป็น PASS
select no, result, name, expect, got
from t_result
order by substring(no from 2)::int;
