-- ARANA TIME — ตารางคำขอไปทำงานสาขาอื่น (#27)
-- รันใน Supabase SQL Editor

create table if not exists branch_transfers (
  id text primary key,
  employee_id text,
  branch_id text,
  from_date date,
  to_date date,
  reason text,
  status text default 'pending',
  requested_at timestamptz,
  decided_at timestamptz
);

alter table branch_transfers enable row level security;
create policy "allow anon full access" on branch_transfers for all using (true) with check (true);
