-- ARANA TIME — เตือน "ยังไม่ได้ส่งหลักฐานการลา" (23:30) ให้รอถึงวันลาก่อนค่อยเริ่มเตือน
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- ที่มา: 15 ก.ย. 69 พบว่าฟังก์ชันเดิมไม่เช็คว่าถึงวันลาหรือยังเลย — พนักงานยื่นลาล่วงหน้าไว้นานๆ
-- (เช่น ลากิจไปธุระที่ยื่นล่วงหน้า 2-3 สัปดาห์) จะโดนเตือนว่า "ยังไม่ส่งหลักฐาน" ตั้งแต่คืนแรกที่ยื่นทันที
-- ทั้งที่ตามธรรมชาติยังไม่ถึงเวลาต้องมีหลักฐานเลย (บางประเภทลาก็ไม่รู้ล่วงหน้าด้วยซ้ำว่าจะมีหลักฐานอะไร)
--
-- แก้โดยเพิ่มเงื่อนไข l.from_date <= v_today (วันนี้ตามเวลาไทย) — จะเริ่มเตือนตั้งแต่คืนของ "วันแรก
-- ที่ลา" เป็นต้นไป (ตามที่ user ยืนยัน "เตือนตั้งแต่คืนวันแรกของวันที่ลาเลย เผื่อพนักงานจะลืม จะได้หา
-- หลักฐานมาแนบได้") ไม่ใช่รอจนวันสุดท้ายของช่วงลา — ก่อนถึงวันลาจะยังไม่เตือนเลย
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
        and l.from_date <= v_today
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
