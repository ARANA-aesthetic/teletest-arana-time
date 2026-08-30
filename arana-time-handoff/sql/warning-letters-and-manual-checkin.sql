-- ARANA TIME — เพิ่มระบบใบเตือนพนักงาน + เพิ่มเวลาเข้างานย้อนหลัง (ลืมสแกน)
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ — add column if not exists / create table if not exists)
--
-- ส่วนที่ทำในไฟล์นี้ (คู่กับโค้ดฝั่งแอปที่แก้ไปแล้วในไฟล์ teletest-arana-time.html):
-- 1) คอลัมน์ใหม่ในตาราง logs: manual_entry (bool), manual_by (text) — ใช้ตอนแอดมิน/HR เพิ่มเวลาเข้างาน
--    ย้อนหลังให้พนักงานที่ลืมสแกน (หน้า "ตรวจ" ปุ่ม "ลืมสแกน") ระบบจะคิดสาย 30 นาทีคงที่เสมอ ไม่คำนวณ
--    จากเวลาเข้ากะจริง (นโยบายลืมสแกน) ไม่ส่ง Telegram (ไม่ใช่การสแกนจริง) แต่บันทึก audit log ไว้
-- 2) ตารางใหม่ warning_letters — เก็บข้อมูลใบเตือนที่ HR บันทึกผ่านเมนู รายงาน → ใบเตือน
--    (การแนบเอกสาร/รูปใบเตือน ใช้วิธีเดียวกับหลักฐานใบลา คือส่งผ่าน Telegram central chat แล้วเก็บแค่
--    file_id ไว้เรียกดูภายหลัง ไม่ได้เก็บไฟล์ในฐานข้อมูลโดยตรง)
--
-- ★ หมายเหตุ: นี่คือ Stage 1 ของฟีเจอร์ใบเตือน (บันทึกข้อมูล + แนบรูป/เอกสาร + ดูรายละเอียด) — ส่วนที่ผู้ใช้
-- อยากได้เพิ่มเติมคือให้ระบบ "จัดวางแพทเทิร์นเอกสารเป็นไฟล์ PDF ตามฟอร์มจริงของบริษัท พร้อมลายเซ็นอิเล็กทรอนิกส์
-- และสลับชื่อบริษัท/โลโก้ได้ (มี 2 บริษัทในเครือ)" ยังไม่ได้ทำในรอบนี้ เป็นงานที่ใหญ่และควรทำแยกเป็นอีกรอบ
-- (ต้องใช้ไลบรารีสร้าง PDF + ระบบเซ็นลายมือบน canvas + ออกแบบให้ตรงฟอร์มจริงที่ user ส่งตัวอย่างมาให้)

-- 1) คอลัมน์ manual_entry / manual_by ในตาราง logs
alter table logs add column if not exists manual_entry boolean default false;
alter table logs add column if not exists manual_by text;

-- 2) ตาราง warning_letters
create table if not exists warning_letters (
  id text primary key,
  employee_id text references employees(id) on delete set null,
  subject text,
  issued_date date not null,
  details text,
  punishment text default 'verbal',
  warning_number int default 1,
  evidence_file_id text,
  issued_by text,
  created_at timestamptz not null default now()
);

alter table warning_letters enable row level security;
create policy "allow anon full access" on warning_letters for all using (true) with check (true);
