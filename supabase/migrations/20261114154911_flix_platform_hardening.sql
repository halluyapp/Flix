-- Flix Supabase platform schema and row-level security.
-- User data is cloud-backed by Supabase; the Flutter app should still keep a
-- local cache/outbox so startup and offline playback do not wait on the network.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 40),
  avatar_url text not null default '',
  is_kids boolean not null default false,
  maturity_rating text not null default 'TV-MA',
  pin_hash text,
  language text not null default 'en',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists maturity_rating text not null default 'TV-MA';
alter table public.profiles add column if not exists pin_hash text;
alter table public.profiles add column if not exists language text not null default 'en';
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

create index if not exists idx_profiles_user_id on public.profiles(user_id);

-- Serialize profile creation per account so concurrent requests cannot exceed
-- the five-profile cap.
create or replace function public.enforce_profile_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_count integer;
begin
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
    select count(*) into current_count from public.profiles where user_id = new.user_id;
    if current_count >= 5 then
      raise exception using errcode = '23514', message = 'A maximum of five profiles is allowed per account.';
    end if;
  elsif new.user_id is distinct from old.user_id then
    perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
    select count(*) into current_count from public.profiles where user_id = new.user_id;
    if current_count >= 5 then
      raise exception using errcode = '23514', message = 'A maximum of five profiles is allowed per account.';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_profile_limit() from public, anon, authenticated;
drop trigger if exists trg_check_profile_limit on public.profiles;
create trigger trg_check_profile_limit
before insert or update of user_id on public.profiles
for each row execute function public.enforce_profile_limit();

create or replace function public.handle_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
before update on public.profiles
for each row execute function public.handle_updated_at();

-- SECURITY DEFINER avoids recursive RLS evaluation when child tables check
-- whether the signed-in account owns a profile.
create or replace function public.owns_profile(candidate_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = candidate_profile_id and p.user_id = auth.uid()
  );
$$;

revoke all on function public.owns_profile(uuid) from public, anon;
grant execute on function public.owns_profile(uuid) to authenticated;

create table if not exists public.watch_progress (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  tmdb_id integer not null,
  media_type text not null check (media_type in ('movie', 'tv')),
  title text not null,
  poster_path text,
  backdrop_path text,
  season_number integer not null default 0 check (season_number >= 0),
  episode_number integer not null default 0 check (episode_number >= 0),
  episode_title text,
  position_seconds integer not null default 0 check (position_seconds >= 0),
  duration_seconds integer not null default 0 check (duration_seconds >= 0),
  completed boolean not null default false,
  last_watched_at timestamptz not null default now(),
  unique (profile_id, tmdb_id, media_type, season_number, episode_number)
);

create index if not exists idx_watch_progress_profile_recent
  on public.watch_progress(profile_id, last_watched_at desc);

create table if not exists public.watchlist (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  tmdb_id integer not null,
  media_type text not null check (media_type in ('movie', 'tv')),
  title text not null,
  poster_path text,
  backdrop_path text,
  vote_average numeric(3, 1),
  release_date text,
  overview text,
  added_at timestamptz not null default now(),
  unique (profile_id, tmdb_id, media_type)
);

create index if not exists idx_watchlist_profile_recent
  on public.watchlist(profile_id, added_at desc);

create table if not exists public.user_ratings (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  tmdb_id integer not null,
  media_type text not null check (media_type in ('movie', 'tv')),
  rating smallint not null check (rating in (-1, 1, 2)),
  updated_at timestamptz not null default now(),
  unique (profile_id, tmdb_id, media_type)
);

create table if not exists public.profile_settings (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  wifi_only boolean not null default true,
  smart_downloads boolean not null default false,
  download_quality text not null default 'standard'
    check (download_quality in ('standard', 'high')),
  updated_at timestamptz not null default now()
);

create table if not exists public.release_reminders (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  tmdb_id integer not null,
  media_type text not null check (media_type in ('movie', 'tv')),
  title text not null,
  release_date date,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  unique (profile_id, tmdb_id, media_type)
);

create table if not exists public.stream_cache (
  id uuid primary key default gen_random_uuid(),
  cache_key text not null unique,
  tmdb_id integer,
  subject_id text not null,
  detail_path text not null,
  title text not null,
  media_type text not null check (media_type in ('movie', 'tv')),
  season integer,
  episode integer,
  sources_json jsonb not null,
  captions_json jsonb not null default '[]'::jsonb,
  last_verified_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours')
);

alter table public.stream_cache add column if not exists tmdb_id integer;
alter table public.stream_cache add column if not exists detail_path text not null default '';
alter table public.stream_cache add column if not exists last_verified_at timestamptz not null default now();
create index if not exists idx_stream_cache_expiry on public.stream_cache(expires_at);

-- Enforce account ownership through the profile row for every profile-scoped
-- table. A client cannot attach its own user_id to another user's profile.
alter table public.profiles enable row level security;
alter table public.watch_progress enable row level security;
alter table public.watchlist enable row level security;
alter table public.user_ratings enable row level security;
alter table public.profile_settings enable row level security;
alter table public.release_reminders enable row level security;
alter table public.stream_cache enable row level security;

drop policy if exists "Users can view their own profiles" on public.profiles;
drop policy if exists "Users can create their own profiles" on public.profiles;
drop policy if exists "Users can update their own profiles" on public.profiles;
drop policy if exists "Users can delete their own profiles" on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using (user_id = auth.uid());
create policy profiles_insert_own on public.profiles for insert to authenticated with check (user_id = auth.uid());
create policy profiles_update_own on public.profiles for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy profiles_delete_own on public.profiles for delete to authenticated using (user_id = auth.uid());

-- Remove older, weaker policies if this migration is applied after the legacy schema.
drop policy if exists "Users can view their own watch progress" on public.watch_progress;
drop policy if exists "Users can insert their own watch progress" on public.watch_progress;
drop policy if exists "Users can update their own watch progress" on public.watch_progress;
drop policy if exists "Users can delete their own watch progress" on public.watch_progress;
create policy watch_progress_select_owned on public.watch_progress for select to authenticated
  using (user_id = auth.uid() and public.owns_profile(profile_id));
create policy watch_progress_insert_owned on public.watch_progress for insert to authenticated
  with check (user_id = auth.uid() and public.owns_profile(profile_id));
create policy watch_progress_update_owned on public.watch_progress for update to authenticated
  using (user_id = auth.uid() and public.owns_profile(profile_id))
  with check (user_id = auth.uid() and public.owns_profile(profile_id));
create policy watch_progress_delete_owned on public.watch_progress for delete to authenticated
  using (user_id = auth.uid() and public.owns_profile(profile_id));

drop policy if exists "Users can view their own watchlist" on public.watchlist;
drop policy if exists "Users can insert into their own watchlist" on public.watchlist;
drop policy if exists "Users can delete from their own watchlist" on public.watchlist;
create policy watchlist_select_owned on public.watchlist for select to authenticated
  using (user_id = auth.uid() and public.owns_profile(profile_id));
create policy watchlist_insert_owned on public.watchlist for insert to authenticated
  with check (user_id = auth.uid() and public.owns_profile(profile_id));
create policy watchlist_update_owned on public.watchlist for update to authenticated
  using (user_id = auth.uid() and public.owns_profile(profile_id))
  with check (user_id = auth.uid() and public.owns_profile(profile_id));
create policy watchlist_delete_owned on public.watchlist for delete to authenticated
  using (user_id = auth.uid() and public.owns_profile(profile_id));

create policy ratings_select_owned on public.user_ratings for select to authenticated
  using (public.owns_profile(profile_id));
create policy ratings_insert_owned on public.user_ratings for insert to authenticated
  with check (public.owns_profile(profile_id));
create policy ratings_update_owned on public.user_ratings for update to authenticated
  using (public.owns_profile(profile_id)) with check (public.owns_profile(profile_id));
create policy ratings_delete_owned on public.user_ratings for delete to authenticated
  using (public.owns_profile(profile_id));

create policy profile_settings_select_owned on public.profile_settings for select to authenticated
  using (public.owns_profile(profile_id));
create policy profile_settings_insert_owned on public.profile_settings for insert to authenticated
  with check (public.owns_profile(profile_id));
create policy profile_settings_update_owned on public.profile_settings for update to authenticated
  using (public.owns_profile(profile_id)) with check (public.owns_profile(profile_id));
create policy profile_settings_delete_owned on public.profile_settings for delete to authenticated
  using (public.owns_profile(profile_id));

create policy reminders_select_owned on public.release_reminders for select to authenticated
  using (public.owns_profile(profile_id));
create policy reminders_insert_owned on public.release_reminders for insert to authenticated
  with check (public.owns_profile(profile_id));
create policy reminders_update_owned on public.release_reminders for update to authenticated
  using (public.owns_profile(profile_id)) with check (public.owns_profile(profile_id));
create policy reminders_delete_owned on public.release_reminders for delete to authenticated
  using (public.owns_profile(profile_id));

-- Stream URLs are short-lived and sensitive. Only trusted Edge Functions using
-- the service role should read or write this table; there are no client policies.
drop policy if exists "Authenticated users can read stream cache" on public.stream_cache;
drop policy if exists "Authenticated users or functions can insert stream cache" on public.stream_cache;
drop policy if exists "Authenticated users or functions can update stream cache" on public.stream_cache;
revoke all on public.stream_cache from anon, authenticated;
grant select, insert, update, delete on public.stream_cache to service_role;

grant select, insert, update, delete on public.profiles, public.watch_progress,
  public.watchlist, public.user_ratings, public.profile_settings,
  public.release_reminders to authenticated;
revoke all on public.profiles, public.watch_progress, public.watchlist,
  public.user_ratings, public.profile_settings, public.release_reminders from anon;
