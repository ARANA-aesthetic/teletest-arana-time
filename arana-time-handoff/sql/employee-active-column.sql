-- ARANA TIME — เพิ่มคอลัมน์สำหรับฟีเจอร์ "ปิดการใช้งาน" พนักงาน (แทนการลบ)
-- รันใน Supabase SQL Editor

alter table employees add column if not exists active boolean default true;
