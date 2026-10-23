-- خدمة الطباعة: نفّذ هذا الملف في Supabase SQL Editor بعد إنشاء المشروع.
-- فعّل Anonymous Sign-ins من Authentication > Providers قبل استخدام صفحة الزبون.
drop function if exists public.claim_existing_print_account(text,text);
create table if not exists public.print_users (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 40),
  phone text not null check (phone ~ '^0[567][0-9]{8}$'),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  approved_at timestamptz
);
alter table public.print_users drop constraint if exists print_users_phone_check;
alter table public.print_users add constraint print_users_phone_check check (phone ~ '^0[567][0-9]{8}$');
create unique index if not exists print_users_phone_unique on public.print_users(phone);

-- جلسات إضافية يربطها المدير يدويًا بعد التحقق؛ لا تُنقل بيانات الحساب الأصلية.
create table if not exists public.print_user_access (
  user_id uuid not null references public.print_users(id) on delete cascade,
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  verified_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (user_id,auth_user_id)
);

create table if not exists public.print_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.print_users(id) on delete cascade,
  color text not null check (color in ('bw','color')),
  paper_size text not null,
  paper_type text not null,
  copies integer not null check (copies between 1 and 10000),
  pricing_quantity integer,
  unit_price numeric(10,2),
  total_price numeric(12,2),
  notes text not null default '',
  status text not null default 'pending' check (status in ('pending','accepted','printing','done','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.print_jobs drop constraint if exists print_jobs_copies_check;
alter table public.print_jobs add constraint print_jobs_copies_check check (copies between 1 and 10000);
alter table public.print_jobs add column if not exists pricing_quantity integer;
alter table public.print_jobs add column if not exists unit_price numeric(10,2);
alter table public.print_jobs add column if not exists total_price numeric(12,2);

create table if not exists public.print_job_files (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.print_jobs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  file_name text not null,
  object_path text not null unique,
  mime_type text not null,
  byte_size bigint not null check (byte_size between 1 and 10485760),
  created_at timestamptz not null default now()
);

-- سجل تكاليف دائم: يبقى بعد حذف الطلب، ويحذف تلقائيًا عند حذف المستخدم.
create table if not exists public.print_job_charges (
  job_id uuid primary key,
  user_id uuid not null references public.print_users(id) on delete cascade,
  amount numeric(12,2) not null check (amount >= 0),
  created_at timestamptz not null default now()
);

-- مصدر التسعيرة الوحيد: لا توجد صفوف لـ A5 أو للتركيبات غير المعتمدة.
create table if not exists public.print_price_tiers (
  color text not null check (color in ('bw','color')),
  paper_type text not null check (paper_type in ('normal','photo-medium','photo-good')),
  paper_size text not null check (paper_size in ('A3','A4')),
  min_quantity integer not null check (min_quantity >= 1),
  max_quantity integer,
  unit_price numeric(10,2) not null check (unit_price > 0),
  primary key (color,paper_type,paper_size,min_quantity),
  check (max_quantity is null or max_quantity >= min_quantity)
);
insert into public.print_price_tiers(color,paper_type,paper_size,min_quantity,max_quantity,unit_price) values
 ('bw','normal','A4',1,19,10),('bw','normal','A4',20,49,8),('bw','normal','A4',50,99,7),('bw','normal','A4',100,199,6),('bw','normal','A4',200,499,5),('bw','normal','A4',500,null,5),
 ('color','normal','A4',1,9,30),('color','normal','A4',10,24,25),('color','normal','A4',25,49,20),('color','normal','A4',50,99,18),('color','normal','A4',100,199,15),('color','normal','A4',200,null,15),
 ('color','photo-medium','A4',1,9,70),('color','photo-medium','A4',10,24,65),('color','photo-medium','A4',25,49,60),('color','photo-medium','A4',50,99,55),('color','photo-medium','A4',100,null,50),
 ('color','photo-good','A4',1,9,120),('color','photo-good','A4',10,24,110),('color','photo-good','A4',25,49,100),('color','photo-good','A4',50,99,90),('color','photo-good','A4',100,null,80),
 ('bw','normal','A3',1,19,20),('bw','normal','A3',20,49,16),('bw','normal','A3',50,99,14),('bw','normal','A3',100,199,12),('bw','normal','A3',200,499,10),('bw','normal','A3',500,null,10),
 ('color','normal','A3',1,9,60),('color','normal','A3',10,24,50),('color','normal','A3',25,49,40),('color','normal','A3',50,99,36),('color','normal','A3',100,199,30),('color','normal','A3',200,null,30),
 ('color','photo-medium','A3',1,9,140),('color','photo-medium','A3',10,24,130),('color','photo-medium','A3',25,49,120),('color','photo-medium','A3',50,99,110),('color','photo-medium','A3',100,null,100),
 ('color','photo-good','A3',1,9,240),('color','photo-good','A3',10,24,220),('color','photo-good','A3',25,49,200),('color','photo-good','A3',50,99,180),('color','photo-good','A3',100,null,160)
on conflict (color,paper_type,paper_size,min_quantity) do update set max_quantity=excluded.max_quantity,unit_price=excluded.unit_price;

alter table public.print_jobs enable row level security;
alter table public.print_job_files enable row level security;
alter table public.print_price_tiers enable row level security;
drop policy if exists "authenticated reads print price tiers" on public.print_price_tiers;
create policy "authenticated reads print price tiers" on public.print_price_tiers for select to authenticated using (true);
create or replace function public.finalize_print_job_pricing(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_job record;
  v_file_count integer;
  v_image_count integer;
  v_quantity integer;
  v_customer_id uuid;
  v_unit_price numeric(10,2);
  v_total numeric(12,2);
begin
  select j.id,j.user_id,j.color,j.paper_size,j.paper_type,j.copies,j.pricing_quantity,j.unit_price,j.total_price into v_job
  from public.print_jobs j where j.id=p_job_id;
  if not found then raise exception 'الطلب غير موجود'; end if;
  v_customer_id := coalesce(auth.uid(),(select a.user_id from public.print_user_access a where a.auth_user_id=auth.uid()));
  if auth.uid() is not null and v_job.user_id <> v_customer_id then
    raise exception 'غير مخول لتسعير هذا الطلب';
  end if;
  if v_job.pricing_quantity is not null and v_job.unit_price is not null and v_job.total_price is not null then
    return jsonb_build_object('quantity',v_job.pricing_quantity,'unit_price',v_job.unit_price,'total_price',v_job.total_price);
  end if;
  select count(*),count(*) filter (where f.mime_type like 'image/%' or lower(f.file_name) ~ '\.(jpg|jpeg|png)$')
  into v_file_count,v_image_count from public.print_job_files f where f.job_id=p_job_id;
  if v_file_count=0 or (v_image_count>0 and v_image_count<>v_file_count) then
    update public.print_jobs set pricing_quantity=null,unit_price=null,total_price=null where id=p_job_id;
    return null;
  end if;
  v_quantity := case when v_image_count>0 then v_image_count*v_job.copies else v_job.copies end;
  select t.unit_price into v_unit_price from public.print_price_tiers t
  where t.color=v_job.color and t.paper_type=v_job.paper_type and t.paper_size=v_job.paper_size
    and v_quantity>=t.min_quantity and (t.max_quantity is null or v_quantity<=t.max_quantity)
  limit 1;
  if v_unit_price is null then
    update public.print_jobs set pricing_quantity=null,unit_price=null,total_price=null where id=p_job_id;
    return null;
  end if;
  v_total := v_unit_price*v_quantity;
  update public.print_jobs set pricing_quantity=v_quantity,unit_price=v_unit_price,total_price=v_total where id=p_job_id;
  return jsonb_build_object('quantity',v_quantity,'unit_price',v_unit_price,'total_price',v_total);
end;
$$;
revoke all on function public.finalize_print_job_pricing(uuid) from public, anon, authenticated;
grant execute on function public.finalize_print_job_pricing(uuid) to authenticated;

-- احسب أسعار الطلبات التاريخية المدعومة، واترك التركيبات غير المسعرة بلا مبلغ.
do $$ declare r record; begin
  for r in select id from public.print_jobs loop
    perform public.finalize_print_job_pricing(r.id);
  end loop;
end $$;
delete from public.print_job_charges c using public.print_jobs j
where c.job_id=j.id and (j.status<>'done' or j.total_price is null);
update public.print_job_charges c set amount=j.total_price
from public.print_jobs j where c.job_id=j.id and j.status='done' and j.total_price is not null;
-- إزالة أي مبالغ قديمة سُجلت قبل اعتماد شرط اكتمال الطباعة.
delete from public.print_job_charges c
using public.print_jobs j
where c.job_id = j.id and j.status <> 'done';

grant select, insert, update, delete on public.print_users to authenticated;
grant select, update, delete on public.print_jobs to authenticated;
revoke insert on public.print_jobs from authenticated;
grant insert (id,user_id,color,paper_size,paper_type,copies,notes) on public.print_jobs to authenticated;
grant select, insert, delete on public.print_job_files to authenticated;
grant select, insert on public.print_job_charges to authenticated;
grant select on public.print_price_tiers to authenticated;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.print_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
revoke all on private.print_admins from public, anon, authenticated;

create or replace function public.is_print_admin()
returns boolean language sql stable security definer
set search_path = '' as $$
  select exists (select 1 from private.print_admins a where a.user_id = (select auth.uid()));
$$;
revoke all on function public.is_print_admin() from public;
grant execute on function public.is_print_admin() to authenticated;

create or replace function public.current_print_user_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select u.id from public.print_users u where u.id=(select auth.uid())),
    (select a.user_id from public.print_user_access a where a.auth_user_id=(select auth.uid()))
  );
$$;
revoke all on function public.current_print_user_id() from public, anon;
grant execute on function public.current_print_user_id() to authenticated;

-- لا توجد استعادة تلقائية بالاسم ورقم الهاتف؛ يلزم OTP أو تحقق يدوي من الإدارة.

alter table public.print_users enable row level security;
alter table public.print_jobs enable row level security;
alter table public.print_job_files enable row level security;
alter table public.print_job_charges enable row level security;
alter table public.print_user_access enable row level security;
revoke all on public.print_user_access from public, anon, authenticated;

drop policy if exists "admin reads print job charges" on public.print_job_charges;
create policy "admin reads print job charges" on public.print_job_charges for select to authenticated
using ((select public.is_print_admin()));
drop policy if exists "admin records print job charges" on public.print_job_charges;
create policy "admin records print job charges" on public.print_job_charges for insert to authenticated
with check ((select public.is_print_admin()));

drop policy if exists "customer reads own profile or admin reads all" on public.print_users;
create policy "customer reads own profile or admin reads all" on public.print_users for select to authenticated
using (id = (select public.current_print_user_id()) or (select public.is_print_admin()));
drop policy if exists "customer creates own pending profile" on public.print_users;
create policy "customer creates own pending profile" on public.print_users for insert to authenticated
with check (id = (select auth.uid()) and status = 'pending');
drop policy if exists "admin updates profiles" on public.print_users;
create policy "admin updates profiles" on public.print_users for update to authenticated
using ((select public.is_print_admin())) with check ((select public.is_print_admin()));
drop policy if exists "admin deletes profiles" on public.print_users;
create policy "admin deletes profiles" on public.print_users for delete to authenticated
using ((select public.is_print_admin()));

drop policy if exists "customer reads own jobs or admin reads all" on public.print_jobs;
create policy "customer reads own jobs or admin reads all" on public.print_jobs for select to authenticated
using (user_id = (select public.current_print_user_id()) or (select public.is_print_admin()));
drop policy if exists "approved customer creates own jobs" on public.print_jobs;
create policy "approved customer creates own jobs" on public.print_jobs for insert to authenticated
with check (user_id = (select public.current_print_user_id()) and exists (
  select 1 from public.print_users u where u.id = user_id and u.status = 'approved'
));
drop policy if exists "admin updates jobs" on public.print_jobs;
create policy "admin updates jobs" on public.print_jobs for update to authenticated
using ((select public.is_print_admin())) with check ((select public.is_print_admin()));
drop policy if exists "admin deletes jobs" on public.print_jobs;
create policy "admin deletes jobs" on public.print_jobs for delete to authenticated
using ((select public.is_print_admin()));

drop policy if exists "owner or admin reads file rows" on public.print_job_files;
create policy "owner or admin reads file rows" on public.print_job_files for select to authenticated
using (exists (
  select 1 from public.print_jobs j where j.id=job_id and j.user_id=(select public.current_print_user_id())
) or (select public.is_print_admin()));
drop policy if exists "owner or admin creates file rows" on public.print_job_files;
create policy "owner or admin creates file rows" on public.print_job_files for insert to authenticated
with check ((user_id = (select auth.uid()) and exists (
  select 1 from public.print_jobs j join public.print_users u on u.id = j.user_id
  where j.id = job_id and j.user_id = (select public.current_print_user_id()) and u.status = 'approved'
)) or (select public.is_print_admin()));
drop policy if exists "admin deletes file rows" on public.print_job_files;
create policy "admin deletes file rows" on public.print_job_files for delete to authenticated
using ((select public.is_print_admin()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('print-files', 'print-files', false, 10485760,
  array['image/jpeg','image/png','application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "customer uploads into own folder" on storage.objects;
create policy "customer uploads into own folder" on storage.objects for insert to authenticated
with check (bucket_id = 'print-files' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "owner or admin reads print files" on storage.objects;
create policy "owner or admin reads print files" on storage.objects for select to authenticated
using (bucket_id = 'print-files' and ((storage.foldername(name))[1] = (select auth.uid())::text or exists (
  select 1 from public.print_job_files f join public.print_jobs j on j.id=f.job_id
  where f.object_path=storage.objects.name and j.user_id=(select public.current_print_user_id())
) or (select public.is_print_admin())));
drop policy if exists "admin deletes print files" on storage.objects;
create policy "admin deletes print files" on storage.objects for delete to authenticated
using (bucket_id = 'print-files' and (select public.is_print_admin()));

-- إنشاء مدير:
-- 1) أضف المستخدم من Authentication > Users (بريد وكلمة مرور قوية).
-- 2) انسخ UUID الخاص به ونفّذ: insert into private.print_admins(user_id) values ('UUID');

-- حدّث مخطط PostgREST حتى تظهر الدوال الجديدة للواجهة مباشرة.
notify pgrst, 'reload schema';
