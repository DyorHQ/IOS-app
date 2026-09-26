-- 26_storage_write_once_and_upload_limits — the public buckets stop being free, mutable file hosting (security audit
-- 2026-09-26, OH-6, SB-6 / PR-2, and the storage half of SB-2).
--
-- 1. launch-media is write-once: launch_media_owner_update is dropped, so no object can be overwritten. The public
--    URL of a launch-media object is written on-chain (a token's logo, a Moment's media mirror, a video Moment's poster
--    fallback), and with UPDATE allowed its creator could swap the bytes behind that immutable pointer at any time. A
--    Moment's poster is filed under the VIDEO's hash (moment-<video hash>.jpg), so its bytes are not covered by the
--    on-chain hash either (PR-2). Every name the app writes is unique per content or per upload (<uuid>.jpg,
--    moment-<keccak>.<ext>), so a first upload never needs UPDATE — including one sent with x-upsert: true, which
--    PostgreSQL checks against the UPDATE policy only when the object already exists. What changes: re-uploading a
--    path that already exists is refused. The app should upload launch-media with x-upsert: false and treat
--    409 Duplicate as "already uploaded" (for moment-<keccak> names the stored bytes are the same by construction).
--    There is still no owner DELETE policy on launch-media: on-chain pointers must keep resolving. Takedowns are a
--    service-role action (supabase/README.md, "Takedown").
-- 2. Upload names are pinned to what the app writes, and launch-media has a per-wallet quota:
--      avatars       <wallet>/avatar.jpg only (insert and update)
--      launch-media  <wallet>/<uuid>.jpg (launch logos), <wallet>/moment-<64 hex>.<jpg|mp4|mov> (Moment media) and
--                    <wallet>/moment-<uuid>.<jpg|mp4|mov> (the names builds before content-hash naming wrote)
--    plus at most 40 objects and 500 MB per wallet in any rolling 24 hours (launch_media_upload_allowed(): it counts
--    the caller's existing objects, so one more upload of up to the bucket's 50 MB limit can land on top). Every
--    object in both buckets was checked against these shapes on 2026-09-26 (read-only): only one manual test object
--    (<wallet>/selftest.jpg) falls outside them, and existing objects are not affected by an insert policy.
-- 3. Bucket MIME allow-lists shrink to the types the app has ever sent (checked in git history): avatars image/jpeg;
--    launch-media image/jpeg, video/mp4, video/quicktime. Size limits are re-asserted (5 MB and 50 MB).
--
-- Reverse:
--   create policy "launch_media_owner_update" on storage.objects for update to authenticated
--     using (bucket_id = 'launch-media' and (storage.foldername(name))[1] = public.app_wallet())
--     with check (bucket_id = 'launch-media' and (storage.foldername(name))[1] = public.app_wallet());
--   and recreate avatars_owner_insert / avatars_owner_update / launch_media_owner_insert as in migrations 08/09,
--   drop function public.launch_media_upload_allowed(), and restore the MIME lists from 08/10.
-- Verify after apply:
--   select policyname, cmd from pg_policies where schemaname = 'storage' and tablename = 'objects' order by 1;
--     -- no launch_media_owner_update
--   select id, file_size_limit, allowed_mime_types from storage.buckets where id in ('avatars', 'launch-media');
--   select has_function_privilege('anon', 'public.launch_media_upload_allowed()', 'execute'),          -- false
--          has_function_privilege('authenticated', 'public.launch_media_upload_allowed()', 'execute'); -- true

-- The per-wallet quota. SECURITY DEFINER so it counts the caller's objects whatever the SELECT policies are (it runs
-- as postgres, which bypasses RLS on this project); it only ever looks at the caller's own folder and returns a
-- boolean. The name range uses the (bucket_id, name COLLATE "C") index: '0' is the character after '/'.
create or replace function public.launch_media_upload_allowed()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select w.wallet is not null and (
    select count(*) < 40
       and coalesce(sum(case when o.metadata->>'size' ~ '^[0-9]{1,15}$' then (o.metadata->>'size')::bigint else 0 end), 0)
           < 500 * 1024 * 1024
      from storage.objects o
     where o.bucket_id = 'launch-media'
       and o.name collate "C" >= w.wallet || '/' and o.name collate "C" < w.wallet || '0'
       and o.created_at > now() - interval '1 day')
  from (select public.app_wallet() as wallet) w
$function$;

revoke all on function public.launch_media_upload_allowed() from public, anon, authenticated;
grant execute on function public.launch_media_upload_allowed() to authenticated, service_role;
comment on function public.launch_media_upload_allowed() is
  'Storage quota for the launch-media INSERT policy: true while the calling wallet (app_wallet()) has stored fewer than 40 objects and 500 MB in launch-media in the last 24 hours. Counts only the caller''s own folder; returns a boolean only.';

-- 1. launch-media: no overwrites.
drop policy if exists "launch_media_owner_update" on storage.objects;

-- 2. Pinned names and the quota.
drop policy if exists "launch_media_owner_insert" on storage.objects;
create policy "launch_media_owner_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'launch-media'
    and (storage.foldername(name))[1] = public.app_wallet()
    and name ~ '^0x[0-9a-f]{40}/(moment-([0-9a-f]{64}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(jpg|mp4|mov)|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg)$'
    and public.launch_media_upload_allowed()
  );

drop policy if exists "avatars_owner_insert" on storage.objects;
create policy "avatars_owner_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and name = public.app_wallet() || '/avatar.jpg');

drop policy if exists "avatars_owner_update" on storage.objects;
create policy "avatars_owner_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and name = public.app_wallet() || '/avatar.jpg')
  with check (bucket_id = 'avatars' and name = public.app_wallet() || '/avatar.jpg');

-- 3. Bucket limits.
update storage.buckets
   set file_size_limit = 5242880, allowed_mime_types = array['image/jpeg']
 where id = 'avatars';
update storage.buckets
   set file_size_limit = 52428800, allowed_mime_types = array['image/jpeg', 'video/mp4', 'video/quicktime']
 where id = 'launch-media';

-- Fail the migration if any of it did not take.
do $$
declare
  offending text;
begin
  select string_agg(policyname, ', ') into offending from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd in ('UPDATE', 'ALL')
     and (coalesce(qual, '') || coalesce(with_check, '')) like '%launch-media%';
  if offending is not null then
    raise exception 'launch-media objects can still be overwritten: %', offending;
  end if;
  if has_function_privilege('anon', 'public.launch_media_upload_allowed()', 'execute')
     or not has_function_privilege('authenticated', 'public.launch_media_upload_allowed()', 'execute') then
    raise exception 'launch_media_upload_allowed() must be executable by authenticated and not by anon';
  end if;
  if (select count(*) from storage.buckets
       where (id = 'avatars' and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg'])
          or (id = 'launch-media' and file_size_limit = 52428800
              and allowed_mime_types = array['image/jpeg', 'video/mp4', 'video/quicktime'])) <> 2 then
    raise exception 'bucket limits for avatars / launch-media did not take';
  end if;
end
$$;
