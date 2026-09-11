-- ARANA TIME — เลื่อนเวลาแจ้งเตือน "ลืมสแกน" เป็น 23:30 + เพิ่มแจ้งเตือนใบลาค้างอนุมัติ
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- (1) missing-scan-reminder (ข้อความ "⏰สรุปการสแกนเข้า-ออกงาน") เดิมส่งตอน 21:00 น.
--     ปัญหา: พนักงานที่ขอ OT ทำงานเลิกดึก ยังไม่ทันสแกนออกตอน 21:00 จะถูกขึ้นชื่อว่า "ยังไม่สแกนออก"
--     ทั้งที่ยังไม่ถึงเวลาเลิกงานจริง แก้โดยเลื่อนเวลาส่งเป็น 23:30 น. (Asia/Bangkok)
alter table logs add column if not exists manual_reason text;

select cron.alter_job(15, schedule => '30 16 * * *'); -- 16:30 UTC = 23:30 ICT (jobid ของ missing-scan-reminder)

-- (2) เพิ่มใหม่: แจ้งกลุ่มส่วนกลางตอน 23:30 น. ถ้ามีคำขอลาที่ยื่นวันนี้แล้วยังไม่มีใครอนุมัติ/ปฏิเสธเลย
--     กันเคสลืมอนุมัติจนข้ามวันไป พนักงานเข้าใจผิดว่าลาผ่านแล้ว
create or replace function send_pending_leave_alert()
returns void language plpgsql security definer as $$
declare
  v_token text; v_central text; v_today date;
  v_leave record; v_lines text[] := array[]::text[]; v_count int := 0;
  v_display_name text; v_msg text;
begin
  select central_token, central_chat_id into v_token, v_central from settings where id = 1;
  if v_token is null or v_token = '' or v_central is null or v_central = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_leave in
    select l.kind, e.name, e.nickname
    from leaves l
    join employees e on e.id = l.employee_id
    where l.status = 'pending'
      and (l.requested_at at time zone 'Asia/Bangkok')::date = v_today
    order by l.requested_at
  loop
    v_count := v_count + 1;
    v_display_name := split_part(v_leave.name, ' ', 1) || case when v_leave.nickname is not null and v_leave.nickname != '' then ' (' || v_leave.nickname || ')' else '' end;
    v_lines := array_append(v_lines, v_count || '. ' || v_display_name || ' (' || v_leave.kind || ')');
  end loop;

  if v_count = 0 then return; end if;

  v_msg := '⚠️มีคำขอลาที่ยื่นวันนี้ ยังไม่มีใครอนุมัติ (' || v_count || ' รายการ)' || E'\n' || array_to_string(v_lines, E'\n')
    || E'\n\nกรุณาอนุมัติ/ปฏิเสธก่อนสิ้นวัน';
  perform tg_send('send_pending_leave_alert', null, v_central, v_msg);
end;
$$;
grant execute on function send_pending_leave_alert() to anon;

select cron.schedule('pending-leave-alert', '30 16 * * *', $$select send_pending_leave_alert();$$);

-- (3) เพิ่มคอลัมน์ logs.manual_reason — ตอน HR บันทึก "ลืมสแกนเข้างาน" ย้อนหลังให้พนักงาน
--     (เมนู "ลืมสแกน" ในแท็บตรวจ) ตอนนี้บังคับให้ระบุเหตุผล/หลักฐานที่ได้รับแจ้งด้วย เพื่อโน้ตไว้เช็คย้อนหลังได้
--     (คอลัมน์นี้เพิ่มไว้ในบล็อกแรกด้านบนแล้ว เขียนซ้ำที่นี่เพื่อให้อ่านลำดับเหตุผลต่อเนื่องกัน)
