-- ARANA TIME — ให้ฐานข้อมูล "ซ่อมตัวเอง" เมื่อข้อมูลถูกล้างโดยไม่ตั้งใจ
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ ไม่มีคำสั่งลบข้อมูลใดๆ)
--
-- ที่มา: 28 ส.ค. 2569 มีคำสั่งจากนอกแอป (ไม่ผ่านหน้าเว็บ ไม่มีร่องรอยใน audit_log)
-- มาล้างข้อมูล 2 อย่างซ้ำๆ วันเดียว 2 รอบ (09:47:15 และ 10:13:19)
--   1. ลบตาราง employees แล้วเขียนกลับด้วย id เดิม -> foreign key แบบ ON DELETE SET NULL
--      ตัดตัวเชื่อมของประวัติทั้งหมดทิ้ง (logs 1,222 / leaves 51 / ot 15 / notifications 1,331)
--   2. คอลัมน์ Chat ID ของสาขา (chat_id_checkinout / facility / leave_approval) กลายเป็น NULL
--      ทั้ง 4 สาขา ทำให้ระบบข้ามการส่ง Telegram เงียบๆ โดยไม่มีใครรู้ตัว
--
-- แนวคิด: กันที่ฝั่งฐานข้อมูลเท่านั้นถึงจะได้ผล เพราะคำสั่งที่มาล้างไม่ได้วิ่งผ่านแอป
-- จึงไม่ใช้วิธีห้าม (จะทำให้งานปกติสะดุด) แต่ใช้วิธี "จำค่าไว้ แล้วเติมกลับให้เอง"

-- ============================================================
-- ส่วนที่ 1 — ประวัติผูกกลับหาพนักงานเองอัตโนมัติ
-- ============================================================
-- ต่อยอดจาก keep-employee-name-snapshot.sql ที่ทำให้ทุกแถวมีชื่อกำกับติดไว้แล้ว
-- ตรงนี้เพิ่มให้ว่า "พอแถวพนักงานกลับเข้ามา ประวัติที่ชื่อตรงกันจะผูกกลับเองทันที"
-- ไม่ต้องรอคนมากดปุ่มซ่อม

create index if not exists idx_logs_orphan_name    on logs(employee_name)          where employee_id is null;
create index if not exists idx_leaves_orphan_name  on leaves(employee_name)        where employee_id is null;
create index if not exists idx_ot_orphan_name      on ot_requests(employee_name)   where employee_id is null;
create index if not exists idx_noti_orphan_name    on notifications(employee_name) where employee_id is null;

create or replace function arana_relink_employee_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.name is null then
    return new;
  end if;
  -- ถ้ามีพนักงานคนอื่นชื่อซ้ำกันเป๊ะ ไม่ผูกให้ เพราะเดาไม่ได้ว่าเป็นของใคร
  if exists (select 1 from employees where name = new.name and id <> new.id) then
    return new;
  end if;
  update logs             set employee_id = new.id where employee_id is null and employee_name = new.name;
  update leaves           set employee_id = new.id where employee_id is null and employee_name = new.name;
  update ot_requests      set employee_id = new.id where employee_id is null and employee_name = new.name;
  update notifications    set employee_id = new.id where employee_id is null and employee_name = new.name;
  update branch_transfers set employee_id = new.id where employee_id is null and employee_name = new.name;
  return new;
end;
$$;

drop trigger if exists trg_relink_employee_history on employees;
create trigger trg_relink_employee_history
  after insert on employees
  for each row execute function arana_relink_employee_history();

-- ผูกกลับให้แถวที่ค้างอยู่ตอนนี้ทันที (เฉพาะแถวที่มีชื่อกำกับและชื่อไม่ซ้ำกับใคร)
update logs t set employee_id = e.id from employees e
  where t.employee_id is null and t.employee_name = e.name
    and not exists (select 1 from employees x where x.name = e.name and x.id <> e.id);
update leaves t set employee_id = e.id from employees e
  where t.employee_id is null and t.employee_name = e.name
    and not exists (select 1 from employees x where x.name = e.name and x.id <> e.id);
update ot_requests t set employee_id = e.id from employees e
  where t.employee_id is null and t.employee_name = e.name
    and not exists (select 1 from employees x where x.name = e.name and x.id <> e.id);
update notifications t set employee_id = e.id from employees e
  where t.employee_id is null and t.employee_name = e.name
    and not exists (select 1 from employees x where x.name = e.name and x.id <> e.id);
update branch_transfers t set employee_id = e.id from employees e
  where t.employee_id is null and t.employee_name = e.name
    and not exists (select 1 from employees x where x.name = e.name and x.id <> e.id);

-- ============================================================
-- ส่วนที่ 2 — Chat ID ของสาขาเติมกลับเองเมื่อถูกล้างเป็น NULL
-- ============================================================
-- เก็บสำเนา Chat ID ล่าสุดไว้อีกตาราง แล้วถ้ามีคำสั่งเขียนค่า NULL ทับ ให้ดึงสำเนากลับมาใส่แทน
-- ตารางสำเนาเปิด RLS โดยไม่มี policy = ฝั่งเว็บอ่านไม่ได้ มีแต่ trigger เท่านั้นที่แตะได้

create table if not exists branch_chat_backup (
  branch_id              text primary key,
  chat_id_checkinout     text,
  chat_id_facility       text,
  chat_id_leave_approval text,
  updated_at             timestamptz default now()
);
alter table branch_chat_backup enable row level security;

-- (ก) ก่อนบันทึกสาขา: ช่องไหนเป็น NULL ให้ดึงค่าเดิมจากสำเนามาใส่
--     หมายเหตุ: เติมกลับเฉพาะกรณี NULL เท่านั้น ถ้าตั้งใจล้างค่าจริงๆ ให้บันทึกเป็นค่าว่าง ''
--     ซึ่งเป็นสิ่งที่หน้าเว็บทำอยู่แล้ว (ดู branchToRow ในไฟล์แอป) จึงไม่กระทบการใช้งานปกติ
create or replace function arana_branch_chat_restore()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare bk branch_chat_backup%rowtype;
begin
  select * into bk from branch_chat_backup where branch_id = new.id;
  if found then
    if new.chat_id_checkinout     is null then new.chat_id_checkinout     := bk.chat_id_checkinout;     end if;
    if new.chat_id_facility       is null then new.chat_id_facility       := bk.chat_id_facility;       end if;
    if new.chat_id_leave_approval is null then new.chat_id_leave_approval := bk.chat_id_leave_approval; end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_branch_chat_restore on branches;
create trigger trg_branch_chat_restore
  before insert or update on branches
  for each row execute function arana_branch_chat_restore();

-- (ข) หลังบันทึกสาขา: อัปเดตสำเนา เก็บเฉพาะค่าที่ไม่ว่าง
create or replace function arana_branch_chat_backup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into branch_chat_backup as bk
    (branch_id, chat_id_checkinout, chat_id_facility, chat_id_leave_approval, updated_at)
  values
    (new.id, nullif(new.chat_id_checkinout,''), nullif(new.chat_id_facility,''), nullif(new.chat_id_leave_approval,''), now())
  on conflict (branch_id) do update set
    chat_id_checkinout     = coalesce(excluded.chat_id_checkinout,     bk.chat_id_checkinout),
    chat_id_facility       = coalesce(excluded.chat_id_facility,       bk.chat_id_facility),
    chat_id_leave_approval = coalesce(excluded.chat_id_leave_approval, bk.chat_id_leave_approval),
    updated_at = now();
  return null;
end;
$$;

drop trigger if exists trg_branch_chat_backup on branches;
create trigger trg_branch_chat_backup
  after insert or update on branches
  for each row execute function arana_branch_chat_backup();

-- เก็บสำเนาจากค่าที่มีอยู่ตอนนี้ (ถ้าตอนนี้ยังเป็น NULL อยู่ จะยังไม่มีอะไรให้เก็บ
-- ต้องใส่ Chat ID กลับเข้าไปทางหน้าเว็บหนึ่งครั้งก่อน จากนั้นระบบจะจำไว้ให้เอง)
insert into branch_chat_backup (branch_id, chat_id_checkinout, chat_id_facility, chat_id_leave_approval)
select id, nullif(chat_id_checkinout,''), nullif(chat_id_facility,''), nullif(chat_id_leave_approval,'')
from branches
where coalesce(chat_id_checkinout,'') <> '' or coalesce(chat_id_facility,'') <> '' or coalesce(chat_id_leave_approval,'') <> ''
on conflict (branch_id) do nothing;

-- ============================================================
-- ส่วนที่ 3 — ปฏิเสธคำสั่งลบทั้งตาราง (ตัวการตัวจริง)
-- ============================================================
-- จาก Supabase log วันที่ 28 ส.ค. 2569 พบคำสั่งนี้ 2 ครั้ง (10:08:39 และ 10:13:19)
--   DELETE /rest/v1/branches?id=not.is.null
--   DELETE /rest/v1/employees?id=not.is.null
--   POST   /rest/v1/settings, /rest/v1/branches, /rest/v1/employees
-- ตรงกับฟังก์ชัน sbReplaceAll() ของแอปเวอร์ชันเก่าเป๊ะ (ลบทั้งตารางแล้วเขียนกลับ)
-- ส่งมาจาก iPhone Safari เครื่องเดียว ที่เปิดหน้าเว็บเวอร์ชันเก่าค้างไว้
-- (ดูออกจากตอนเปิดแอปมันโหลดแค่ 7 ตาราง ขาด approvers กับ branch_transfers
--  ซึ่งเป็นตารางที่เพิ่มมาทีหลัง = เป็นไฟล์เวอร์ชันก่อนหน้าที่ค้างใน cache)
--
-- ด่านนี้กันที่ฐานข้อมูล จึงกันได้ทุกเครื่อง ทุกเวอร์ชัน แม้แต่เครื่องที่ยังไม่ได้รีเฟรช
-- ลบพนักงาน/สาขาทีละคนผ่านหน้าเว็บยังทำได้ปกติ (1 แถวต่อ 1 คำสั่ง) ห้ามเฉพาะลบรวดเดียวหลายแถว

create or replace function arana_block_bulk_delete()
returns trigger
language plpgsql
as $$
declare n integer;
begin
  select count(*) into n from arana_deleted_rows;
  if n > 1 then
    raise exception
      'ARANA: ปฏิเสธคำสั่งลบ % แถวพร้อมกันจากตาราง "%" — ลบได้ทีละแถวเท่านั้น '
      'คำสั่งแบบนี้มาจากแอปเวอร์ชันเก่าที่ค้างในเครื่อง กรุณาปิดแท็บแล้วเปิดหน้าเว็บใหม่',
      n, tg_table_name;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_block_bulk_delete on employees;
create trigger trg_block_bulk_delete
  after delete on employees
  referencing old table as arana_deleted_rows
  for each statement execute function arana_block_bulk_delete();

drop trigger if exists trg_block_bulk_delete on branches;
create trigger trg_block_bulk_delete
  after delete on branches
  referencing old table as arana_deleted_rows
  for each statement execute function arana_block_bulk_delete();

drop trigger if exists trg_block_bulk_delete on approvers;
create trigger trg_block_bulk_delete
  after delete on approvers
  referencing old table as arana_deleted_rows
  for each statement execute function arana_block_bulk_delete();

-- ============================================================
-- ตรวจผลหลังรัน
-- ============================================================
select 'logs' as ตาราง, count(*) as ทั้งหมด, count(employee_id) as ผูกพนักงานอยู่, count(employee_name) as มีชื่อกำกับ from logs
union all select 'leaves',           count(*), count(employee_id), count(employee_name) from leaves
union all select 'ot_requests',      count(*), count(employee_id), count(employee_name) from ot_requests
union all select 'notifications',    count(*), count(employee_id), count(employee_name) from notifications
union all select 'branch_transfers', count(*), count(employee_id), count(employee_name) from branch_transfers;

select id, name, chat_id_checkinout, chat_id_facility, chat_id_leave_approval from branches order by name;
select * from branch_chat_backup order by branch_id;
