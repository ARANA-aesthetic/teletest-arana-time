-- ARANA TIME — แก้ลำดับรายชื่อในสรุป 10:30 น. (ส่วน "มาสาย")
-- รันไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ — CREATE OR REPLACE)
--
-- เดิม (group3-migration.sql): ส่วน "มาสาย" เรียงตามชื่อ (order by e.name)
-- ใหม่: เรียงตามจำนวนนาทีที่สาย จากน้อยไปมาก (order by late_minutes asc)
--       ถ้าสายเท่ากันหลายคน เรียงตามชื่อเป็นตัวรอง
-- ส่วน "ลางาน" ไม่มีแนวคิด "สายกี่นาที" จึงคงเรียงตามชื่อไว้เหมือนเดิม ไม่ได้แก้

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
      if v_emp.kind in ('hourly_sick','hourly_personal') then
        v_hours := extract(epoch from (v_emp.to_time::time - v_emp.from_time::time)) / 3600.0;
        v_leave_lines := array_append(v_leave_lines,
          v_leave_count || '. ' || v_emp.name || ' (' || coalesce(v_emp.nickname,'-') || ') ลาเป็นชั่วโมง (' ||
          case v_emp.kind when 'hourly_sick' then 'ป่วย' else 'กิจ' end || ') ' || round(v_hours,1) || ' ชม.');
      else
        v_days := (v_emp.to_date - v_emp.from_date) + 1;
        v_leave_lines := array_append(v_leave_lines,
          v_leave_count || '. ' || v_emp.name || ' (' || coalesce(v_emp.nickname,'-') || ') ' ||
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
      v_late_lines := array_append(v_late_lines, v_late_count || '. ' || v_emp.name || ' (' || coalesce(v_emp.nickname,'-') || ') ' || v_emp.late_minutes || ' นาที');
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

-- ทดสอบยิงเลยได้ (ไม่ต้องรอ 10:30 น.):
-- select send_daily_leave_summary();
