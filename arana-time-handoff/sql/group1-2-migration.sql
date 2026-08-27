-- ARANA TIME — Group 1+2 migration
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้)

-- 1) วันหยุดประจำสัปดาห์ต่อสาขา
alter table branches add column if not exists weekly_off_days integer[] default '{}';

-- 2) ห้อง Telegram แยกสำหรับ OT
alter table settings add column if not exists ot_chat_id text;

-- 3) ฟังก์ชันเช็กว่าสาขาปิดวันนั้นหรือไม่ (วันหยุดประจำสัปดาห์ หรือวันหยุดบริษัท)
create or replace function is_shop_closed(p_branch_id text, p_date date)
returns boolean
language plpgsql
as $$
declare
  v_dow int;
  v_weekly_off int[];
  v_holidays jsonb;
  v_is_holiday boolean;
begin
  v_dow := extract(dow from p_date);
  select weekly_off_days into v_weekly_off from branches where id = p_branch_id;
  if v_weekly_off is not null and v_dow = any(v_weekly_off) then
    return true;
  end if;
  select holidays into v_holidays from settings where id = 1;
  select exists(
    select 1 from jsonb_array_elements(coalesce(v_holidays,'[]'::jsonb)) h
    where (h->>'date')::date = p_date
  ) into v_is_holiday;
  return coalesce(v_is_holiday, false);
end;
$$;

-- 4) อัปเดตฟังก์ชันเตือน 3 ตัวเดิม ให้ข้ามสาขาที่ปิดวันนั้น (ไม่ส่งอะไรเลยถ้าร้านปิด)

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
    if is_shop_closed(v_branch.id, v_today) then continue; end if;
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

    if array_length(v_missing,1) > 0 then
      v_msg := 'สาขา ' || v_branch.name || E'\nยังไม่ได้แจ้งปิดแอร์จุด:\n- ' || array_to_string(v_missing, E'\n- ');
    else
      v_msg := 'สาขา ' || v_branch.name || E'\nปิดแอร์ครบทุกจุดแล้ว (' || v_total || ' จุด) ✓';
    end if;

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
    );
  end loop;
end;
$$;

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
  v_total int;
  v_msg text;
  v_done boolean;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, cleaning_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;
    v_missing := array[]::text[];
    v_total := 0;

    for v_point in select value->>'id' as pid, value->>'name' as pname from jsonb_array_elements(coalesce(v_branch.cleaning_points,'[]'::jsonb)) loop
      v_total := v_total + 1;
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
      for v_emp in select id, name from employees where branch_id = v_branch.id and department = 'หน้าร้าน' loop
        v_total := v_total + 1;
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

    if v_total = 0 then continue; end if;

    if array_length(v_missing,1) > 0 then
      v_msg := 'สาขา ' || v_branch.name || E'\nยังไม่ได้ส่ง:\n- ' || array_to_string(v_missing, E'\n- ');
    else
      v_msg := 'สาขา ' || v_branch.name || E'\nส่งความสะอาด + ความเรียบร้อยครบแล้ว (' || v_total || ' รายการ) ✓';
    end if;

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg)
    );
  end loop;
end;
$$;

-- ไม่ต้องรัน cron.schedule ใหม่ — create or replace แค่เปลี่ยนเนื้อหาฟังก์ชันเดิมที่ผูกกับตัวจับเวลาอยู่แล้ว

-- ทดสอบทันที:
-- select send_daily_leave_summary();
-- select send_ac_missing_reminder();
-- select send_facility_missing_reminder();
