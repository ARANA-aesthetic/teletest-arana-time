-- ตรวจสอบว่าทำไมสาขาแม่สอดไม่ได้รับแจ้งเตือน 11:30 น.
-- รันทีละคำสั่งใน SQL Editor แล้วดูผลลัพธ์

-- 1) เช็กว่าสาขาแม่สอดตั้ง Chat ID (กลุ่มปิดแอร์/ความสะอาด/ความเรียบร้อย) ไว้หรือยัง
select id, name, chat_id_facility, jsonb_array_length(coalesce(cleaning_points,'[]'::jsonb)) as จำนวนจุดความสะอาด
from branches
where name ilike '%แม่สอด%';

-- ถ้า chat_id_facility เป็นค่าว่างหรือ null = สาเหตุคือยังไม่ได้ตั้งค่าห้องนี้ในแอป (หน้าตั้งค่า > สาขา)
-- ถ้าจำนวนจุดความสะอาดเป็น 0 และไม่มีพนักงานแผนกหน้าร้าน = ฟังก์ชันจะข้ามสาขานี้ไปเลยตามที่ตั้งใจไว้ (ไม่ถือเป็นบั๊ก)

-- 2) เช็กว่ามีพนักงานแผนก "หน้าร้าน" ที่สาขาแม่สอดไหม
select e.name, e.department, b.name as สาขา
from employees e
join branches b on b.id = e.branch_id
where b.name ilike '%แม่สอด%';

-- 3) ทดสอบยิงฟังก์ชันเองตรงๆ (ไม่ต้องรอถึงเวลา) แล้วดู error ถ้ามี
select send_facility_missing_reminder();
