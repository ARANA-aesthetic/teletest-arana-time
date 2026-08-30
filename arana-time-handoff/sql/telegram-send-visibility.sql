-- ARANA TIME — ทำให้เห็น error เวลาส่ง Telegram แจ้งเตือนอัตโนมัติไม่สำเร็จ
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ — create or replace / create table if not exists)
--
-- ปัญหาที่พบ: เมื่อคืน (29 ส.ค.) ตอน 23:00 น. มีแค่สาขา Back Office ได้รับสรุปปิดแอร์ อีก 3 สาขาไม่ได้รับ
-- ทั้งที่ตั้งค่า Chat ID / วันหยุด / จุดปิดแอร์ ไว้ครบถูกต้องทุกสาขา (ตรวจแล้วไม่ใช่ปัญหาการตั้งค่า)
--
-- สาเหตุที่แท้จริง: ฟังก์ชันแจ้งเตือนทั้ง 4 ตัว (สรุปลา 10:30, สรุปลาชั่วโมง 14:00, สรุปความสะอาด+ความ
-- เรียบร้อย 11:30, สรุปปิดแอร์ 23:00) ส่งข้อความแบบ "ยิงแล้วไม่รอผล" (perform net.http_post(...)) — ถ้า
-- Telegram ปฏิเสธการส่ง (เช่น bot ถูกเตะออกจากกลุ่ม, chat_id ผิด/กลุ่มถูกลบ, เครือข่ายมีปัญหาชั่วขณะ)
-- ฟังก์ชันจะไม่รู้เลยและไม่มีที่ไหนบันทึก error ไว้ ดูเหมือนทำงานสำเร็จปกติทุกครั้งจากมุมมอง Postgres
-- แต่ข้อความไปไม่ถึงบางกลุ่มแบบเงียบๆ — เป็นปัญหาเดียวกับที่เคยสงสัยไว้ก่อนหน้านี้ว่าทำไมสาขาแม่สอด
-- ไม่ได้รับสรุปความสะอาด 11:30 น. (ดู diagnose-maesot-notification.sql เดิม)
--
-- สิ่งที่ไฟล์นี้ทำ: เพิ่มตาราง telegram_send_log เก็บผลการส่งทุกครั้ง (ไม่รอผลตอนส่ง เหมือนเดิม กัน
-- statement timeout) แล้วมีฟังก์ชัน resolve_telegram_send_log() รันทุก 10 นาทีคอยเช็คผลย้อนหลังจาก
-- pg_net ว่าสำเร็จ (status 200) หรือ error อะไร — ถ้าเกิดปัญหาแบบเมื่อคืนอีก จะเห็นในตารางนี้ทันที
--
-- วิธีดู error ย้อนหลัง (รันเองใน SQL Editor ได้ตลอด):
-- select fn_name, branch_name, status_code, response, created_at from telegram_send_log
-- where resolved = true and status_code is distinct from 200 order by created_at desc limit 50;

-- 1) ตารางเก็บผลการส่งทุกครั้ง
create table if not exists telegram_send_log (
  id bigserial primary key,
  fn_name text not null,
  branch_name text,
  chat_id text,
  request_id bigint,
  status_code int,
  response text,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- 2) ฟังก์ชันเช็คผลย้อนหลัง — เติม status_code/response ให้แถวที่ยังไม่เช็ค (pg_net ตอบกลับภายในไม่กี่วินาที
-- ปกติ แต่ให้รอบถัดไปที่รันมาเช็คให้ กันเหมือนกับ sync_to_google_sheets ที่แก้ไปก่อนหน้านี้)
create or replace function resolve_telegram_send_log()
returns jsonb
language plpgsql
security definer
as $$
declare
  v_row record;
  v_status int;
  v_content text;
  v_resolved int := 0;
  v_failed int := 0;
begin
  for v_row in select * from telegram_send_log where resolved = false and created_at > now() - interval '2 days' loop
    select status_code, content into v_status, v_content from net._http_response where id = v_row.request_id;
    if v_status is not null then
      update telegram_send_log set status_code = v_status, response = v_content, resolved = true where id = v_row.id;
      v_resolved := v_resolved + 1;
      if v_status is distinct from 200 then v_failed := v_failed + 1; end if;
    end if;
  end loop;
  return jsonb_build_object('resolved', v_resolved, 'failed', v_failed);
end;
$$;
grant execute on function resolve_telegram_send_log() to anon;
select cron.schedule('resolve-telegram-send-log', '*/10 * * * *', $$select resolve_telegram_send_log();$$);

-- 3) แก้ 4 ฟังก์ชันแจ้งเตือน — เนื้อหาข้อความเหมือนเดิมทุกตัวอักษร เปลี่ยนแค่ตอนส่งให้เก็บ request_id
-- ไว้ใน telegram_send_log แทนที่จะยิงทิ้งเฉยๆ

-- ===== สรุปลา 10:30 น. =====
-- รวม 2 การแก้ล่าสุดที่เคยทำแยกกันไว้คนละไฟล์ (เช็คแล้วพบว่าถ้ารันไฟล์นี้เดี่ยวๆ ตามลำดับเวลาจริง
-- จะทับกันเอง จึงรวมมาไว้ในฟังก์ชันเดียวให้ครบทั้ง 2 อย่าง):
-- 1) notification-name-format-and-spacing.sql — ชื่อพนักงานแสดงแค่ "ชื่อจริง (ชื่อเล่น)" ไม่มีนามสกุล
-- 2) sort-late-list-by-minutes.sql — ส่วน "มาสาย" เรียงตามนาทีที่สาย น้อย→มาก แทนเรียงตามชื่อ
create or replace function send_daily_leave_summary()
returns void
language plpgsql
security definer
as $$
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

    v_msg := 'วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n' || 'สาขา ' || v_branch.name || E'\n\n'
      || '▪️ลางาน ' || v_leave_count || ' คน' || E'\n'
      || '▪️มาสาย ' || v_late_count || ' คน';
    if v_leave_count > 0 then
      v_msg := v_msg || E'\n\n⛔ลางาน\n' || array_to_string(v_leave_lines, E'\n');
    end if;
    if v_late_count > 0 then
      v_msg := v_msg || E'\n\n⛔มาสาย\n' || array_to_string(v_late_lines, E'\n');
    end if;

    v_request_id := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_checkinout, 'text', v_msg)
    );
    insert into telegram_send_log(fn_name, branch_name, chat_id, request_id)
      values ('send_daily_leave_summary', v_branch.name, v_branch.chat_id_checkinout, v_request_id);
  end loop;
end;
$$;

-- ===== สรุป 14:00 น. — เฉพาะวันมีคนลาชั่วโมง =====
create or replace function send_hourly_leave_checkin_summary()
returns void
language plpgsql
security definer
as $$
declare
  v_token text;
  v_today date;
  v_branch record;
  v_emp record;
  v_late_lines text[];
  v_late_count int;
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
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;

    v_hourly_count := 0;
    v_late_lines := array[]::text[];
    v_late_count := 0;

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
      select late_minutes into v_in_log
        from logs
        where employee_id = v_emp.id and type = 'IN'
          and (time at time zone 'Asia/Bangkok')::date = v_today
        limit 1;
      if found and v_in_log.late_minutes > 0 then
        v_late_count := v_late_count + 1;
        v_display_name := split_part(v_emp.name, ' ', 1) || case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
        v_late_lines := array_append(v_late_lines, v_late_count || '. ' || v_display_name || ' ' || v_in_log.late_minutes || ' นาที');
      end if;
    end loop;

    if v_hourly_count = 0 then continue; end if;

    v_msg := 'วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n' || 'สาขา ' || v_branch.name || E'\n\n'
      || '▪️ลาเป็นชั่วโมง ' || (case when v_late_count = 0 then '✅มาครบ' else '' end) || E'\n'
      || '▪️มาสาย ' || v_late_count || ' คน';
    if v_late_count > 0 then
      v_msg := v_msg || E'\n\n⛔มาสาย\n' || array_to_string(v_late_lines, E'\n');
    end if;

    v_request_id := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_checkinout, 'text', v_msg)
    );
    insert into telegram_send_log(fn_name, branch_name, chat_id, request_id)
      values ('send_hourly_leave_checkin_summary', v_branch.name, v_branch.chat_id_checkinout, v_request_id);
  end loop;
end;
$$;

-- ===== สรุปความสะอาด + ความเรียบร้อย 11:30 น. =====
create or replace function send_facility_missing_reminder()
returns void
language plpgsql
security definer
as $$
declare
  v_token text;
  v_today date;
  v_branch record;
  v_point record;
  v_emp record;
  v_clean_missing text[];
  v_clean_total int;
  v_groom_missing text[];
  v_groom_total int;
  v_msg text;
  v_done boolean;
  v_display_name text;
  v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, cleaning_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;
    v_clean_missing := array[]::text[];
    v_clean_total := 0;
    v_groom_missing := array[]::text[];
    v_groom_total := 0;

    for v_point in select value->>'id' as pid, value->>'name' as pname from jsonb_array_elements(coalesce(v_branch.cleaning_points,'[]'::jsonb)) loop
      v_clean_total := v_clean_total + 1;
      select exists(
        select 1 from logs
        where branch_id = v_branch.id and type = 'CLEAN' and clean_point_id = v_point.pid
          and (time at time zone 'Asia/Bangkok')::date = v_today
      ) into v_done;
      if not v_done then
        v_clean_missing := array_append(v_clean_missing, v_point.pname);
      end if;
    end loop;

    for v_emp in select id, name, nickname from employees where branch_id = v_branch.id and department = 'หน้าร้าน' loop
      v_groom_total := v_groom_total + 1;
      select exists(
        select 1 from logs
        where branch_id = v_branch.id and type = 'GROOM' and employee_id = v_emp.id
          and (time at time zone 'Asia/Bangkok')::date = v_today
      ) into v_done;
      if not v_done then
        v_display_name := split_part(v_emp.name, ' ', 1) || case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
        v_groom_missing := array_append(v_groom_missing, v_display_name);
      end if;
    end loop;

    if v_clean_total = 0 and v_groom_total = 0 then continue; end if;

    v_msg := '📍สาขา ' || v_branch.name || E'\n\n';

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

    v_request_id := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
    );
    insert into telegram_send_log(fn_name, branch_name, chat_id, request_id)
      values ('send_facility_missing_reminder', v_branch.name, v_branch.chat_id_facility, v_request_id);
  end loop;
end;
$$;

-- ===== สรุปปิดแอร์ 23:00 น. =====
create or replace function send_ac_missing_reminder()
returns void
language plpgsql
security definer
as $$
declare
  v_token text;
  v_today date;
  v_branch record;
  v_point record;
  v_missing text[];
  v_total int;
  v_msg text;
  v_done boolean;
  v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, ac_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;
    v_missing := array[]::text[];
    v_total := 0;
    for v_point in select value->>'id' as pid, value->>'name' as pname from jsonb_array_elements(coalesce(v_branch.ac_points,'[]'::jsonb)) loop
      v_total := v_total + 1;
      select exists(
        select 1 from logs
        where branch_id = v_branch.id and type = 'AC' and ac_point_id = v_point.pid
          and (time at time zone 'Asia/Bangkok')::date = v_today
      ) into v_done;
      if not v_done then
        v_missing := array_append(v_missing, v_point.pname);
      end if;
    end loop;

    if v_total = 0 then continue; end if;

    v_msg := '📍สาขา ' || v_branch.name || E'\n\n';
    if array_length(v_missing,1) > 0 then
      v_msg := v_msg || '▪️ส่งปิดแอร์' || E'\n❌ไม่ครบ (' || array_length(v_missing,1) || ' จุด)' || E'\n' ||
        (select string_agg('⛔' || x, E'\n') from unnest(v_missing) as x);
    else
      v_msg := v_msg || '▪️ส่งปิดแอร์' || E'\n✅ครบแล้ว (' || v_total || ' จุด)';
    end if;

    v_request_id := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
    );
    insert into telegram_send_log(fn_name, branch_name, chat_id, request_id)
      values ('send_ac_missing_reminder', v_branch.name, v_branch.chat_id_facility, v_request_id);
  end loop;
end;
$$;

grant execute on function send_daily_leave_summary() to anon;
grant execute on function send_hourly_leave_checkin_summary() to anon;
grant execute on function send_facility_missing_reminder() to anon;
grant execute on function send_ac_missing_reminder() to anon;

-- ทดสอบทันที (ไม่ต้องรอถึงเวลาจริง) แล้วรอสัก 10-20 วินาทีค่อยเช็คผล:
-- select send_ac_missing_reminder();
-- select resolve_telegram_send_log();
-- select fn_name, branch_name, status_code, response, created_at from telegram_send_log order by created_at desc limit 20;
