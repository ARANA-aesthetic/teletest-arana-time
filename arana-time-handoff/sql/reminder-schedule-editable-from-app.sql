-- ARANA TIME — เพิ่มเมนูตั้งค่าเวลาส่งแจ้งเตือนอัตโนมัติ (ปรับได้เองจากแอป ไม่ต้องแก้ pg_cron ตรงๆ)
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- ที่มา: หลังจากทำระบบเตือนซ้ำรายชั่วโมงให้ปิดแอร์/ความสะอาด/ความเรียบร้อย (ดูไฟล์
-- snapshot-reports-fresh-retry-and-facility-hourly-followup.sql) user อยากปรับเวลาต่างๆ เองได้จากแอป
-- โดยตรง ไม่ต้องรอทีมพัฒนาไปแก้ให้ทุกครั้ง — และขอให้อยู่ในหน้าตั้งค่าเดิม (การแจ้งเตือน Telegram)
-- ไม่สร้างหน้าใหม่แยก เพราะเริ่มมีหลายหน้าจนสับสนแล้ว
--
-- เพิ่ม RPC 2 ตัว เปิดให้ anon เรียกได้ (ตามรูปแบบเดิมของโปรเจกต์ที่ยกสิทธิ์ผ่าน SECURITY DEFINER
-- function เท่านั้น ไม่เปิด schema cron ให้เข้าถึงตรงๆ):
-- - get_reminder_times() — อ่านตารางเวลาปัจจุบันของ 6 งานที่ปรับได้ (คืนเป็น cron string ดิบ, UTC)
-- - update_reminder_time(job_name, hour, minute, end_hour) — แปลงเวลาไทย (ICT, UTC+7) ที่ผู้ใช้กรอก
--   เป็น UTC แล้วเรียก cron.alter_job() จำกัดเฉพาะชื่องานที่รู้จักเท่านั้น กัน SQL แปลกปลอมจาก client
--   (end_hour ใช้เฉพาะ facility-missing-hourly-followup ที่เป็นช่วงเวลาเริ่ม-สิ้นสุด งานอื่นเป็นเวลาเดียว)
--
-- ฝั่งแอป: หน้าตั้งค่า → การแจ้งเตือน Telegram → เพิ่มการ์ด "เวลาส่งแจ้งเตือนอัตโนมัติ" อ่านค่าปัจจุบัน
-- มาแสดงตอนเข้าหน้า Admin ทุกครั้ง (loadReminderSchedule) และมีปุ่มบันทึกเรียกทั้ง 6 ค่ากลับไปตั้งใหม่
--
-- ทดสอบแล้ว: ตั้งค่าเดิมกลับเข้าไปใหม่ (round-trip) แล้วเช็ค cron.job ตรงกับก่อนแก้ทุกตัว ไม่มีผลกระทบ
CREATE OR REPLACE FUNCTION public.get_reminder_times()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_result jsonb := '{}'::jsonb;
  v_row record;
begin
  for v_row in
    select jobname, schedule from cron.job
    where jobname in ('daily-leave-summary','hourly-leave-checkin-summary','facility-missing-reminder',
                       'facility-missing-hourly-followup','missing-leave-evidence-reminder','ac-missing-reminder')
  loop
    v_result := v_result || jsonb_build_object(v_row.jobname, v_row.schedule);
  end loop;
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_reminder_time(p_job_name text, p_hour int, p_minute int, p_end_hour int default null)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_utc_hour int;
  v_utc_end_hour int;
  v_cron text;
  v_jobid bigint;
begin
  if p_job_name not in ('daily-leave-summary','hourly-leave-checkin-summary','facility-missing-reminder',
                         'facility-missing-hourly-followup','missing-leave-evidence-reminder','ac-missing-reminder') then
    raise exception 'invalid job name: %', p_job_name;
  end if;
  if p_hour is null or p_hour < 0 or p_hour > 23 or p_minute is null or p_minute < 0 or p_minute > 59 then
    raise exception 'invalid time';
  end if;

  v_utc_hour := (p_hour - 7 + 24) % 24;

  if p_job_name = 'facility-missing-hourly-followup' then
    if p_end_hour is null or p_end_hour < 0 or p_end_hour > 23 then
      raise exception 'invalid end hour';
    end if;
    v_utc_end_hour := (p_end_hour - 7 + 24) % 24;
    if v_utc_end_hour < v_utc_hour then
      raise exception 'เวลาสิ้นสุดต้องอยู่หลังเวลาเริ่ม (ยังไม่รองรับช่วงข้ามเที่ยงคืน)';
    end if;
    v_cron := p_minute || ' ' || v_utc_hour || '-' || v_utc_end_hour || ' * * *';
  else
    v_cron := p_minute || ' ' || v_utc_hour || ' * * *';
  end if;

  select jobid into v_jobid from cron.job where jobname = p_job_name;
  if v_jobid is null then raise exception 'job not found: %', p_job_name; end if;

  perform cron.alter_job(job_id => v_jobid, schedule => v_cron);
  return jsonb_build_object('ok', true, 'cron', v_cron);
end;
$function$;

grant execute on function public.get_reminder_times() to anon;
grant execute on function public.update_reminder_time(text, int, int, int) to anon;
