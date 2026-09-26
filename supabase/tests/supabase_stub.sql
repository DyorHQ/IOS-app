-- A minimal stand-in for what a hosted Supabase project provides before any migration in ../migrations runs: the API
-- roles, the extensions schema, auth.uid()/auth.jwt(), the storage tables and helpers the policies use, a Vault stub,
-- the rls_auto_enable() function migration 07 revokes, and Supabase's default privileges in schema public. Used only
-- by migrations_test.ts against a throwaway in-memory database (PGlite). It is NOT a migration.

create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create role authenticator login noinherit;
create role supabase_storage_admin nologin;
grant anon, authenticated, service_role to authenticator;

create schema extensions;
create extension pgcrypto with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;

-- auth: only what policies or functions could call.
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;

-- storage: the columns and helpers the policies and migrations touch, owned by a non-postgres role as on the platform.
create schema storage authorization supabase_storage_admin;
grant usage on schema storage to anon, authenticated, service_role;
create table storage.buckets (
  id                 text primary key,
  name               text not null,
  owner              uuid,
  public             boolean default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);
create table storage.objects (
  id               uuid primary key default gen_random_uuid(),
  bucket_id        text references storage.buckets (id),
  name             text,
  owner            uuid,
  owner_id         text,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata         jsonb,
  version          text,
  user_metadata    jsonb,
  unique (bucket_id, name)
);
create index idx_objects_bucket_id_name on storage.objects (bucket_id, name collate "C");
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;
create function storage.foldername(name text) returns text[] language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end
$$;
alter table storage.objects owner to supabase_storage_admin;
alter table storage.buckets owner to supabase_storage_admin;

-- vault: create_secret + decrypted_secrets, without the encryption.
create schema vault;
create table vault.secrets (
  id          uuid primary key default gen_random_uuid(),
  name        text unique,
  description text,
  secret      text not null
);
create view vault.decrypted_secrets as select id, name, description, secret as decrypted_secret from vault.secrets;
create function vault.create_secret(new_secret text, new_name text default null, new_description text default '',
                                    new_key_id uuid default null) returns uuid language sql as
  $$ insert into vault.secrets (name, description, secret) values (new_name, new_description, new_secret) returning id $$;

-- Migration 07 revokes EXECUTE on this platform event-trigger function.
create function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin end $$;

-- Supabase's default privileges for objects postgres creates in public (what migrations 22 and 23 narrow).
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
