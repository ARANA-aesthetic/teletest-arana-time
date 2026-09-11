-- ARANA TIME — ทำให้แจ้งเตือน 23:30 เป็นข้อความ "สรุป/คั่นวัน" เสมอ ไม่ใช่แค่เตือนตอนค้าง
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- เดิม send_pending_leave_alert() (สร้างไว้ใน missing-scan-time-and-pending-leave-alert.sql)
-- จะส่งเข้ากลุ่มก็ต่อเมื่อมีใบลาที่ยื่นวันนั้นแล้วยังไม่มีใครอนุมัติเท่านั้น — ถ้าอนุมัติครบแล้วจะไม่ส่งอะไรเลย
--
-- ผู้ใช้ต้องการให้ส่งข้อความสรุปทุกวันที่มีการยื่นลา ไม่ว่าจะอนุมัติครบหรือยังค้างอยู่ก็ตาม
-- เพื่อให้เป็นข้อความคั่นระหว่างวัน และให้ทุกคนที่มีสิทธิ์อนุมัติเห็นภาพรวมร่วมกันว่าเคลียร์ไปถึงไหนแล้ว
-- (ไม่ใช่แค่คนที่บังเอิญเห็นตอนมีคำเตือนค้างอยู่) — แก้โดยแสดงรายการ "ทุกสถานะ" ของวันนั้น พร้อมระบุ
-- ✅อนุมัติแล้ว / ❌ปฏิเสธแล้ว / ⏳ยังไม่มีใครอนุมัติ ต่อท้ายแต่ละรายการ ยังไม่มีใครยื่นลาเลยวันนั้นก็ยังไม่ส่งอะไร
create or replace function send_pending_leave_alert()
returns void language plpgsql security definer as $$
declare
  v_token text; v_central text; v_today date;
  v_leave record; v_lines text[] := array[]::text[]; v_total int := 0; v_pending int := 0;
  v_display_name text; v_msg text; v_status_label text;
begin
  select central_token, central_chat_id into v_token, v_central from settings where id = 1;
  if v_token is null or v_token = '' or v_central is null or v_central = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_leave in
    select l.kind, l.status, e.name, e.nickname
    from leaves l
    join employees e on e.id = l.employee_id
    where (l.requested_at at time zone 'Asia/Bangkok')::date = v_today
    order by l.requested_at
  loop
    v_total := v_total + 1;
    v_display_name := split_part(v_leave.name, ' ', 1) || case when v_leave.nickname is not null and v_leave.nickname != '' then ' (' || v_leave.nickname || ')' else '' end;
    v_status_label := case v_leave.status when 'approved' then '✅อนุมัติแล้ว' when 'rejected' then '❌ปฏิเสธแล้ว' else '⏳ยังไม่มีใครอนุมัติ' end;
    if v_leave.status = 'pending' then v_pending := v_pending + 1; end if;
    v_lines := array_append(v_lines, v_total || '. ' || v_display_name || ' (' || v_leave.kind || ') — ' || v_status_label);
  end loop;

  if v_total = 0 then return; end if;

  if v_pending > 0 then
    v_msg := '⚠️สรุปคำขอลาที่ยื่นวันนี้ — ยังค้างไม่อนุมัติ ' || v_pending || '/' || v_total || ' รายการ';
  else
    v_msg := '✅สรุปคำขอลาที่ยื่นวันนี้ — พิจารณาครบแล้วทุกรายการ (' || v_total || ' รายการ)';
  end if;
  v_msg := v_msg || E'\n' || array_to_string(v_lines, E'\n');
  if v_pending > 0 then
    v_msg := v_msg || E'\n\nกรุณาอนุมัติ/ปฏิเสธก่อนสิ้นวัน';
  end if;

  perform tg_send('send_pending_leave_alert', null, v_central, v_msg);
end;
$$;

-- นอกจากนี้ยังแก้ฝั่งเว็บ (teletest-arana-time.html, decideTransfer()) ให้ข้อความแจ้งผลอนุมัติ
-- คำขอ "ไปทำงานนอกสถานที่" เข้ากลุ่มส่วนกลางแบบสั้นเมื่ออนุมัติแล้ว:
--   ✅อนุมัติโดย : ชื่อผู้อนุมัติ
--   ▪️ชื่อ(ชื่อเล่น)พนักงาน
--   ▪️ไปทำงาน[เป้าหมาย] — เหตุผลที่ระบุ
--   ▪️วันที่
-- กรณีปฏิเสธยังคงรูปแบบเดิม (ระบุเหตุผลที่ยื่นไว้) ไม่ได้แก้ตรงนี้
