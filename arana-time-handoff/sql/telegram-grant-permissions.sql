-- ต้องรันไฟล์นี้เพิ่ม เพื่อให้ปุ่มทดสอบในแอปเรียกใช้ฟังก์ชันได้
-- (ค่าเริ่มต้น Supabase จะไม่อนุญาตให้เรียกฟังก์ชันจากภายนอกจนกว่าจะ grant สิทธิ์)
-- รันหลังจาก telegram-scheduled-reminders.sql เสร็จแล้ว

grant execute on function send_daily_leave_summary() to anon;
grant execute on function send_ac_missing_reminder() to anon;
grant execute on function send_facility_missing_reminder() to anon;
