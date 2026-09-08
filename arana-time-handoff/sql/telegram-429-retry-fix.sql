-- ARANA TIME — แก้ resolve_telegram_send_log() ให้จัดการ 429 (Too Many Requests) ถูกต้อง
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration x2) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- ที่มา: เช้าวันที่ 8/9/2569 พนักงานสแกนเข้างานพร้อมกันหลายคน (Back Office 16 ครั้งใน ~2 ชม.)
-- ทำให้ Telegram ปฏิเสธการส่งรูปด้วยรหัส 429 "Too Many Requests: retry after N" เป็นชุด
-- ตรวจสอบแล้วว่าบอทไม่ได้เสีย (getMe ตอบ 200 ปกติ) — เป็น rate limit ต่อบอท ไม่ใช่ปัญหา token/บอทถูกลบ
--
-- พบบั๊ก 2 จุดในระบบ auto-retry ที่ทำให้แก้ปัญหานี้ไม่ได้เอง:
--
-- (1) resolve_telegram_send_log() เดิมเห็นว่ามี status_code กลับมา (ไม่ใช่ NULL) แล้วสรุปว่า
--     "Telegram ตอบมาแน่ชัดแล้วว่าไม่สำเร็จ ส่งซ้ำไม่ช่วย" แล้ว gave_up ทันที — ใช้ได้กับ error
--     ถาวรจริง (เช่น 400 chat not found) แต่ผิดสำหรับ 429 ซึ่ง Telegram บอกไว้ชัดว่า "ลองใหม่ได้"
--     แก้ไข: แยก 429 ออกมาให้เข้า branch เดียวกับ timeout (ลองใหม่ได้) แทนที่จะ gave_up ทันที
--
-- (2) เมื่อมีหลายแถวรอ retry พร้อมกัน (เช่น 4 สาขาที่โดน 429 พร้อมกันตอนเช้า) ฟังก์ชันเดิมยิง
--     คำขอทุกแถวติดกันไม่มีช่วงห่างเลย ทำให้ยิงรัวจนชนกันเองซ้ำแล้วซ้ำเล่า ไม่มีวันหลุดจาก 429
--     แก้ไข: เพิ่ม pg_sleep(1.3) คั่นระหว่างการยิงแต่ละครั้งในลูปเดียวกัน (เฉพาะตอนที่ยิงจริง)
--
-- นอกจากนี้ยังพบระหว่างแก้ไขว่า "อย่าเรียก resolve_telegram_send_log() มือเองพร้อมกับที่ cron
-- job (รันทุก 5 นาทีอยู่แล้ว) กำลังทำงาน" เพราะจะยิงซ้อนกัน 2 ชุดจนโดน rate limit หนักขึ้นไปอีก
-- ถ้าต้องการเร่งการส่งซ้ำ ให้รอรอบ cron ถัดไปแทนการเรียกเอง

create table if not exists system_heartbeat(
  name text primary key,
  last_run_at timestamptz not null,
  detail jsonb
);
alter table system_heartbeat enable row level security;
drop policy if exists system_heartbeat_read on system_heartbeat;
create policy system_heartbeat_read on system_heartbeat for select using (true);

create or replace function resolve_telegram_send_log()
returns jsonb language plpgsql security definer as $$
declare
  v_row record;
  v_resp record;
  v_token text;
  v_central text;
  v_new_request bigint;
  v_resolved int := 0;
  v_failed int := 0;
  v_retried int := 0;
  v_gave_up int := 0;
  v_alert text[] := array[]::text[];
begin
  select central_token, central_chat_id into v_token, v_central from settings where id = 1;

  for v_row in
    select * from telegram_send_log
    where resolved = false and gave_up = false and created_at > now() - interval '2 days'
  loop
    select status_code, content, error_msg, timed_out into v_resp
      from net._http_response where id = v_row.request_id;

    if v_resp.status_code = 200 then
      update telegram_send_log
        set status_code = 200, response = v_resp.content, resolved = true
        where id = v_row.id;
      v_resolved := v_resolved + 1;

    elsif v_resp.status_code is not null and v_resp.status_code <> 429 then
      -- ตอบกลับมาแน่ชัดว่าไม่สำเร็จด้วยเหตุผลที่ retry ไม่ช่วย (chat id ผิด / บอทถูกเตะออกจากกลุ่ม)
      update telegram_send_log
        set status_code = v_resp.status_code, response = v_resp.content, resolved = true, gave_up = true
        where id = v_row.id;
      v_failed := v_failed + 1;
      v_alert := array_append(v_alert, '• ' || v_row.fn_name || ' → ' || coalesce(v_row.branch_name,'-')
        || ' (ห้องปฏิเสธ รหัส ' || v_resp.status_code || ')');

    elsif v_resp.status_code = 429 or (v_resp.status_code is null and v_row.created_at < now() - interval '3 minutes') then
      -- 429 = โดนจำกัดอัตราส่งชั่วคราว ลองใหม่ได้เสมอ ไม่นับเป็นความล้มเหลวถาวร
      -- (NULL เกิน 3 นาที = timeout/คำขอหาย ก็ลองใหม่เหมือนกัน)
      if v_resp.error_msg is not null then
        update telegram_send_log set error_msg = v_resp.error_msg where id = v_row.id;
      end if;

      if v_row.created_at < now() - interval '2 hours' then
        update telegram_send_log set gave_up = true where id = v_row.id;
        v_gave_up := v_gave_up + 1;
        v_alert := array_append(v_alert, '• ' || v_row.fn_name || ' → ' || coalesce(v_row.branch_name,'-')
          || ' (ส่งไม่สำเร็จ เกินเวลาที่จะส่งย้อนหลัง)');
      elsif v_row.retry_count >= 5 or v_row.message_text is null or v_token is null or v_token = '' then
        update telegram_send_log set gave_up = true where id = v_row.id;
        v_gave_up := v_gave_up + 1;
        v_alert := array_append(v_alert, '• ' || v_row.fn_name || ' → ' || coalesce(v_row.branch_name,'-')
          || ' (ลองส่งซ้ำครบ ' || v_row.retry_count || ' ครั้งแล้วไม่สำเร็จ)');
      else
        -- เว้นจังหวะก่อนยิงแต่ละครั้ง (ยกเว้นครั้งแรกของรอบ) กันชนกันเองเมื่อมีหลายแถวรอพร้อมกัน
        if v_retried > 0 then perform pg_sleep(1.3); end if;
        v_new_request := net.http_post(
          url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
          headers := '{"Content-Type": "application/json"}'::jsonb,
          body := jsonb_build_object('chat_id', v_row.chat_id, 'text', v_row.message_text),
          timeout_milliseconds := 8000
        );
        update telegram_send_log
          set request_id = v_new_request, retry_count = v_row.retry_count + 1
          where id = v_row.id;
        v_retried := v_retried + 1;
      end if;
    end if;
  end loop;

  if array_length(v_alert,1) > 0 and v_token is not null and v_token <> '' and v_central is not null and v_central <> '' then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_central,
        'text', '⚠️ข้อความแจ้งเตือนส่งไม่สำเร็จ' || E'\n' || array_to_string(v_alert, E'\n')
                || E'\n\nกลุ่มที่ระบุไว้ข้างต้นไม่ได้รับข้อความรอบนี้ กรุณาแจ้งด้วยตนเอง'),
      timeout_milliseconds := 8000
    );
  end if;

  insert into system_heartbeat(name, last_run_at, detail)
    values ('resolve_telegram_send_log', now(),
            jsonb_build_object('resolved', v_resolved, 'failed', v_failed,
                               'retried', v_retried, 'gave_up', v_gave_up))
    on conflict (name) do update
      set last_run_at = excluded.last_run_at, detail = excluded.detail;

  return jsonb_build_object('resolved', v_resolved, 'failed', v_failed,
                            'retried', v_retried, 'gave_up', v_gave_up);
end;
$$;
grant execute on function resolve_telegram_send_log() to anon;
