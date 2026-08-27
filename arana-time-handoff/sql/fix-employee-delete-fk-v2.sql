-- ARANA TIME — แก้ปัญหาลบพนักงานถาวรไม่ได้ (foreign key constraint) — เวอร์ชันแก้ไข
-- เพิ่มขั้นตอนล้างข้อมูลเก่าที่ผูกกับพนักงานซึ่งถูกลบไปแล้วก่อนหน้านี้ (employee_id ที่ไม่มีอยู่จริงแล้ว)
-- รันใน Supabase SQL Editor ปลอดภัย รันซ้ำได้

-- 1) ล้างข้อมูลกำพร้า (employee_id ที่ไม่มีอยู่ในตาราง employees แล้ว) ให้เป็นค่าว่างก่อน
update leaves set employee_id = null
  where employee_id is not null and employee_id not in (select id from employees);

update logs set employee_id = null
  where employee_id is not null and employee_id not in (select id from employees);

update ot_requests set employee_id = null
  where employee_id is not null and employee_id not in (select id from employees);

update notifications set employee_id = null
  where employee_id is not null and employee_id not in (select id from employees);

update branch_transfers set employee_id = null
  where employee_id is not null and employee_id not in (select id from employees);

-- 2) ตั้งกฎใหม่ ให้ลบพนักงานได้โดยประวัติเก่ายังอยู่ (employee_id จะกลายเป็นค่าว่างแทน)
alter table leaves drop constraint if exists leaves_employee_id_fkey;
alter table leaves add constraint leaves_employee_id_fkey
  foreign key (employee_id) references employees(id) on delete set null;

alter table logs drop constraint if exists logs_employee_id_fkey;
alter table logs add constraint logs_employee_id_fkey
  foreign key (employee_id) references employees(id) on delete set null;

alter table ot_requests drop constraint if exists ot_requests_employee_id_fkey;
alter table ot_requests add constraint ot_requests_employee_id_fkey
  foreign key (employee_id) references employees(id) on delete set null;

alter table notifications drop constraint if exists notifications_employee_id_fkey;
alter table notifications add constraint notifications_employee_id_fkey
  foreign key (employee_id) references employees(id) on delete set null;

alter table branch_transfers drop constraint if exists branch_transfers_employee_id_fkey;
alter table branch_transfers add constraint branch_transfers_employee_id_fkey
  foreign key (employee_id) references employees(id) on delete set null;
