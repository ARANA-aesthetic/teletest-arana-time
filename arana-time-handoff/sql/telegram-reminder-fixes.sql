-- ARANA TIME — แก้ไขฟังก์ชันแจ้งเตือนอัตโนมัติ (รันทับของเดิมได้เลย ปลอดภัย)
-- แก้ 2 เรื่อง:
-- 1) เพิ่มข้อความสรุปตอน "ครบทุกจุดแล้ว" (ไม่ใช่แค่ตอนขาด)
-- 2) ความเรียบร้อยพนักงาน กรองเฉพาะพนักงานที่ตั้ง "แผนก" เป็น "หน้าร้าน" เท่านั้น (ไม่ใช่ดูจากสาขา)

-- ===== เตือน/สรุปจุดปิดแอร์ — เวลา 23:00 น. =====
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

    if v_total = 0 then
      continue; -- สาขานี้ยังไม่ได้ตั้งจุดปิดแอร์เลย ไม่ต้องส่งอะไร
    end if;

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


-- ===== เตือน/สรุปความสะอาด + ความเรียบร้อยพนักงาน — เวลา 11:30 น. =====
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
    v_missing := array[]::text[];
    v_total := 0;

    -- จุดตรวจความสะอาด
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

    -- ความเรียบร้อยพนักงาน: เฉพาะพนักงานที่ตั้ง "แผนก" เป็น "หน้าร้าน" เท่านั้น (ไม่ใช่ดูจากสาขา)
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

    if v_total = 0 then
      continue; -- สาขานี้ยังไม่มีจุดตรวจความสะอาด และไม่มีพนักงานแผนกหน้าร้าน ไม่ต้องส่งอะไร
    end if;

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

-- หมายเหตุ: ไม่ต้องรัน cron.schedule ใหม่ เพราะ create or replace function
-- จะอัปเดตเนื้อหาฟังก์ชันที่ผูกกับตัวจับเวลาเดิมโดยอัตโนมัติ (ชื่อฟังก์ชันเหมือนเดิม)

-- ทดสอบทันที:
-- select send_ac_missing_reminder();
-- select send_facility_missing_reminder();
