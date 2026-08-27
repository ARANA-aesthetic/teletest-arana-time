-- ARANA TIME — แก้ error "function convert_from(text, unknown) does not exist"
-- รันไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้ ใช้ CREATE OR REPLACE)
--
-- สาเหตุ: ในเวอร์ชัน pg_net ของฐานข้อมูลนี้ คอลัมน์ net._http_response.content
-- เป็นชนิด text อยู่แล้ว (ไม่ใช่ bytea เหมือนที่คาดไว้ในไฟล์ gsheet-fix-use-pgnet.sql)
-- เลยเรียก convert_from() ซ้ำไม่ได้ — แก้แค่จุดนี้จุดเดียว อ่านเป็น text ตรงๆ

create or replace function sync_to_google_sheets()
returns jsonb
language plpgsql
security definer
as $$
declare
  v_url text; v_secret text;
  v_leaves jsonb := '[]'::jsonb;
  v_late jsonb := '[]'::jsonb;
  v_ot jsonb := '[]'::jsonb;
  v_logs jsonb := '[]'::jsonb;
  v_leave_ids text[] := '{}';
  v_log_ids text[] := '{}';
  v_ot_ids text[] := '{}';
  v_payload jsonb;
  v_request_id bigint;
  v_status int;
  v_content text;
  rec record;
  i int;
begin
  select gsheet_webapp_url, gsheet_secret into v_url, v_secret from settings where id = 1;
  if v_url is null or v_url = '' then
    return jsonb_build_object('ok', false, 'error', 'ยังไม่ได้ตั้งค่า gsheet_webapp_url ใน settings');
  end if;

  -- ===== ขาดลา (leaves) — ส่งทุกสถานะ เพื่อเก็บเป็นบันทึกครบถ้วน =====
  for rec in
    select l.id, l.requested_at, e.name as emp_name, e.nickname as emp_nickname, e.email as emp_email,
           e.job_title as emp_job_title, br.name as branch_name,
           l.kind, l.from_date, l.to_date, l.from_time, l.to_time, l.reason, l.status, l.decided_at, l.employee_id
    from leaves l
    left join employees e on e.id = l.employee_id
    left join branches br on br.id = e.branch_id
    where l.synced_at is null
    order by l.requested_at
    limit 500
  loop
    v_leave_ids := array_append(v_leave_ids, rec.id);
    v_leaves := v_leaves || jsonb_build_array(jsonb_build_array(
      round(extract(epoch from (rec.from_date::timestamp - rec.requested_at at time zone 'Asia/Bangkok'))/86400.0, 4),
      rec.from_date::text,
      to_char(rec.requested_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI'),
      coalesce(rec.emp_email, ''),
      coalesce(rec.emp_name, '(ลบแล้ว)'),
      coalesce(rec.emp_nickname, ''),
      coalesce(rec.branch_name, '-'),
      coalesce(rec.emp_job_title, ''),
      rec.from_date::text,
      rec.to_date::text,
      case when rec.from_time is null then (rec.to_date - rec.from_date + 1) else null end,
      case rec.kind
        when 'sick_cert' then 'ลาป่วย (มีใบรับรองแพทย์)'
        when 'sick_nocert' then 'ลาป่วย (ไม่มีใบรับรองแพทย์)'
        when 'personal_nodeduct' then 'ลากิจ (ไม่หักเงิน)'
        when 'personal_deduct' then 'ลากิจ (หักเงิน)'
        when 'traditional' then 'ลาใช้สิทธิ์วันหยุดประเพณี'
        when 'vacation' then 'ลาพักร้อน'
        when 'maternity' then 'ลาคลอด'
        when 'hourly_sick' then 'ลาเป็นชั่วโมง (ป่วย)'
        when 'hourly_personal' then 'ลาเป็นชั่วโมง (กิจ)'
        else rec.kind
      end,
      case when rec.from_time is not null then round(extract(epoch from (rec.to_time::time - rec.from_time::time))/3600.0, 2) else null end,
      case when rec.from_time is not null then rec.from_time::text else '' end,
      case when rec.to_time is not null then rec.to_time::text else '' end,
      coalesce(rec.reason, ''),
      rec.status,
      case when rec.decided_at is not null then to_char(rec.decided_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI') else '' end,
      rec.id::text,
      coalesce(rec.employee_id::text, '')
    ));
  end loop;

  -- ===== logs (IN/OUT) — ใช้ผลชุดเดียวกันแยกลงทั้ง "มาสาย" และ "Log In-Out" =====
  for rec in
    select lg.id, lg.time, lg.type, lg.late_minutes, e.name as emp_name, br.name as branch_name, lg.employee_id
    from logs lg
    left join employees e on e.id = lg.employee_id
    left join branches br on br.id = lg.branch_id
    where lg.synced_at is null and lg.type in ('IN','OUT')
    order by lg.time
    limit 1000
  loop
    v_log_ids := array_append(v_log_ids, rec.id);
    v_logs := v_logs || jsonb_build_array(jsonb_build_array(
      to_char(rec.time at time zone 'Asia/Bangkok', 'YYYY-MM-DD'),
      to_char(rec.time at time zone 'Asia/Bangkok', 'HH24:MI'),
      coalesce(rec.emp_name, '(ลบแล้ว)'),
      coalesce(rec.branch_name, '-'),
      rec.type,
      coalesce(rec.late_minutes, 0),
      rec.id::text,
      coalesce(rec.employee_id::text, '')
    ));
    if rec.type = 'IN' and coalesce(rec.late_minutes, 0) > 0 then
      v_late := v_late || jsonb_build_array(jsonb_build_array(
        to_char(rec.time at time zone 'Asia/Bangkok', 'YYYY-MM-DD'),
        to_char(rec.time at time zone 'Asia/Bangkok', 'HH24:MI'),
        coalesce(rec.emp_name, '(ลบแล้ว)'),
        coalesce(rec.branch_name, '-'),
        rec.late_minutes,
        rec.id::text,
        coalesce(rec.employee_id::text, '')
      ));
    end if;
  end loop;

  -- ===== OT ที่อนุมัติแล้วเท่านั้น =====
  for rec in
    select o.id, o.requested_at, e.name as emp_name, br.name as branch_name,
           o.date, o.hour_start, o.hour_end, o.reason, o.decided_at, o.employee_id
    from ot_requests o
    left join employees e on e.id = o.employee_id
    left join branches br on br.id = e.branch_id
    where o.synced_at is null and o.status = 'approved'
    order by o.requested_at
    limit 500
  loop
    v_ot_ids := array_append(v_ot_ids, rec.id);
    v_ot := v_ot || jsonb_build_array(jsonb_build_array(
      to_char(rec.requested_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI'),
      coalesce(rec.emp_name, '(ลบแล้ว)'),
      coalesce(rec.branch_name, '-'),
      rec.date::text,
      rec.hour_start::text,
      rec.hour_end::text,
      round(extract(epoch from (rec.hour_end::time - rec.hour_start::time))/3600.0, 1),
      coalesce(rec.reason, ''),
      case when rec.decided_at is not null then to_char(rec.decided_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI') else '' end,
      rec.id::text,
      coalesce(rec.employee_id::text, '')
    ));
  end loop;

  if array_length(v_leave_ids,1) is null and array_length(v_log_ids,1) is null and array_length(v_ot_ids,1) is null then
    return jsonb_build_object('ok', true, 'note', 'ไม่มีข้อมูลใหม่ต้อง sync');
  end if;

  v_payload := jsonb_build_object(
    'secret', v_secret,
    'leaves', v_leaves,
    'late', v_late,
    'ot', v_ot,
    'logs_inout', v_logs
  );

  v_request_id := net.http_post(
    url := v_url,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := v_payload
  );

  v_status := null;
  for i in 1..12 loop
    perform pg_sleep(0.5);
    select status_code, content into v_status, v_content
    from net._http_response where id = v_request_id;
    exit when v_status is not null;
  end loop;

  if v_status = 200 then
    if array_length(v_leave_ids,1) > 0 then update leaves set synced_at = now() where id = any(v_leave_ids); end if;
    if array_length(v_log_ids,1) > 0 then update logs set synced_at = now() where id = any(v_log_ids); end if;
    if array_length(v_ot_ids,1) > 0 then update ot_requests set synced_at = now() where id = any(v_ot_ids); end if;
    update settings set gsheet_last_sync = now() where id = 1;
    return jsonb_build_object('ok', true,
      'leaves_synced', coalesce(array_length(v_leave_ids,1),0),
      'logs_synced', coalesce(array_length(v_log_ids,1),0),
      'ot_synced', coalesce(array_length(v_ot_ids,1),0),
      'response', v_content);
  else
    return jsonb_build_object('ok', false, 'status', v_status, 'response', v_content,
      'request_id', v_request_id,
      'note', 'ส่งไม่สำเร็จหรือยังไม่ได้ผลลัพธ์ภายในเวลาที่รอ ไม่ได้ mark synced_at ไว้ รอบถัดไปจะลองส่งซ้ำอัตโนมัติ');
  end if;
end;
$$;

grant execute on function sync_to_google_sheets() to anon;

-- ทดสอบทันที:
-- select sync_to_google_sheets();
