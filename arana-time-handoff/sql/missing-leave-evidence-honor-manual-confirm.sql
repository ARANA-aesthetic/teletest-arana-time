-- ARANA TIME — ให้เตือน "ยังไม่ได้ส่งหลักฐานการลา" (23:30) เคารพการยืนยันด้วยมือของ HR ด้วย
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- ที่มา: 14 ก.ย. 69 เคสณิชกานต์ (ใบลาป่วย sick_cert วันที่ 09/09/2026) — พนักงานส่งรูปหลักฐานเข้ากลุ่ม
-- เทเลแกรมโดยตรง (พิมพ์/แนบเองในแชท) ไม่ได้ผ่านปุ่ม "แนบหลักฐานภายหลัง" ในแอป ทำให้ระบบไม่มีทางรู้ว่า
-- มีการส่งแล้ว เพราะ evidence_file_id เก็บได้เฉพาะตอนแอปเป็นคนส่งรูปเข้า Telegram เองเท่านั้น (ต้องใช้
-- ค่า file_id ที่ Telegram ตอบกลับมาตอนนั้น) ระบบจึงยังแจ้งเตือนว่า "ยังไม่ได้ส่งหลักฐาน" ทุกคืนต่อไปเรื่อยๆ
--
-- แก้โดยเพิ่มเงื่อนไข coalesce(evidence_sent, false) = false เข้าไปด้วย (เดิมเช็คแค่ evidence_file_id
-- is null อย่างเดียว) ทำให้ HR ยืนยันด้วยมือได้ (ตั้งค่า evidence_sent = true ในแถวใบลานั้นตรงๆ) โดยไม่ต้อง
-- มี evidence_file_id จริงก็ได้ — ใช้สำหรับกรณีพนักงานส่งหลักฐานนอกช่องทางแอปแบบนี้โดยเฉพาะ
--
-- แก้ไขข้อมูลของเคสณิชกานต์ไปแล้วพร้อมกัน (update leaves set evidence_sent = true where id =
-- '0a954d30-f9eb-4a5a-a9e2-d7dd744098b5') และบันทึกไว้ใน audit_log ด้วยว่าเป็นการยืนยันด้วยมือ
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
        and coalesce(l.evidence_sent, false) = false
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
