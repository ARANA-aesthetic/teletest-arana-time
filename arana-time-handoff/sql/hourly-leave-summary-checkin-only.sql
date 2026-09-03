-- ARANA TIME — แก้สรุปลาเป็นชั่วโมง 14:00 น. ให้นับเฉพาะ "ขาเข้างาน" เท่านั้น
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (แทนที่ฟังก์ชันเดิมด้วย create or replace ปลอดภัย รันซ้ำได้)
--
-- ที่มา: เคสจริง พนักงานลาเป็นชั่วโมง (กิจ) ช่วงบ่าย (เข้างานเวลาปกติ แล้วลากลับก่อน) แต่สรุป 14:00 น.
-- ที่ส่งเข้ากลุ่ม ยังดูสับสน/ผิดคอนเซ็ป — ต้องการให้สรุปนี้ดูแค่ "ขาเข้างาน" อย่างเดียว โดยขาเข้างานมี 2 แบบ
-- 1) เข้างานเวลาปกติ แล้วลาช่วงบ่าย (ลาครอบคลุมท้ายกะ) — เช็คแค่ว่ามาเข้างานตรงเวลาปกติไหม (ไม่ต้องสนใจ
--    ว่าออกงานตอนไหน เพราะการออกก่อนคือส่วนของใบลาอยู่แล้ว)
-- 2) ลาช่วงก่อนเข้างาน (ลาครอบคลุมต้นกะ) — เช็คว่าสุดท้ายแล้วมาเช็กอินไหม (เวลาสายที่บันทึกไว้ตอนสแกน
--    ปรับฐานเป็นเวลาสิ้นสุดใบลาให้อัตโนมัติอยู่แล้วจากฝั่งแอป — ดู shiftLateMinutes() ในโค้ด)
--
-- บั๊กเดิม: ฟังก์ชันเดิมเช็คแค่ "ถ้ามี IN log แล้ว late_minutes>0 ถือว่าสาย" แต่ถ้า "ยังไม่มี IN log เลย"
-- (ยังไม่เข้างานตอนที่ระบบสรุปตอน 14:00 น. — อาจเพราะลืมสแกน หรือขาดงานทั้งวันโดยอ้างใบลาเป็นข้ออ้าง)
-- โค้ดเดิมจะข้ามไปเฉยๆ ไม่นับว่ามีปัญหาอะไร ทำให้ขึ้น "✅มาครบ" ทั้งที่จริงๆ ยังไม่มีใครยืนยันว่าคนนั้นมาจริง
-- แก้ไขนี้แยกกรณี "สาย" กับ "ยังไม่เช็กอินเลย" ออกจากกันชัดเจน ไม่ให้ถูกกลืนเป็น "มาครบ" แบบเงียบๆ

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
        -- ยังไม่มีการเช็กอินเข้างานเลยวันนี้ ณ ตอนสรุป (14:00 น.) — ไม่ว่าจะลาช่วงเช้าหรือบ่าย ก็ควรเช็กอินแล้ว
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

grant execute on function send_hourly_leave_checkin_summary() to anon;
