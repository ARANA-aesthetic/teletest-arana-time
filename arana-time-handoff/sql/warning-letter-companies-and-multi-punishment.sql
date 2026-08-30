-- ARANA TIME — บริษัทในเครือ (สำหรับสลับโลโก้/ชื่อตอนออกเอกสาร) + ระดับโทษเลือกได้หลายข้อ
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ — add column if not exists / create table if not exists)
--
-- ส่วนที่ทำในไฟล์นี้:
-- 1) ตารางใหม่ companies — เก็บชื่อ+โลโก้ (base64) ของแต่ละบริษัทในเครือ จัดการเองได้จากหน้าตั้งค่า
--    → คนและสิทธิ์ → "บริษัทในเครือ" (เพิ่ม/ลบเองได้ ไม่ต้องให้ผู้พัฒนาแก้โค้ด — ตามที่ user ขอไว้เผื่อ
--    อนาคตมีการปรับเปลี่ยน) โลโก้เก็บเป็น base64 ตรงในตาราง (ไม่ผ่าน Telegram แบบรูปหลักฐานอื่นๆ เพราะ
--    ต้องใช้ข้อมูลรูปจริงตอนสร้าง PDF ในสเตจถัดไป การอ้างอิงผ่าน Telegram file_id จะต้องดึงข้อมูลรูปทุก
--    ครั้งที่สร้างเอกสาร ช้าและซับซ้อนกว่าเก็บ base64 ไว้ตรงๆ)
-- 2) ตาราง warning_letters เพิ่มคอลัมน์ company_id (อ้างอิงบริษัทที่เลือกตอนออกใบเตือน) และ punishments
--    (jsonb array — เปลี่ยนจาก punishment เดิม (text ค่าเดียว) เป็นเลือกได้หลายข้อพร้อมกันตามที่ user ขอ)
--    คอลัมน์ punishment เดิมยังคงอยู่เฉยๆ ไม่ได้ลบ (ไม่กระทบข้อมูลเก่า โค้ดฝั่งแอปอ่าน fallback จากคอลัมน์
--    เดิมให้อัตโนมัติถ้าแถวไหนยังไม่มีค่าใน punishments)

-- 1) ตารางบริษัทในเครือ
create table if not exists companies (
  id text primary key,
  name text,
  logo_base64 text,
  created_at timestamptz not null default now()
);
alter table companies enable row level security;
create policy "allow anon full access" on companies for all using (true) with check (true);

-- 2) คอลัมน์เพิ่มในตาราง warning_letters
alter table warning_letters add column if not exists company_id text references companies(id) on delete set null;
alter table warning_letters add column if not exists punishments jsonb;
