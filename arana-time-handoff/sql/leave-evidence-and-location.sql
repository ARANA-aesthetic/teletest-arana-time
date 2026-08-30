-- ARANA TIME — ฟีเจอร์ใหม่ฝั่งใบลา: เก็บพิกัด GPS ตอนยื่นลาป่วย/ลากิจ + เตือนหลักฐานการลาที่ยังไม่ครบ
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ — add column if not exists / create or replace)
--
-- ส่วนที่ทำในไฟล์นี้ (คู่กับโค้ดฝั่งแอปที่แก้ไปแล้วในไฟล์ teletest-arana-time.html):
-- 1) เพิ่มคอลัมน์เก็บพิกัดในตาราง leaves (location_lat, location_lng, location_address) — แอปจะกรอกให้เอง
--    ตอนพนักงานยื่นลาป่วย/ลากิจ (เต็มวัน+เป็นชั่วโมง) เท่านั้น ไม่มีในแอปฝั่งพนักงานเลย เห็นได้แค่ในข้อความ
--    Telegram ฝั่งอนุมัติเท่านั้น (สำหรับให้แอดมินตรวจสอบหลังบ้าน)
-- 2) ฟังก์ชันใหม่ send_missing_leave_evidence_reminder() — รันทุกวัน 23:30 น. เช็คใบลาป่วย/ลากิจ
--    (สถานะ pending หรือ approved เท่านั้น ไม่รวมที่ถูกปฏิเสธ) ที่ยัง "ไม่มีรูปหลักฐาน" (evidence_file_id
--    เป็น null) ไม่ว่าจะลาวันไหนก็ตาม (ค้างมาจากวันก่อนก็จะถูกเตือนซ้ำทุกวันจนกว่าจะแนบ) ส่งสรุปแยกตาม
--    สาขา เข้าห้อง Telegram "แจ้งผลอนุมัติใบลา" (chat_id_leave_approval) ของสาขานั้น ถ้าไม่มีใครค้างเลย
--    จะไม่ส่งข้อความให้สาขานั้น (เหมือนฟังก์ชันเตือนอื่นๆ ที่ข้ามถ้าไม่มีอะไรต้องแจ้ง)

-- 1) คอลัมน์พิกัด
alter table leaves add column if not exists location_lat double precision;
alter table leaves add column if not exists location_lng double precision;
alter table leaves add column if not exists location_address text;

-- 2) ฟังก์ชันเตือนหลักฐานการลาค้าง — รูปแบบข้อความ:
--   📍สาขา Back Office
--   🗓️วันที่ 30/08/2026
--
--   ▪️ยังไม่ได้ส่งหลักฐานการลา
--   ❌ณัฎฐากร (ออม) 30/08/2026
--   (บรรทัดวันที่บนสุดคือวันที่ส่งสรุปนี้ ส่วนวันที่หลังชื่อคือวันที่พนักงานลาจริง อาจคนละวันกันได้
--    ถ้าเป็นใบลาที่ค้างมาจากวันก่อน)
create or replace function send_missing_leave_evidence_reminder()
returns void
language plpgsql
security definer
as $$
declare
  v_token text;
  v_today date;
  v_branch record;
  v_row record;
  v_lines text[];
  v_count int;
  v_msg text;
  v_display_name text;
  v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_leave_approval from branches
    where chat_id_leave_approval is not null and chat_id_leave_approval != ''
  loop
    v_lines := array[]::text[];
    v_count := 0;
    for v_row in
      select e.name, e.nickname, l.from_date
      from leaves l
      join employees e on e.id = l.employee_id
      where e.branch_id = v_branch.id
        and l.kind in ('sick_cert','sick_nocert','personal_deduct','personal_nodeduct','hourly_sick','hourly_personal')
        and l.status in ('pending','approved')
        and l.evidence_file_id is null
      order by l.from_date
    loop
      v_count := v_count + 1;
      v_display_name := split_part(v_row.name, ' ', 1) || case when v_row.nickname is not null and v_row.nickname != '' then ' (' || v_row.nickname || ')' else '' end;
      v_lines := array_append(v_lines, '❌' || v_display_name || ' ' || to_char(v_row.from_date,'DD/MM/YYYY'));
    end loop;

    if v_count = 0 then continue; end if;

    v_msg := '📍สาขา ' || v_branch.name || E'\n🗓️วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n\n'
      || '▪️ยังไม่ได้ส่งหลักฐานการลา' || E'\n' || array_to_string(v_lines, E'\n');

    v_request_id := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_leave_approval, 'text', v_msg)
    );
    insert into telegram_send_log(fn_name, branch_name, chat_id, request_id)
      values ('send_missing_leave_evidence_reminder', v_branch.name, v_branch.chat_id_leave_approval, v_request_id);
  end loop;
end;
$$;

grant execute on function send_missing_leave_evidence_reminder() to anon;
select cron.schedule('missing-leave-evidence-reminder', '30 16 * * *', $$select send_missing_leave_evidence_reminder();$$);
-- หมายเหตุ: 16:30 UTC = 23:30 เวลาไทย

-- ทดสอบทันที (ไม่ต้องรอถึง 23:30):
-- select send_missing_leave_evidence_reminder();
-- select resolve_telegram_send_log();
-- select branch_name, status_code, response from telegram_send_log
--   where fn_name = 'send_missing_leave_evidence_reminder' order by created_at desc limit 10;
