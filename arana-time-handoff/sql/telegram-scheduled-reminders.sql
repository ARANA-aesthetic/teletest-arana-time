-- ARANA TIME — ระบบแจ้งเตือนอัตโนมัติตามเวลา (pg_cron + pg_net)
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว
-- ต้องรัน telegram-rooms-migration.sql ให้เสร็จก่อน (ต้องมีคอลัมน์ chat_id_checkinout, chat_id_facility ก่อน)

-- ===== 0) เปิดใช้งาน extension ที่จำเป็น =====
-- ถ้าคำสั่งนี้ error เรื่องสิทธิ์ ให้ไปเปิดผ่าน Dashboard > Database > Extensions
-- ค้นหา "pg_cron" กับ "pg_net" แล้วกด Enable แทน จากนั้นค่อยรันไฟล์นี้ต่อ
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ===== 1) สรุปวันลาประจำวัน — ส่งเข้าห้อง "เช็กอิน-เช็กเอาท์" ของแต่ละสาขา เวลา 10:30 น. =====
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
  v_lines text[];
  v_count int;
  v_msg text;
  v_days int;
  v_hours numeric;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_checkinout from branches
    where chat_id_checkinout is not null and chat_id_checkinout != ''
  loop
    v_lines := array[]::text[];
    v_count := 0;
    for v_emp in
      select e.name, e.nickname, l.kind, l.from_date, l.to_date, l.from_time, l.to_time
      from leaves l
      join employees e on e.id = l.employee_id
      where e.branch_id = v_branch.id
        and l.status = 'approved'
        and l.from_date <= v_today and l.to_date >= v_today
      order by e.name
    loop
      v_count := v_count + 1;
      if v_emp.kind in ('hourly_sick','hourly_personal') then
        v_hours := extract(epoch from (v_emp.to_time::time - v_emp.from_time::time)) / 3600.0;
        v_lines := array_append(v_lines,
          v_count || '. ' || v_emp.name || ' (' || coalesce(v_emp.nickname,'-') || ') ลาเป็นชั่วโมง (' ||
          case v_emp.kind when 'hourly_sick' then 'ป่วย' else 'กิจ' end || ') ' || round(v_hours,1) || ' ชม.');
      else
        v_days := (v_emp.to_date - v_emp.from_date) + 1;
        v_lines := array_append(v_lines,
          v_count || '. ' || v_emp.name || ' (' || coalesce(v_emp.nickname,'-') || ') ' ||
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

    v_msg := 'วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n' || 'สาขา ' || v_branch.name || E'\n\n' || 'ลางาน ' || v_count || ' คน';
    if v_count > 0 then
      v_msg := v_msg || E'\n\n' || array_to_string(v_lines, E'\n');
    end if;

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_checkinout, 'text', v_msg)
    );
  end loop;
end;
$$;

select cron.schedule('daily-leave-summary', '30 3 * * *', $$select send_daily_leave_summary();$$);
-- หมายเหตุ: 03:30 UTC = 10:30 เวลาไทย (ประเทศไทย UTC+7)


-- ===== 2) เตือนจุดปิดแอร์ที่ยังไม่ได้แจ้ง — เวลา 23:00 น. =====
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
  v_msg text;
  v_done boolean;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, ac_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
  loop
    v_missing := array[]::text[];
    for v_point in select value->>'id' as pid, value->>'name' as pname from jsonb_array_elements(coalesce(v_branch.ac_points,'[]'::jsonb)) loop
      select exists(
        select 1 from logs
        where branch_id = v_branch.id and type = 'AC' and ac_point_id = v_point.pid
          and (time at time zone 'Asia/Bangkok')::date = v_today
      ) into v_done;
      if not v_done then
        v_missing := array_append(v_missing, v_point.pname);
      end if;
    end loop;

    if array_length(v_missing,1) > 0 then
      v_msg := 'สาขา ' || v_branch.name || E'\nยังไม่ได้แจ้งปิดแอร์จุด:\n- ' || array_to_string(v_missing, E'\n- ');
      perform net.http_post(
        url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
        headers := '{"Content-Type": "application/json"}'::jsonb,
        body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
      );
    end if;
  end loop;
end;
$$;

select cron.schedule('ac-missing-reminder', '0 16 * * *', $$select send_ac_missing_reminder();$$);
-- หมายเหตุ: 16:00 UTC = 23:00 เวลาไทย


-- ===== 3) เตือนความสะอาด + ความเรียบร้อยพนักงานที่ยังไม่ได้ส่ง — เวลา 11:30 น. =====
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
  v_missing text[];
  v_msg text;
  v_done boolean;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, cleaning_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
  loop
    v_missing := array[]::text[];

    for v_point in select value->>'id' as pid, value->>'name' as pname from jsonb_array_elements(coalesce(v_branch.cleaning_points,'[]'::jsonb)) loop
      select exists(
        select 1 from logs
        where branch_id = v_branch.id and type = 'CLEAN' and clean_point_id = v_point.pid
          and (time at time zone 'Asia/Bangkok')::date = v_today
      ) into v_done;
      if not v_done then
        v_missing := array_append(v_missing, 'ความสะอาด: ' || v_point.pname);
      end if;
    end loop;

    if v_branch.id != 'hq' then
      for v_emp in select id, name from employees where branch_id = v_branch.id loop
        select exists(
          select 1 from logs
          where branch_id = v_branch.id and type = 'GROOM' and employee_id = v_emp.id
            and (time at time zone 'Asia/Bangkok')::date = v_today
        ) into v_done;
        if not v_done then
          v_missing := array_append(v_missing, 'ความเรียบร้อย: ' || v_emp.name);
        end if;
      end loop;
    end if;

    if array_length(v_missing,1) > 0 then
      v_msg := 'สาขา ' || v_branch.name || E'\nยังไม่ได้ส่ง:\n- ' || array_to_string(v_missing, E'\n- ');
      perform net.http_post(
        url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
        headers := '{"Content-Type": "application/json"}'::jsonb,
        body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
      );
    end if;
  end loop;
end;
$$;

select cron.schedule('facility-missing-reminder', '30 4 * * *', $$select send_facility_missing_reminder();$$);
-- หมายเหตุ: 04:30 UTC = 11:30 เวลาไทย


-- ===== วิธีทดสอบทันที (ไม่ต้องรอถึงเวลา) =====
-- รันบรรทัดใดบรรทัดหนึ่งด้านล่างนี้แยกต่างหาก แล้วเช็กว่าข้อความเข้า Telegram จริงไหม:
-- select send_daily_leave_summary();
-- select send_ac_missing_reminder();
-- select send_facility_missing_reminder();

-- ===== วิธีดูว่าตั้งเวลาไว้ถูกไหม / ยกเลิกทีหลัง =====
-- select * from cron.job;
-- select cron.unschedule('daily-leave-summary');
