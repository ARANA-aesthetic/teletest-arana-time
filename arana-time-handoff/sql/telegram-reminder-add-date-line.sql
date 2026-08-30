-- ARANA TIME — เพิ่มบรรทัดวันที่ในสรุปปิดแอร์ (23:00) และสรุปความสะอาด+ความเรียบร้อย (11:30)
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ — create or replace)
--
-- เหตุผล: 2 ข้อความนี้เดิมมีแค่ "📍สาขา ชื่อ" ไม่บอกวันที่เลย ทำให้แยกไม่ออกว่าเป็นรายงานของวันไหน
-- (ตัวอย่างที่ user แจ้ง: ทดสอบยิงฟังก์ชันปิดแอร์วันนี้ แต่ดูเผินๆ เหมือนเป็นของเมื่อคืน) — เพิ่มบรรทัด
-- "🗓️วันที่ DD/MM/YYYY" ต่อจากชื่อสาขาทันที ตามตัวอย่างที่ user ให้:
--   📍สาขา กำแพงเพชร
--   🗓️วันที่ xx/08/2026
--
--   ▪️ส่งปิดแอร์
--   ...
--
-- ไม่แตะ send_daily_leave_summary() / send_hourly_leave_checkin_summary() เพราะ 2 ฟังก์ชันนั้นมีบรรทัด
-- วันที่อยู่แล้ว (แค่คนละรูปแบบ) ไม่ได้อยู่ในสิ่งที่ user แจ้งให้แก้รอบนี้
--
-- โครงฟังก์ชันทั้งหมด (รวม telegram_send_log ที่เพิ่งเพิ่มไปในไฟล์ telegram-send-visibility.sql) เหมือนเดิม
-- ทุกจุด เปลี่ยนแค่บรรทัดประกอบ v_msg ตอนเริ่มต้นข้อความเท่านั้น

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

    v_msg := '📍สาขา ' || v_branch.name || E'\n🗓️วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n\n';
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

grant execute on function send_facility_missing_reminder() to anon;
grant execute on function send_ac_missing_reminder() to anon;

-- ทดสอบทันที:
-- select send_ac_missing_reminder();
-- select send_facility_missing_reminder();
