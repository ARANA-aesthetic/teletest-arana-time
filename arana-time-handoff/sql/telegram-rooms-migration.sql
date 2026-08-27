-- ARANA TIME — เพิ่มคอลัมน์สำหรับระบบแยกห้อง Telegram
-- รันใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ ไม่ลบข้อมูลเดิม)

-- 1) branches: เพิ่ม 3 ห้องแยกตามสาขา
alter table branches add column if not exists chat_id_checkinout text;
alter table branches add column if not exists chat_id_facility text;
alter table branches add column if not exists chat_id_leave_approval text;

-- ย้ายค่าเดิมจากคอลัมน์ chat_id (ถ้ามี) มาเป็นห้องเช็กอิน-เอาท์ให้อัตโนมัติ
-- (สาขาที่เคยตั้งค่าไว้แล้วจะไม่ต้องตั้งใหม่ทั้งหมด แค่ไปเพิ่มอีก 2 ห้องที่เหลือ)
update branches set chat_id_checkinout = chat_id
  where chat_id is not null and chat_id != '' and (chat_id_checkinout is null or chat_id_checkinout = '');

-- 2) leaves: เพิ่มคอลัมน์เก็บ file_id ของรูปหลักฐาน (ใช้ส่งซ้ำตอนอนุมัติ โดยไม่ต้องอัปโหลดใหม่)
alter table leaves add column if not exists evidence_file_id text;

-- 3) settings: เพิ่มคอลัมน์เก็บรายการ "ห้อง Telegram เพิ่มเติม" สำหรับใช้ในอนาคต
alter table settings add column if not exists telegram_rooms jsonb default '[]';
