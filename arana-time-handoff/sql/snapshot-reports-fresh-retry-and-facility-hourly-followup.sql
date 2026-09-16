-- ARANA TIME — แก้ retry ของรายงาน "สรุปสถานะ ณ ขณะนั้น" ให้คำนวณข้อมูลใหม่ก่อนส่งซ้ำ
-- + เพิ่มระบบเตือนซ้ำทุกชั่วโมงสำหรับปิดแอร์/ความสะอาด/ความเรียบร้อย จนกว่าจะครบ
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration หลายรอบ) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- ที่มา: 15 ก.ย. 69 กลุ่ม "ส่งตรวจ พิษณุโลก" ไม่ได้รับสรุป 11:30 ตรงเวลา แต่ได้รับตอน 11:35 แทน และ
-- ข้อมูลในนั้นบอกว่ายังไม่ครบ 13 จุด ทั้งที่พนักงานส่งเพิ่มไปแล้วเกือบครบในช่วง 5 นาทีนั้นพอดี
--
-- ต้นเหตุ (ตรวจจาก telegram_send_log จริง): การเชื่อมต่อ Telegram รอบ 11:30 หลุด/ช้าจนครบ 8 วินาที
-- ที่ตั้งไว้ (TCP/SSL handshake timeout พอดี) ระบบมีตัวกู้คืนอัตโนมัติอยู่แล้ว (resolve_telegram_send_log
-- ทำงานทุก 5 นาที) เจอรอบถัดไปแล้วส่งซ้ำให้ตอน 11:35 — ปัญหาคือ**ส่งซ้ำด้วยข้อความเดิมที่แต่งไว้ตั้งแต่
-- 11:30 เป๊ะๆ** ไม่ได้คำนวณใหม่ก่อนส่ง จึงกลายเป็นข้อมูลเก่าเมื่อมาถึงจริงตอน 11:35
--
-- แก้ 2 เรื่อง:
--
-- 1) ให้กลุ่มฟังก์ชัน "สรุปสถานะ ณ ขณะนั้น" (ต่างจากเหตุการณ์ตายตัวแบบอนุมัติลา/เช็กอิน ที่ retry ด้วย
--    ข้อความเดิมถูกต้องอยู่แล้ว) คำนวณข้อมูลใหม่ก่อน retry แทนการส่งซ้ำข้อความเดิม — ได้แก่
--    send_facility_missing_reminder, send_missing_leave_evidence_reminder, send_daily_leave_summary,
--    send_hourly_leave_checkin_summary
--    ทำโดยเพิ่มพารามิเตอร์ p_branch_id (optional) ให้ทั้ง 4 ฟังก์ชัน + เพิ่มคอลัมน์ branch_id ใน
--    telegram_send_log + เพิ่มพารามิเตอร์ p_branch_id ให้ tg_send (optional, ของเดิม 4 อาร์กิวเมนต์
--    ยังใช้ได้ปกติกับฟังก์ชันอื่นที่ไม่เกี่ยว) แล้วแก้ resolve_telegram_send_log ให้เช็ค fn_name อยู่ใน
--    กลุ่มนี้แล้วมี branch_id → เรียกฟังก์ชันเดิมซ้ำแบบเจาะจงสาขาแทนการยิง HTTP ซ้ำด้วยข้อความเก่า
--
--    ระวัง: ตอนแรกใช้ CREATE OR REPLACE เพิ่มพารามิเตอร์เข้าไป กลายเป็นสร้างฟังก์ชันซ้อน (overload) ใหม่
--    ขึ้นมาแทนที่จะแทนที่ของเดิม เพราะ Postgres ถือว่า signature ต่างกัน — ฟังก์ชันเดิมแบบไม่มีอาร์กิวเมนต์
--    (ที่ pg_cron เรียกอยู่ทุกวัน) เลยยังใช้โค้ดเก่าอยู่ ต้อง DROP FUNCTION แบบไม่มีอาร์กิวเมนต์ทิ้งไปด้วย
--    ให้เหลือแค่ตัวใหม่ (มี default ทุกพารามิเตอร์ ยังเรียกแบบไม่ใส่อาร์กิวเมนต์ได้เหมือนเดิม)
--
-- 2) เพิ่ม cron job ใหม่ (facility-missing-hourly-followup, ทุกชั่วโมงเวลา 12:30-20:30 ตามเวลาไทย)
--    เรียก send_facility_missing_reminder(null, true) — พารามิเตอร์ที่ 2 (p_skip_if_complete) ทำให้
--    ข้ามสาขาที่ครบทุกจุดแล้วเงียบๆ ไม่ส่งซ้ำอีก จะส่งเฉพาะสาขาที่ยังขาดอยู่จริงเท่านั้น ทุกชั่วโมงจนกว่า
--    จะครบ ตามที่ user ขอ (กันพนักงาน ignore หรือปล่อยให้เป็นหน้าที่คนอื่นเมื่อคนที่รับผิดชอบเดิมลา)
--    รอบ 11:30 ปกติ (จาก cron เดิม) ยังคงส่งสรุปทุกวันเหมือนเดิมไม่ว่าจะครบหรือไม่ครบ

alter table telegram_send_log add column if not exists branch_id text;

CREATE OR REPLACE FUNCTION public.tg_send(p_fn text, p_branch text, p_chat text, p_msg text, p_branch_id text default null)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_token text;
  v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' or p_chat is null or p_chat = '' then return null; end if;
  v_request_id := net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('chat_id', p_chat, 'text', p_msg),
    timeout_milliseconds := 8000
  );
  insert into telegram_send_log(fn_name, branch_name, chat_id, request_id, message_text, branch_id)
    values (p_fn, p_branch, p_chat, v_request_id, p_msg, p_branch_id);
  return v_request_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.send_facility_missing_reminder(p_branch_id text default null, p_skip_if_complete boolean default false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_token text; v_today date; v_branch record; v_point record; v_emp record;
  v_clean_missing text[]; v_clean_total int;
  v_groom_missing text[]; v_groom_total int;
  v_msg text; v_done boolean; v_on_leave boolean;
  v_display_name text; v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, cleaning_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
      and (p_branch_id is null or id = p_branch_id)
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;
    v_clean_missing := array[]::text[]; v_clean_total := 0;
    v_groom_missing := array[]::text[]; v_groom_total := 0;

    for v_point in select value->>'id' as pid, value->>'name' as pname
      from jsonb_array_elements(coalesce(v_branch.cleaning_points,'[]'::jsonb)) loop
      v_clean_total := v_clean_total + 1;
      select exists(select 1 from logs where branch_id = v_branch.id and type = 'CLEAN'
        and clean_point_id = v_point.pid
        and (time at time zone 'Asia/Bangkok')::date = v_today) into v_done;
      if not v_done then v_clean_missing := array_append(v_clean_missing, v_point.pname); end if;
    end loop;

    for v_emp in select id, name, nickname from employees
      where branch_id = v_branch.id and department = 'หน้าร้าน'
        and coalesce(active, true) = true
        and (start_date is null or start_date <= v_today)
        and (resign_date is null or resign_date >= v_today)
    loop
      select exists(select 1 from leaves where employee_id = v_emp.id and status = 'approved'
        and from_date <= v_today and to_date >= v_today) into v_on_leave;
      if v_on_leave then continue; end if;

      v_groom_total := v_groom_total + 1;
      select exists(select 1 from logs where branch_id = v_branch.id and type = 'GROOM'
        and employee_id = v_emp.id
        and (time at time zone 'Asia/Bangkok')::date = v_today) into v_done;
      if not v_done then
        v_display_name := split_part(v_emp.name, ' ', 1) ||
          case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
        v_groom_missing := array_append(v_groom_missing, v_display_name);
      end if;
    end loop;

    if v_clean_total = 0 and v_groom_total = 0 then continue; end if;
    if p_skip_if_complete and coalesce(array_length(v_clean_missing,1),0) = 0
       and coalesce(array_length(v_groom_missing,1),0) = 0 then continue; end if;

    v_msg := '📍สาขา ' || v_branch.name || E'\n🗓️วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n\n';
    if v_clean_total = 0 then
      v_msg := v_msg || '▪️ส่งความสะอาด' || E'\n-ไม่มี-';
    elsif array_length(v_clean_missing,1) > 0 then
      v_msg := v_msg || '▪️ส่งความสะอาด' || E'\n❌ไม่ครบ (' || array_length(v_clean_missing,1) || ' จุด)' || E'\n' ||
        (select string_agg('⛔' || x, E'\n') from unnest(v_clean_missing) as x);
    else
      v_msg := v_msg || '▪️ส่งความสะอาด' || E'\n✅ครบแล้ว (' || v_clean_total || ' จุด)';
    end if;

    v_msg := v_msg || E'\n\n';

    if v_groom_total = 0 then
      v_msg := v_msg || '▪️ความเรียบร้อย' || E'\n-ไม่มี-';
    elsif array_length(v_groom_missing,1) > 0 then
      v_msg := v_msg || '▪️ความเรียบร้อย' || E'\n❌ไม่ครบ (' || array_length(v_groom_missing,1) || ' คน)' || E'\n' ||
        (select string_agg('⛔' || x, E'\n') from unnest(v_groom_missing) as x);
    else
      v_msg := v_msg || '▪️ความเรียบร้อย' || E'\n✅ครบแล้ว (' || v_groom_total || ' คน)';
    end if;

    perform tg_send('send_facility_missing_reminder', v_branch.name, v_branch.chat_id_facility, v_msg, v_branch.id);
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.send_missing_leave_evidence_reminder(p_branch_id text default null)
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
      and (p_branch_id is null or id = p_branch_id)
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

    perform tg_send('send_missing_leave_evidence_reminder', v_branch.name, v_branch.chat_id_leave_approval, v_msg, v_branch.id);
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.send_daily_leave_summary(p_branch_id text default null)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_token text;
  v_today date;
  v_branch record;
  v_emp record;
  v_leave_lines text[];
  v_late_lines text[];
  v_leave_count int;
  v_late_count int;
  v_msg text;
  v_days int;
  v_hours numeric;
  v_display_name text;
  v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_checkinout from branches
    where chat_id_checkinout is not null and chat_id_checkinout != ''
      and (p_branch_id is null or id = p_branch_id)
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;

    v_leave_lines := array[]::text[];
    v_leave_count := 0;
    for v_emp in
      select e.name, e.nickname, l.kind, l.from_date, l.to_date, l.from_time, l.to_time
      from leaves l
      join employees e on e.id = l.employee_id
      where e.branch_id = v_branch.id
        and l.status = 'approved'
        and l.from_date <= v_today and l.to_date >= v_today
      order by e.name
    loop
      v_leave_count := v_leave_count + 1;
      v_display_name := split_part(v_emp.name, ' ', 1) || case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
      if v_emp.kind in ('hourly_sick','hourly_personal') then
        v_hours := extract(epoch from (v_emp.to_time::time - v_emp.from_time::time)) / 3600.0;
        v_leave_lines := array_append(v_leave_lines,
          v_leave_count || '. ' || v_display_name || ' ลาเป็นชั่วโมง (' ||
          case v_emp.kind when 'hourly_sick' then 'ป่วย' else 'กิจ' end || ') ' || round(v_hours,1) || ' ชม.');
      else
        v_days := (v_emp.to_date - v_emp.from_date) + 1;
        v_leave_lines := array_append(v_leave_lines,
          v_leave_count || '. ' || v_display_name || ' ' ||
          case v_emp.kind
            when 'sick_cert' then 'ลาป่วย(มีใบรับรองแพทย์)'
            when 'sick_nocert' then 'ลาป่วย(ไม่มีใบรับรองแพทย์)'
            when 'personal_nodeduct' then 'ลากิจ(ไม่หักเงิน)'
            when 'personal_deduct' then 'ลากิจ(หักเงิน)'
            when 'traditional' then 'ลาใช้สิทธิ์วันหยุดประเพณี'
            when 'vacation' then 'ลาพักร้อน'
            when 'maternity' then 'ลาคลอด'
            else v_emp.kind
          end || ' ' || v_days || ' วัน');
      end if;
    end loop;

    v_late_lines := array[]::text[];
    v_late_count := 0;
    for v_emp in
      select e.name, e.nickname, l.late_minutes
      from logs l
      join employees e on e.id = l.employee_id
      where l.branch_id = v_branch.id and l.type = 'IN' and l.late_minutes > 0
        and (l.time at time zone 'Asia/Bangkok')::date = v_today
      order by l.late_minutes asc, e.name
    loop
      v_late_count := v_late_count + 1;
      v_display_name := split_part(v_emp.name, ' ', 1) || case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
      v_late_lines := array_append(v_late_lines, v_late_count || '. ' || v_display_name || ' ' || v_emp.late_minutes || ' นาที');
    end loop;

    v_msg := '📍สาขา ' || v_branch.name || E'\n🗓️วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n\n'
      || '▪️ลางาน ' || v_leave_count || ' คน' || E'\n'
      || '▪️มาสาย ' || v_late_count || ' คน';
    if v_leave_count > 0 then
      v_msg := v_msg || E'\n\n⛔ลางาน\n' || array_to_string(v_leave_lines, E'\n');
    end if;
    if v_late_count > 0 then
      v_msg := v_msg || E'\n\n⛔มาสาย\n' || array_to_string(v_late_lines, E'\n');
    end if;

    perform tg_send('send_daily_leave_summary', v_branch.name, v_branch.chat_id_checkinout, v_msg, v_branch.id);
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.send_hourly_leave_checkin_summary(p_branch_id text default null)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_token text;
  v_today date;
  v_branch record;
  v_emp record;
  v_late_lines text[];
  v_notyet_lines text[];
  v_late_count int;
  v_notyet_count int;
  v_hourly_count int;
  v_msg text;
  v_in_log record;
  v_display_name text;
  v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_checkinout from branches
    where chat_id_checkinout is not null and chat_id_checkinout != ''
      and (p_branch_id is null or id = p_branch_id)
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;

    v_hourly_count := 0;
    v_late_lines := array[]::text[];
    v_late_count := 0;
    v_notyet_lines := array[]::text[];
    v_notyet_count := 0;

    for v_emp in
      select e.id, e.name, e.nickname
      from leaves l
      join employees e on e.id = l.employee_id
      where e.branch_id = v_branch.id
        and l.status = 'approved'
        and l.kind in ('hourly_sick','hourly_personal')
        and l.from_date = v_today
    loop
      v_hourly_count := v_hourly_count + 1;
      v_display_name := split_part(v_emp.name, ' ', 1) || case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
      select late_minutes into v_in_log
        from logs
        where employee_id = v_emp.id and type = 'IN'
          and (time at time zone 'Asia/Bangkok')::date = v_today
        limit 1;
      if found then
        if v_in_log.late_minutes > 0 then
          v_late_count := v_late_count + 1;
          v_late_lines := array_append(v_late_lines, v_late_count || '. ' || v_display_name || ' ' || v_in_log.late_minutes || ' นาที');
        end if;
      else
        v_notyet_count := v_notyet_count + 1;
        v_notyet_lines := array_append(v_notyet_lines, v_notyet_count || '. ' || v_display_name);
      end if;
    end loop;

    if v_hourly_count = 0 then continue; end if;

    v_msg := 'วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n' || 'สาขา ' || v_branch.name || E'\n\n'
      || '▪️ลาเป็นชั่วโมง ' || (case when v_late_count = 0 and v_notyet_count = 0 then '✅มาครบ' else '' end) || E'\n'
      || '▪️มาสาย ' || v_late_count || ' คน';
    if v_late_count > 0 then
      v_msg := v_msg || E'\n\n⛔มาสาย\n' || array_to_string(v_late_lines, E'\n');
    end if;
    if v_notyet_count > 0 then
      v_msg := v_msg || E'\n\n❓ยังไม่เช็กอินเข้างาน\n' || array_to_string(v_notyet_lines, E'\n');
    end if;

    perform tg_send('send_hourly_leave_checkin_summary', v_branch.name, v_branch.chat_id_checkinout, v_msg, v_branch.id);
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_telegram_send_log()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_row record;
  v_resp record;
  v_token text;
  v_central text;
  v_new_request bigint;
  v_resolved int := 0;
  v_failed int := 0;
  v_retried int := 0;
  v_gave_up int := 0;
  v_alert text[] := array[]::text[];
  v_snapshot_fns text[] := array['send_facility_missing_reminder','send_missing_leave_evidence_reminder',
                                  'send_daily_leave_summary','send_hourly_leave_checkin_summary'];
begin
  select central_token, central_chat_id into v_token, v_central from settings where id = 1;

  for v_row in
    select * from telegram_send_log
    where resolved = false and gave_up = false and created_at > now() - interval '2 days'
  loop
    select status_code, content, error_msg, timed_out into v_resp
      from net._http_response where id = v_row.request_id;

    if v_resp.status_code = 200 then
      update telegram_send_log
        set status_code = 200, response = v_resp.content, resolved = true
        where id = v_row.id;
      v_resolved := v_resolved + 1;

    elsif v_resp.status_code is not null and v_resp.status_code <> 429 then
      update telegram_send_log
        set status_code = v_resp.status_code, response = v_resp.content, resolved = true, gave_up = true
        where id = v_row.id;
      v_failed := v_failed + 1;
      v_alert := array_append(v_alert, '• ' || v_row.fn_name || ' → ' || coalesce(v_row.branch_name,'-')
        || ' (ห้องปฏิเสธ รหัส ' || v_resp.status_code || ')');

    elsif v_resp.status_code = 429 or (v_resp.status_code is null and v_row.created_at < now() - interval '3 minutes') then
      if v_resp.error_msg is not null then
        update telegram_send_log set error_msg = v_resp.error_msg where id = v_row.id;
      end if;

      if v_row.created_at < now() - interval '2 hours' then
        update telegram_send_log set gave_up = true where id = v_row.id;
        v_gave_up := v_gave_up + 1;
        v_alert := array_append(v_alert, '• ' || v_row.fn_name || ' → ' || coalesce(v_row.branch_name,'-')
          || ' (ส่งไม่สำเร็จ เกินเวลาที่จะส่งย้อนหลัง)');
      elsif v_row.retry_count >= 5 or v_row.message_text is null or v_token is null or v_token = '' then
        update telegram_send_log set gave_up = true where id = v_row.id;
        v_gave_up := v_gave_up + 1;
        v_alert := array_append(v_alert, '• ' || v_row.fn_name || ' → ' || coalesce(v_row.branch_name,'-')
          || ' (ลองส่งซ้ำครบ ' || v_row.retry_count || ' ครั้งแล้วไม่สำเร็จ)');
      elsif v_row.fn_name = any(v_snapshot_fns) and v_row.branch_id is not null then
        update telegram_send_log set gave_up = true, resolved = true where id = v_row.id;
        execute format('select %I(%L)', v_row.fn_name, v_row.branch_id);
        v_retried := v_retried + 1;
      else
        if v_retried > 0 then perform pg_sleep(1.3); end if;
        v_new_request := net.http_post(
          url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
          headers := '{"Content-Type": "application/json"}'::jsonb,
          body := jsonb_build_object('chat_id', v_row.chat_id, 'text', v_row.message_text),
          timeout_milliseconds := 8000
        );
        update telegram_send_log
          set request_id = v_new_request, retry_count = v_row.retry_count + 1
          where id = v_row.id;
        v_retried := v_retried + 1;
      end if;
    end if;
  end loop;

  if array_length(v_alert,1) > 0 and v_token is not null and v_token <> '' and v_central is not null and v_central <> '' then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_central,
        'text', '⚠️ข้อความแจ้งเตือนส่งไม่สำเร็จ' || E'\n' || array_to_string(v_alert, E'\n')
                || E'\n\nกลุ่มที่ระบุไว้ข้างต้นไม่ได้รับข้อความรอบนี้ กรุณาแจ้งด้วยตนเอง'),
      timeout_milliseconds := 8000
    );
  end if;

  insert into system_heartbeat(name, last_run_at, detail)
    values ('resolve_telegram_send_log', now(),
            jsonb_build_object('resolved', v_resolved, 'failed', v_failed,
                               'retried', v_retried, 'gave_up', v_gave_up))
    on conflict (name) do update
      set last_run_at = excluded.last_run_at, detail = excluded.detail;

  return jsonb_build_object('resolved', v_resolved, 'failed', v_failed,
                            'retried', v_retried, 'gave_up', v_gave_up);
end;
$function$;

drop function if exists public.send_facility_missing_reminder();
drop function if exists public.send_missing_leave_evidence_reminder();
drop function if exists public.send_daily_leave_summary();
drop function if exists public.send_hourly_leave_checkin_summary();

select cron.schedule(
  'facility-missing-hourly-followup',
  '30 5-13 * * *',
  $$select send_facility_missing_reminder(null, true);$$
);
