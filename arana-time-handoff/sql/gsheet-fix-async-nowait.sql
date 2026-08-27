-- ARANA TIME — แก้ error "canceling statement due to statement timeout"
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้)
--
-- สาเหตุ: เวอร์ชันก่อนหน้าใช้ pg_sleep วนรอผลลัพธ์นานสุด ~6 วินาทีในฟังก์ชันเดียว
-- แต่ role ที่ใช้เรียกผ่าน RPC มี statement_timeout สั้นกว่านั้น เลยถูกตัดก่อนได้ผลลัพธ์
--
-- แก้โดยเปลี่ยนสถาปัตยกรรมเป็น "ยิงแล้วไม่รอ" (fire-and-forget แบบมีการติดตามผล):
-- 1) ทุกครั้งที่ฟังก์ชันถูกเรียก จะ "ตรวจผลลัพธ์ของรอบก่อนหน้า" ก่อน (ถ้ามี, มักจะพร้อมแล้ว
--    เพราะเวลาผ่านไปหลายวินาที-หลายนาทีตั้งแต่ยิงรอบก่อน) แล้วค่อย mark synced_at ให้แถวที่สำเร็จ
-- 2) จากนั้นดึงแถวที่ยังไม่ sync ปัจจุบัน ยิง request ใหม่แบบ async (ไม่รอผล) แล้วจดไว้ในตาราง
--    ติดตามผล gsheet_sync_batches เพื่อให้รอบถัดไปมาเช็คผลลัพธ์ต่อ
-- ฟังก์ชันจึงทำงานเร็วมาก (ไม่ค้างรอ) ไม่ชน statement_timeout อีก
-- ถ้ารอบไหนส่งไม่สำเร็จ แถวจะยังไม่ถูก mark synced_at เลยถูกดึงไปลองส่งใหม่รอบถัดไปเองอัตโนมัติ

-- 1) ตารางติดตามผลลัพธ์การส่งแต่ละครั้ง
create table if not exists gsheet_sync_batches (
  id bigserial primary key,
  request_id bigint,
  leave_ids text[] not null default '{}',
  log_ids text[] not null default '{}',
  ot_ids text[] not null default '{}',
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- 2) ฟังก์ชันหลัก (แก้ใหม่ทั้งหมด — ไม่มี pg_sleep/รอผลในฟังก์ชันแล้ว)
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
  v_resolved_count int := 0;
  v_batch record;
  rec record;
begin
  select gsheet_webapp_url, gsheet_secret into v_url, v_secret from settings where id = 1;
  if v_url is null or v_url = '' then
    return jsonb_build_object('ok', false, 'error', 'ยังไม่ได้ตั้งค่า gsheet_webapp_url ใน settings');
  end if;

  -- ===== ขั้นที่ 1: เช็คผลลัพธ์ของ batch ก่อนหน้าที่ยังไม่ resolve =====
  for v_batch in select * from gsheet_sync_batches where resolved = false order by created_at loop
    select status_code, content into v_status, v_content
    from net._http_response where id = v_batch.request_id;

    if v_status = 200 then
      if array_length(v_batch.leave_ids,1) > 0 then update leaves set synced_at = now() where id = any(v_batch.leave_ids) and synced_at is null; end if;
      if array_length(v_batch.log_ids,1) > 0 then update logs set synced_at = now() where id = any(v_batch.log_ids) and synced_at is null; end if;
      if array_length(v_batch.ot_ids,1) > 0 then update ot_requests set synced_at = now() where id = any(v_batch.ot_ids) and synced_at is null; end if;
      update settings set gsheet_last_sync = now() where id = 1;
      update gsheet_sync_batches set resolved = true where id = v_batch.id;
      v_resolved_count := v_resolved_count + 1;
    elsif v_status is not null then
      -- ได้ผลลัพธ์แล้วแต่ไม่ใช่ 200 (ส่งไม่สำเร็จ) — ปิด batch นี้ไป แถวที่เกี่ยวข้องยัง synced_at
      -- เป็น null อยู่ จะถูกดึงไปลองส่งใหม่ในขั้นที่ 2 ด้านล่างของรอบนี้เอง ไม่ต้องทำอะไรเพิ่ม
      update gsheet_sync_batches set resolved = true where id = v_batch.id;
    end if;
    -- ถ้า v_status ยัง null (pg_net ยังไม่ตอบกลับ) ปล่อย batch นี้ไว้เฉยๆ ให้รอบถัดไปเช็คต่อ
  end loop;

  -- ===== ขั้นที่ 2: รวบรวมแถวที่ยังไม่ sync ปัจจุบัน แล้วยิง request ใหม่ (ไม่รอผล) =====
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
    return jsonb_build_object('ok', true, 'resolved_previous_batches', v_resolved_count, 'note', 'ไม่มีข้อมูลใหม่ต้อง sync');
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

  insert into gsheet_sync_batches (request_id, leave_ids, log_ids, ot_ids)
  values (v_request_id, v_leave_ids, v_log_ids, v_ot_ids);

  return jsonb_build_object('ok', true,
    'resolved_previous_batches', v_resolved_count,
    'queued_leaves', coalesce(array_length(v_leave_ids,1),0),
    'queued_logs', coalesce(array_length(v_log_ids,1),0),
    'queued_ot', coalesce(array_length(v_ot_ids,1),0),
    'note', 'ส่งคำขอไปแล้ว กำลังรอผลลัพธ์ — เรียกฟังก์ชันนี้อีกครั้ง (เช่น กด Sync ตอนนี้ อีกรอบ หรือรอ cron รอบถัดไป) เพื่อยืนยันผลและ mark synced_at');
end;
$$;

grant execute on function sync_to_google_sheets() to anon;

-- ทดสอบทันที (ต้องเรียก 2 ครั้งห่างกันสัก 5-10 วินาทีเพื่อเห็นผลครบ ครั้งแรกจะแค่ "ส่งคำขอ" ครั้งที่สองจะ "ยืนยันผล"):
-- select sync_to_google_sheets();
