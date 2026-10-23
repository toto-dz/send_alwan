-- استعادة يدوية آمنة لحسابات الطباعة.
-- لا يُحذف أو يُنقل أي سجل. يضيف الترحيل علاقة جلسة موثقة بملف الزبون الأصلي.
begin;

-- أزل RPC القديم الذي كان يسمح باستعادة الحساب اعتمادًا على الاسم والهاتف فقط.
drop function if exists public.claim_existing_print_account(text,text);

-- أضف مخطط التحقق من الأسعار للتركيبات الحالية، دون إنشاء/نقل طلبات أو ملفات.
alter table public.print_jobs add column if not exists pricing_quantity integer;
alter table public.print_jobs add column if not exists unit_price numeric(10,2);
alter table public.print_jobs add column if not exists total_price numeric(12,2);

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
alter table public.print_price_tiers enable row level security;
drop policy if exists "authenticated reads print price tiers" on public.print_price_tiers;
create policy "authenticated reads print price tiers" on public.print_price_tiers for select to authenticated using (true);
grant select on public.print_price_tiers to authenticated;

create table if not exists public.print_user_access (
  user_id uuid not null references public.print_users(id) on delete cascade,
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  verified_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (user_id,auth_user_id)
);
alter table public.print_user_access enable row level security;
revoke all on public.print_user_access from public, anon, authenticated;

create or replace function public.current_print_user_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select u.id from public.print_users u where u.id=(select auth.uid())),
    (select a.user_id from public.print_user_access a where a.auth_user_id=(select auth.uid()))
  );
$$;
revoke all on function public.current_print_user_id() from public, anon;
grant execute on function public.current_print_user_id() to authenticated;

-- أبقِ التحقق الخادمي للسعر، مع السماح للجلسة التي ربطتها الإدارة بالملف الأصلي.
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
  if auth.uid() is not null and v_job.user_id <> v_customer_id then raise exception 'غير مخول لتسعير هذا الطلب'; end if;
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

drop policy if exists "customer reads own profile or admin reads all" on public.print_users;
create policy "customer reads own profile or admin reads all" on public.print_users for select to authenticated
using (id=(select public.current_print_user_id()) or (select public.is_print_admin()));

drop policy if exists "customer reads own jobs or admin reads all" on public.print_jobs;
create policy "customer reads own jobs or admin reads all" on public.print_jobs for select to authenticated
using (user_id=(select public.current_print_user_id()) or (select public.is_print_admin()));

drop policy if exists "approved customer creates own jobs" on public.print_jobs;
create policy "approved customer creates own jobs" on public.print_jobs for insert to authenticated
with check (user_id=(select public.current_print_user_id()) and exists (
  select 1 from public.print_users u where u.id=user_id and u.status='approved'
));

drop policy if exists "owner or admin reads file rows" on public.print_job_files;
create policy "owner or admin reads file rows" on public.print_job_files for select to authenticated
using (exists (
  select 1 from public.print_jobs j where j.id=job_id and j.user_id=(select public.current_print_user_id())
) or (select public.is_print_admin()));

drop policy if exists "owner or admin creates file rows" on public.print_job_files;
create policy "owner or admin creates file rows" on public.print_job_files for insert to authenticated
with check (user_id=(select auth.uid()) and exists (
  select 1 from public.print_jobs j join public.print_users u on u.id=j.user_id
  where j.id=job_id and j.user_id=(select public.current_print_user_id()) and u.status='approved'
));

drop policy if exists "owner or admin reads print files" on storage.objects;
create policy "owner or admin reads print files" on storage.objects for select to authenticated
using (bucket_id='print-files' and (
  (storage.foldername(name))[1]=(select auth.uid())::text
  or exists (
    select 1 from public.print_job_files f join public.print_jobs j on j.id=f.job_id
    where f.object_path=storage.objects.name and j.user_id=(select public.current_print_user_id())
  )
  or (select public.is_print_admin())
));

notify pgrst, 'reload schema';
commit;

-- بعد التحقق من هوية الزبون خارج التطبيق، ينفذ المدير يدويًا من SQL Editor:
-- 1) ابحث عن الملف الأصلي باستخدام رقم الهاتف، وتأكد من الاسم:
--    select id,name,phone,status from public.print_users where phone='05xxxxxxxx';
-- 2) تحقق من UUID جلسة الجهاز الجديد عبر Authentication > Users، ومن UUID المدير:
--    select user_id from private.print_admins;
-- 3) أضف الربط دون تعديل أي بيانات موجودة:
--    insert into public.print_user_access(user_id,auth_user_id,verified_by)
--    values ('PROFILE_UUID','NEW_AUTH_UUID','ADMIN_AUTH_UUID');
-- 4) يحدّث الزبون الصفحة ويُدخل الاسم والهاتف المسجلين. لا تنشئ حسابًا بديلًا.
