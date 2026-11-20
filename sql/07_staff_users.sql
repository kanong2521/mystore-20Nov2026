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
