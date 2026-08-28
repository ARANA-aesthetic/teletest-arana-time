-- ARANA TIME — เก็บ "ชื่อพนักงาน" ติดไว้กับทุกรายการ กันประวัติหลุดเมื่อพนักงานถูกลบ
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ ไม่มีคำสั่งลบข้อมูลใดๆ)
--
-- ที่มาของปัญหา (เกิดจริงเมื่อ 28 ส.ค. 2569 เวลา 09:47 น.):
-- ตาราง logs / leaves / ot_requests / notifications / branch_transfers ผูกกับ employees
-- ด้วย foreign key แบบ ON DELETE SET NULL (ตั้งไว้ในไฟล์ fix-employee-delete-fk-v2.sql
-- เพื่อให้ลบพนักงานได้โดยประวัติไม่หายไปด้วย) แต่ผลข้างเคียงคือ "ตัวประวัติยังอยู่ แต่ไม่รู้
-- ว่าเป็นของใคร" — พอมีการลบแล้วสร้างพนักงานใหม่ทั้ง 31 คนพร้อมกัน ทำให้ employee_id
-- ของประวัติเก่าทั้งหมดกลายเป็นค่าว่างในทันที (logs 1,222 / leaves 51 / ot 15 / noti 1,331)
-- รายงานสรุปจึงว่างเปล่าทั้งที่ข้อมูลยังอยู่ครบทุกแถว
--
-- วิธีแก้: เพิ่มคอลัมน์ employee_name เก็บ "ชื่อ ณ ตอนบันทึก" ไว้กับแถวนั้นเลย
-- ต่อไปถ้า employee_id หลุดอีก ก็ยังรู้ว่าเป็นของใคร และเอากลับมาผูกใหม่ได้
-- ใส่ค่าให้อัตโนมัติด้วย trigger ฝั่งฐานข้อมูล จึงไม่ต้องแก้โค้ดแอปและไม่มีทางลืมใส่

-- 1) เพิ่มคอลัมน์ (ถ้ายังไม่มี)
alter table logs             add column if not exists employee_name text;
alter table leaves           add column if not exists employee_name text;
alter table ot_requests      add column if not exists employee_name text;
alter table notifications    add column if not exists employee_name text;
alter table branch_transfers add column if not exists employee_name text;

-- 2) เติมชื่อย้อนหลังเท่าที่ยังผูกกันได้อยู่ (แถวที่ employee_id หลุดไปแล้วจะยังว่าง
--    ต้องกู้จากแหล่งอื่น เช่น ข้อความในกลุ่ม Telegram แล้วนำเข้าผ่านหน้าตั้งค่า)
update logs             t set employee_name = e.name from employees e where t.employee_id = e.id and t.employee_name is null;
update leaves           t set employee_name = e.name from employees e where t.employee_id = e.id and t.employee_name is null;
update ot_requests      t set employee_name = e.name from employees e where t.employee_id = e.id and t.employee_name is null;
update notifications    t set employee_name = e.name from employees e where t.employee_id = e.id and t.employee_name is null;
update branch_transfers t set employee_name = e.name from employees e where t.employee_id = e.id and t.employee_name is null;

-- 3) ใส่ชื่อให้อัตโนมัติทุกครั้งที่มีการบันทึกแถวใหม่
create or replace function arana_fill_employee_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.employee_name is null and new.employee_id is not null then
    select name into new.employee_name from employees where id = new.employee_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_fill_employee_name on logs;
create trigger trg_fill_employee_name before insert or update of employee_id on logs
  for each row execute function arana_fill_employee_name();

drop trigger if exists trg_fill_employee_name on leaves;
create trigger trg_fill_employee_name before insert or update of employee_id on leaves
  for each row execute function arana_fill_employee_name();

drop trigger if exists trg_fill_employee_name on ot_requests;
create trigger trg_fill_employee_name before insert or update of employee_id on ot_requests
  for each row execute function arana_fill_employee_name();

drop trigger if exists trg_fill_employee_name on notifications;
create trigger trg_fill_employee_name before insert or update of employee_id on notifications
  for each row execute function arana_fill_employee_name();

drop trigger if exists trg_fill_employee_name on branch_transfers;
create trigger trg_fill_employee_name before insert or update of employee_id on branch_transfers
  for each row execute function arana_fill_employee_name();

-- 4) ตรวจผลหลังรัน — ควรได้ตัวเลข "มีชื่อ" เท่ากับจำนวนแถวที่ employee_id ยังไม่หลุด
select 'logs' as ตาราง, count(*) as ทั้งหมด,
       count(employee_id) as ผูกพนักงานอยู่, count(employee_name) as มีชื่อกำกับ from logs
union all select 'leaves',           count(*), count(employee_id), count(employee_name) from leaves
union all select 'ot_requests',      count(*), count(employee_id), count(employee_name) from ot_requests
union all select 'notifications',    count(*), count(employee_id), count(employee_name) from notifications
union all select 'branch_transfers', count(*), count(employee_id), count(employee_name) from branch_transfers;
