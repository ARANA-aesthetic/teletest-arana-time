-- ARANA TIME — Backup ข้อมูลไป Google Sheets แบบใกล้เคียงเรียลไทม์ (ทุก 15 นาที) + ปุ่ม export ทันทีได้
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (ปลอดภัย รันซ้ำได้)
--
-- ภาพรวม: เพิ่มคอลัมน์ synced_at ให้ leaves/logs/ot_requests (nullable, ไม่กระทบ logic เดิมใดๆ)
-- ทุก 15 นาที cron จะดึงเฉพาะแถวที่ synced_at is null ส่งเป็น JSON ไปที่ Google Apps Script Web App
-- (URL + secret เก็บใน settings) ถ้าได้ status 200 กลับมาค่อย mark synced_at = now() กันส่งซ้ำ
-- ถ้าส่งไม่สำเร็จจะไม่ mark ไว้ รอบถัดไปจะลองส่งซ้ำอัตโนมัติ (ไม่มี silent failure)
--
-- ก่อนรันต้องมี Google Apps Script deploy แล้ว (ดู arana-time-handoff/google-apps-script/arana-sheets-sync.gs)
-- และต้องรู้ SHARED_SECRET ที่ตั้งไว้ในสคริปต์นั้น เพื่อมาใส่ในขั้นตอนที่ 4 ด้านล่าง
--
-- ★ หมายเหตุความเสี่ยงที่ตรวจสอบไม่ได้จากตรงนี้ (ไม่มีการเชื่อมต่อฐานข้อมูลจริงตอนเขียนไฟล์นี้) ★
-- ใช้ extension "http" (ของ pramsey) เพราะรอผลลัพธ์ทันทีได้ในฟังก์ชันเดียว ไม่ต้อง poll แบบ pg_net
-- ปกติ Supabase มี extension นี้ให้เปิดใช้ได้อยู่แล้ว แต่ถ้ารันขั้นตอนที่ 3 แล้ว error ว่าไม่มี
-- extension "http" ให้แจ้งกลับมา จะปรับให้ใช้ pg_net (ตัวเดียวกับที่ใช้ส่ง Telegram อยู่) แทน

-- 1) คอลัมน์ synced_at
alter table leaves add column if not exists synced_at timestamptz;
alter table logs add column if not exists synced_at timestamptz;
alter table ot_requests add column if not exists synced_at timestamptz;

-- 2) คอลัมน์ตั้งค่าใน settings
alter table settings add column if not exists gsheet_webapp_url text;
alter table settings add column if not exists gsheet_secret text;
alter table settings add column if not exists gsheet_last_sync timestamptz;

-- 3) เปิดใช้ extension http แบบ synchronous (รอผลลัพธ์ได้ทันทีในฟังก์ชันเดียว ไม่ต้อง poll เหมือน pg_net)
create extension if not exists http with schema extensions;

-- 4) ★ ตั้งค่า URL + secret ตรงนี้ (แก้ค่าให้ตรงกับที่ตั้งในไฟล์ .gs แล้วรันบรรทัดนี้แยกเองอีกที) ★
-- update settings set gsheet_webapp_url = 'https://script.google.com/macros/s/xxxxxxxx/exec',
--                      gsheet_secret     = 'รหัสลับเดียวกับที่ตั้งใน Apps Script'
-- where id = 1;

-- 5) ฟังก์ชันหลัก — ดึงข้อมูลที่ยังไม่ sync ทั้ง 4 รายงาน ส่งไป Google Sheets ทีเดียว
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
  v_status int;
  v_content text;
  rec record;
begin
  select gsheet_webapp_url, gsheet_secret into v_url, v_secret from settings where id = 1;
  if v_url is null or v_url = '' then
    return jsonb_build_object('ok', false, 'error', 'ยังไม่ได้ตั้งค่า gsheet_webapp_url ใน settings');
  end if;

  -- ===== ขาดลา (leaves) — ส่งทุกสถานะ เพื่อเก็บเป็นบันทึกครบถ้วน =====
  for rec in
    select l.id, l.requested_at, e.name as emp_name, br.name as branch_name,
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
      to_char(rec.requested_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI'),
      coalesce(rec.emp_name, '(ลบแล้ว)'),
      coalesce(rec.branch_name, '-'),
      rec.kind,
      rec.from_date::text,
      rec.to_date::text,
      case when rec.from_time is not null then rec.from_time::text || '-' || rec.to_time::text else '' end,
      case when rec.from_time is not null then round(extract(epoch from (rec.to_time::time - rec.from_time::time))/3600.0, 1)
           else (rec.to_date - rec.from_date + 1) end,
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

  -- ต้องส่งค้าง OT requests ที่ status='approved' แล้วแต่ยังไม่เคย sync ตอน pending มาก่อน จะไม่ถูกส่งซ้ำตอน pending
  -- (เพราะ query กรอง status='approved' อยู่แล้ว ไม่ดึงตอนยัง pending มา mark synced ก่อนเวลา)

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

  select status, content into v_status, v_content
  from extensions.http_post(v_url, v_payload::text, 'application/json');

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
      'note', 'ส่งไม่สำเร็จ ไม่ได้ mark synced_at ไว้ รอบถัดไปจะลองส่งซ้ำอัตโนมัติ');
  end if;
end;
$$;

-- 6) grant ให้ anon เรียกผ่าน RPC จากแอปได้ (ปุ่ม "Export ตอนนี้")
grant execute on function sync_to_google_sheets() to anon;

-- 7) ตั้ง cron ให้รันทุก 15 นาที
select cron.schedule('gsheet-realtime-backup', '*/15 * * * *', $$select sync_to_google_sheets();$$);

-- ทดสอบทันที (ต้องตั้งค่า URL/secret ในขั้นตอนที่ 4 ก่อน):
-- select sync_to_google_sheets();
