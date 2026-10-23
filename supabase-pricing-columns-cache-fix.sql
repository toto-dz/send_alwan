-- إصلاح مخطط أعمدة التسعير في print_jobs وذاكرة PostgREST.
-- آمن لإعادة التشغيل: لا يحذف بيانات أو أعمدة موجودة.
begin;

alter table public.print_jobs
  add column if not exists pricing_quantity integer,
  add column if not exists unit_price numeric(10,2),
  add column if not exists total_price numeric(12,2);

notify pgrst, 'reload schema';
commit;
