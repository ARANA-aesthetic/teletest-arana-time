-- ARANA TIME — หยุดแจ้งเตือน "ยังไม่ได้ส่งหลักฐานการลา" สำหรับใบลาที่นำเข้าย้อนหลัง (ม.ค.-ส.ค. 2569)
-- รันเองผ่าน Supabase SQL Editor โดยตรง (connector หลุดจากเซสชันนี้ชั่วคราวตอนแก้) — เก็บไฟล์นี้
-- ไว้เป็นบันทึกในโปรเจกต์เหมือนไฟล์อื่นๆ ในโฟลเดอร์นี้
--
-- ที่มา: คืนวันที่ 11 ก.ย. 69 เวลา 23:00 น. กลุ่มเทเลแกรมสาขาได้รับแจ้งเตือนว่าพนักงานยังไม่ส่ง
-- หลักฐานการลา แต่รายการที่ขึ้นเป็นใบลาที่เพิ่งนำเข้าย้อนหลังของช่วง ม.ค.-ส.ค. 2569 (จากไฟล์ Google
-- Sheet เดิมก่อนมีระบบนี้) ซึ่งไม่มีทางมีรูปหลักฐานให้แนบอยู่แล้วตั้งแต่ต้น เพราะเป็นข้อมูลเก่า
--
-- ต้นเหตุ: send_missing_leave_evidence_reminder() เดิมเช็คใบลาที่ evidence_file_id is null
-- โดยไม่จำกัดช่วงวันที่เลย จึงจับรวมใบลาย้อนหลังทุกใบที่นำเข้าไปด้วย และจะแจ้งซ้ำทุกคืนไม่มีที่สิ้นสุด
--
-- แก้โดยเพิ่มเงื่อนไข l.from_date >= settings.attendance_start_date (คอลัมน์เดียวกับที่ตั้งไว้แก้ปัญหา
-- ขาดงานเท็จก่อนหน้านี้ ปัจจุบันตั้งเป็น 2026-09-01) — ใบลาก่อนวันนี้จะไม่ถูกแจ้งเตือนเรื่องหลักฐานอีก
-- ส่วนใบลาจริงตั้งแต่ 1 ก.ย. 69 เป็นต้นไปยังคงแจ้งเตือนตามปกติทุกอย่างเหมือนเดิม ไม่กระทบ
--
-- หมายเหตุ: ถ้าวันไหนย้าย/ล้างค่า attendance_start_date (เช่นนำเข้าประวัติ ม.ค.-ส.ค. ครบสมบูรณ์แล้ว)
-- ฟังก์ชันนี้จะกลับไปแจ้งเตือนใบลาช่วงนั้นตามปกติทันทีเช่นกัน เพราะอิงค่าเดียวกัน
CREATE OR REPLACE FUNCTION public.send_missing_leave_evidence_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_token text;
  v_today date;
  v_data_start date;
  v_branch record;
  v_row record;
  v_lines text[];
  v_count int;
  v_msg text;
  v_display_name text;
  v_request_id bigint;
begin
  select central_token, attendance_start_date into v_token, v_data_start from settings where id = 1;
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
        and (v_data_start is null or l.from_date >= v_data_start)
      order by l.from_date
    loop
      v_count := v_count + 1;
      v_display_name := split_part(v_row.name, ' ', 1) || case when v_row.nickname is not null and v_row.nickname != '' then ' (' || v_row.nickname || ')' else '' end;
      v_lines := array_append(v_lines, '❌' || v_display_name || ' ' || to_char(v_row.from_date,'DD/MM/YYYY'));
    end loop;

    if v_count = 0 then continue; end if;

    v_msg := '📍สาขา ' || v_branch.name || E'\n🗓️วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n\n'
      || '▪️ยังไม่ได้ส่งหลักฐานการลา' || E'\n' || array_to_string(v_lines, E'\n');

    perform tg_send('send_missing_leave_evidence_reminder', v_branch.name, v_branch.chat_id_leave_approval, v_msg);
  end loop;
end;
$function$;
