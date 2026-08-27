-- ARANA TIME — เพิ่มคอลัมน์ group_id ให้ ot_requests (#29/30 ขอ OT หลายคนพร้อมกัน)
-- รันใน Supabase SQL Editor

alter table ot_requests add column if not exists group_id text;
