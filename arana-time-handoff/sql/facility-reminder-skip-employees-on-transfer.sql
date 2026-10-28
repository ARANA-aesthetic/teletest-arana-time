-- ARANA TIME — แจ้งเตือน "ความเรียบร้อย" ต้องไม่นับพนักงานที่ไปทำงานสาขาอื่น/นอกสถานที่ (อนุมัติแล้ว) ในวันนั้น
-- ออมรันเองใน Supabase SQL editor ของโปรเจกต์ ARANA TIME (Claude ไม่ได้รันให้ ตามกฎที่ตั้งไว้) — เก็บไฟล์นี้ไว้เป็นบันทึกในโปรเจกต์
--
-- ที่มา: 24-28 ต.ค. 69 พนักงานอุ้มบุญ (สาขาต้นสังกัดพิษณุโลก) ไปทำงานสาขานครสวรรค์ (คำขออนุมัติแล้ว) แต่ยังโผล่ในแจ้งเตือน
-- "ความเรียบร้อย ไม่ครบ" ของกลุ่มพิษณุโลกทั้งรอบ 11:30 และรอบเตือนซ้ำรายชั่วโมง
--
-- ต้นเหตุ: send_facility_missing_reminder() ไล่รายชื่อพนักงานจาก employees.branch_id (สาขาต้นสังกัด) แล้วข้ามเฉพาะคนที่มี
-- ใบลาอนุมัติแล้ว ไม่เคยเช็คตาราง branch_transfers เลย
--
-- แก้โดยเพิ่มเงื่อนไขในลูปรายชื่อพนักงาน: ถ้ามีแถวใน branch_transfers สถานะ approved ที่ครอบคลุมวันนี้ (v_today อยู่ระหว่าง
-- from_date–to_date) ไม่ว่าจะไปสาขาไหนหรือ 'offsite' ให้ข้ามคนนั้นไปเลย (ไม่นับว่าต้องส่ง ไม่เตือน) — ส่วนอื่นของฟังก์ชัน
-- เหมือนเวอร์ชันล่าสุดใน snapshot-reports-fresh-retry-and-facility-hourly-followup.sql ทุกประการ
-- (ฝั่งแอปแก้คู่กันไว้แล้ว: หน้า "ตรวจ" และสถิติหน้าภาพรวมข้ามคนที่ไปทำงานสาขาอื่นเช่นกัน)

CREATE OR REPLACE FUNCTION public.send_facility_missing_reminder(p_branch_id text default null, p_skip_if_complete boolean default false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_token text; v_today date; v_branch record; v_point record; v_emp record;
  v_clean_missing text[]; v_clean_total int;
  v_groom_missing text[]; v_groom_total int;
  v_msg text; v_done boolean; v_on_leave boolean; v_on_transfer boolean;
  v_display_name text; v_request_id bigint;
begin
  select central_token into v_token from settings where id = 1;
  if v_token is null or v_token = '' then return; end if;
  v_today := (now() at time zone 'Asia/Bangkok')::date;

  for v_branch in select id, name, chat_id_facility, cleaning_points from branches
    where chat_id_facility is not null and chat_id_facility != ''
      and (p_branch_id is null or id = p_branch_id)
  loop
    if is_shop_closed(v_branch.id, v_today) then continue; end if;
    v_clean_missing := array[]::text[]; v_clean_total := 0;
    v_groom_missing := array[]::text[]; v_groom_total := 0;

    for v_point in select value->>'id' as pid, value->>'name' as pname
      from jsonb_array_elements(coalesce(v_branch.cleaning_points,'[]'::jsonb)) loop
      v_clean_total := v_clean_total + 1;
      select exists(select 1 from logs where branch_id = v_branch.id and type = 'CLEAN'
        and clean_point_id = v_point.pid
        and (time at time zone 'Asia/Bangkok')::date = v_today) into v_done;
      if not v_done then v_clean_missing := array_append(v_clean_missing, v_point.pname); end if;
    end loop;

    for v_emp in select id, name, nickname from employees
      where branch_id = v_branch.id and department = 'หน้าร้าน'
        and coalesce(active, true) = true
        and (start_date is null or start_date <= v_today)
        and (resign_date is null or resign_date >= v_today)
    loop
      select exists(select 1 from leaves where employee_id = v_emp.id and status = 'approved'
        and from_date <= v_today and to_date >= v_today) into v_on_leave;
      if v_on_leave then continue; end if;

      select exists(select 1 from branch_transfers where employee_id = v_emp.id and status = 'approved'
        and from_date <= v_today and to_date >= v_today) into v_on_transfer;
      if v_on_transfer then continue; end if;

      v_groom_total := v_groom_total + 1;
      select exists(select 1 from logs where branch_id = v_branch.id and type = 'GROOM'
        and employee_id = v_emp.id
        and (time at time zone 'Asia/Bangkok')::date = v_today) into v_done;
      if not v_done then
        v_display_name := split_part(v_emp.name, ' ', 1) ||
          case when v_emp.nickname is not null and v_emp.nickname != '' then ' (' || v_emp.nickname || ')' else '' end;
        v_groom_missing := array_append(v_groom_missing, v_display_name);
      end if;
    end loop;

    if v_clean_total = 0 and v_groom_total = 0 then continue; end if;
    if p_skip_if_complete and coalesce(array_length(v_clean_missing,1),0) = 0
       and coalesce(array_length(v_groom_missing,1),0) = 0 then continue; end if;

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

    perform tg_send('send_facility_missing_reminder', v_branch.name, v_branch.chat_id_facility, v_msg, v_branch.id);
  end loop;
end;
$function$;
