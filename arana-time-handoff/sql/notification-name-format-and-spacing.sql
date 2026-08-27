-- ARANA TIME — ปรับ 3 เรื่อง ในข้อความแจ้งเตือน Telegram อัตโนมัติ (pg_cron functions)
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ ใช้ CREATE OR REPLACE)
--
-- 1) เปลี่ยนการแสดงชื่อพนักงานในข้อความสรุปทุกฟังก์ชัน จาก "ชื่อ-นามสกุล (ชื่อเล่น)"
--    เป็น "ชื่อจริง (ชื่อเล่น)" เท่านั้น (ตัดนามสกุลออก ลดความรกสายตา) — ถ้าไม่มีชื่อเล่นจะไม่แสดงวงเล็บเลย
--    ใช้ split_part(name, ' ', 1) ดึงคำแรกของชื่อเต็มเป็นชื่อจริง
-- 2) ปรับข้อความสรุปความสะอาด+ความเรียบร้อย (send_facility_missing_reminder) ให้เว้นบรรทัดว่าง
--    คั่นระหว่างสาขา/หัวข้อ/รายการ และแยกหัวข้อกับสถานะคนละบรรทัด อ่านง่ายขึ้นบนมือถือ ตามตัวอย่างที่ผู้ใช้ให้:
--    📍สาขา แม่สอด
--
--    ▪️ส่งความสะอาด
--    ❌ไม่ครบ (1 จุด)
--    ⛔ห้องดริป
--
--    ▪️ความเรียบร้อย
--    ❌ไม่ครบ (2 คน)
--    ⛔ภูริชญา (ฮาเดียร์)
--    ⛔จันบาล (น้อย)
-- 3) ปรับข้อความสรุปปิดแอร์ (send_ac_missing_reminder) ให้เว้นบรรทัด/ขึ้นบรรทัดใหม่แบบเดียวกับข้อ 2
--    (ไม่มีชื่อพนักงานในข้อความนี้ — เป็นชื่อจุดปิดแอร์ เลยปรับแค่ spacing ไม่ต้องแก้เรื่องชื่อ)

-- ===== 1. สรุป 10:30 น. — ลางาน + มาสาย (เปลี่ยนแค่รูปแบบชื่อ) =====
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
      order by e.name
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

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_checkinout, 'text', v_msg)
    );
  end loop;
end;
$$;


-- ===== 2. สรุป 14:00 น. — เฉพาะวันมีคนลาชั่วโมง (เปลี่ยนแค่รูปแบบชื่อ) =====
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

    if v_hourly_count = 0 then continue; end if; -- ไม่มีคนลาชั่วโมงวันนี้ ไม่ต้องส่ง

    v_msg := 'วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n' || 'สาขา ' || v_branch.name || E'\n\n'
      || '▪️ลาเป็นชั่วโมง ' || (case when v_late_count = 0 then '✅มาครบ' else '' end) || E'\n'
      || '▪️มาสาย ' || v_late_count || ' คน';
    if v_late_count > 0 then
      v_msg := v_msg || E'\n\n⛔มาสาย\n' || array_to_string(v_late_lines, E'\n');
    end if;

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_checkinout, 'text', v_msg)
    );
  end loop;
end;
$$;


-- ===== 3. สรุปความสะอาด + ความเรียบร้อย 11:30 น. — เปลี่ยนรูปแบบชื่อ + เว้นบรรทัดใหม่ทั้งหมด =====
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

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
    );
  end loop;
end;
$$;

-- ===== 4. สรุปปิดแอร์ 23:00 น. — เว้นบรรทัดแบบเดียวกับข้อ 2 (ไม่มีชื่อพนักงาน ไม่ต้องแก้เรื่องชื่อ) =====
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

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
    );
  end loop;
end;
$$;

-- ทดสอบทันที:
-- select send_daily_leave_summary();
-- select send_hourly_leave_checkin_summary();
-- select send_facility_missing_reminder();
-- select send_ac_missing_reminder();
