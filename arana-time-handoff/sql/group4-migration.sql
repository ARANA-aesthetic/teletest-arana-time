-- ARANA TIME — Group 4 migration (#14 Audit log + แก้ไขรูป)
-- รันใน Supabase SQL Editor

create table if not exists audit_log (
  id text primary key,
  actor_name text,
  actor_role text,
  action text,
  target_type text,
  target_id text,
  details text,
  created_at timestamptz
);

alter table audit_log enable row level security;
create policy "allow anon full access" on audit_log for all using (true) with check (true);

alter table logs add column if not exists corrected boolean default false;
