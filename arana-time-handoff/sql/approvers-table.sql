-- ARANA TIME — สร้างตารางผู้อนุมัติ (HR / ผู้จัดการ / กรรมการ)
-- รันใน Supabase SQL Editor

create table if not exists approvers (
  id text primary key,
  name text,
  pin text,
  role text,
  updated_at timestamptz default now()
);

alter table approvers enable row level security;
create policy "allow anon full access" on approvers for all using (true) with check (true);
