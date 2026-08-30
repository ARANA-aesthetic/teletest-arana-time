-- ARANA TIME — Stage 2b: เซ็นใบเตือนออนไลน์จากแท็บเล็ต
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ — add column if not exists)
--
-- เพิ่มคอลัมน์ signatures (jsonb) เก็บลายเซ็นทั้ง 3 คน รูปแบบ:
-- {"employee": {"img": "data:image/png;base64,...", "date": "2026-08-30"},
--  "manager":  {"img": "...", "date": "..."},
--  "owner":    {"img": "...", "date": "..."}}
-- แต่ละคนไม่ต้องล็อกอินแยก ใช้วิธีส่งต่อแท็บเล็ตเครื่องเดียวให้เซ็นทีละคน (เหมือนกระดาษเดิม)
-- รูปลายเซ็นเก็บเป็น base64 ตรงในตาราง (แบบเดียวกับโลโก้บริษัท) เพื่อใช้ฝังลงหน้าปริ้น/PDF ได้ทันที

alter table warning_letters add column if not exists signatures jsonb default '{}'::jsonb;
