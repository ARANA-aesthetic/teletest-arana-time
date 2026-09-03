-- ARANA TIME — สรุปตรวจความเรียบร้อย 11:30 น. ต้องไม่นับพนักงานที่มีใบลาอนุมัติแล้ว
-- รันผ่าน Supabase MCP connector ไปแล้ว (apply_migration) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- ที่มา: user ถามว่าพนักงานที่แจ้งลาไว้จะถูกนับเป็น "ไม่ได้ส่งตรวจ" ในสรุปความเรียบร้อยไหม ตรวจโค้ดแล้ว
-- พบว่า loop เช็ค GROOM log ของ send_facility_missing_reminder() ดึงพนักงาน department='หน้าร้าน' ทุกคน
-- มาเช็คโดยไม่ได้ดูใบลาเลย ถ้าลาเต็มวัน (ไม่ได้มาทำงานจริง) จะถูกนับเป็น ❌ไม่ครบ ผิดๆ ทั้งที่ไม่ได้มาทำงาน
--
-- แก้ไข: ข้ามพนักงานที่มีใบลาอนุมัติแล้วครอบคลุมวันนี้ ไม่นับทั้งครบ/ไม่ครบเลย (เหมือนไม่มีตัวตนในสรุปวันนั้น)
-- ส่วนจุดปิดแอร์/ความสะอาด (นับตามสถานที่ ไม่ใช่ตามคน) ไม่ต้องแก้เพราะใครทำงานอยู่ก็ยังต้องส่งแทนกันได้

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
  v_clean_missing text[];
  v_clean_total int;
  v_groom_missing text[];
  v_groom_total int;
  v_msg text;
  v_done boolean;
  v_on_leave boolean;
  v_display_name text;
  v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, cleaning_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;
    v_clean_missing := array[]::text[];
    v_clean_total := 0;
    v_groom_missing := array[]::text[];
    v_groom_total := 0;

    for v_point in select value->>'id' as pid, value->>'name' as pname from jsonb_array_elements(coalesce(v_branch.cleaning_points,'[]'::jsonb)) loop
      v_clean_total := v_clean_total + 1;
      select exists(
        select 1 from logs
        where branch_id = v_branch.id and type = 'CLEAN' and clean_point_id = v_point.pid
          and (time at time zone 'Asia/Bangkok')::date = v_today
      ) into v_done;
      if not v_done then
        v_clean_missing := array_append(v_clean_missing, v_point.pname);
      end if;
    end loop;

    for v_emp in select id, name, nickname from employees where branch_id = v_branch.id and department = 'หน้าร้าน' loop
      select exists(
        select 1 from leaves
        where employee_id = v_emp.id and status = 'approved'
          and from_date <= v_today and to_date >= v_today
      ) into v_on_leave;
      if v_on_leave then continue; end if;

      v_groom_total := v_groom_total + 1;
      select exists(
        select 1 from logs
        where branch_id = v_branch.id and type = 'GROOM' and employee_id = v_emp.id
          and (time at time zone 'Asia/Bangkok')::date = v_today
      ) into v_done;
      if not v_done then
        v_display_name := split_part(v_emp.name, ' ', 1) || case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
        v_groom_missing := array_append(v_groom_missing, v_display_name);
      end if;
    end loop;

    if v_clean_total = 0 and v_groom_total = 0 then continue; end if;

    v_msg := '📍สาขา ' || v_branch.name || E'\n🗓️วันที่ ' || to_char(v_today,'DD/MM/YYYY') || E'\n\n';

    if v_clean_total = 0 then
      v_msg := v_msg || '▪️ส่งความสะอาด' || E'\n-ไม่มี-';
    elsif array_length(v_clean_missing,1) > 0 then
      v_msg := v_msg || '▪️ส่งความสะอาด' || E'\n❌ไม่ครบ (' || array_length(v_clean_missing,1) || ' จุด)' || E'\n' ||
        (select string_agg('⛔' || x, E'\n') from unnest(v_clean_missing) as x);
    else
      v_msg := v_msg || '▪️ส่งความสะอาด' || E'\n✅ครบแล้ว (' || v_clean_total || ' จุด)';
    end if;

    v_msg := v_msg || E'\n\n';

    if v_groom_total = 0 then
      v_msg := v_msg || '▪️ความเรียบร้อย' || E'\n-ไม่มี-';
    elsif array_length(v_groom_missing,1) > 0 then
      v_msg := v_msg || '▪️ความเรียบร้อย' || E'\n❌ไม่ครบ (' || array_length(v_groom_missing,1) || ' คน)' || E'\n' ||
        (select string_agg('⛔' || x, E'\n') from unnest(v_groom_missing) as x);
    else
      v_msg := v_msg || '▪️ความเรียบร้อย' || E'\n✅ครบแล้ว (' || v_groom_total || ' คน)';
    end if;

    v_request_id := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object('chat_id', v_branch.chat_id_facility, 'text', v_msg),
      timeout_milliseconds := 10000
    );
    insert into telegram_send_log(fn_name, branch_name, chat_id, request_id)
      values ('send_facility_missing_reminder', v_branch.name, v_branch.chat_id_facility, v_request_id);
  end loop;
end;
$$;

grant execute on function send_facility_missing_reminder() to anon;
