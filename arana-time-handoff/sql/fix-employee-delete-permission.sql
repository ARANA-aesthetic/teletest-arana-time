-- ตรวจ/แก้สิทธิ์ DELETE บนตาราง employees (เผื่อเป็นสาเหตุที่ลบพนักงานไม่ได้จริง)
-- ปลอดภัย รันซ้ำได้

grant delete on table employees to anon;
grant delete on table branches to anon;
grant delete on table approvers to anon;

-- ทวนสอบว่า policy "for all" ครอบคลุม DELETE จริง (สร้างใหม่ทับถ้ายังไม่มี)
drop policy if exists "allow anon full access" on employees;
create policy "allow anon full access" on employees for all using (true) with check (true);
