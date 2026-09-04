-- 00009: Per-profile cloud sync scoping
--
-- watch_progress_sync / favorites_sync rows are now keyed by the CLOUD
-- profile identity (user_profiles.profile_id, which equals the local profile
-- id per user — see ProfileManager.syncToCloud / syncFromCloud) instead of
-- encoding the device-specific LOCAL profile id inside content_id. Cloud
-- content_id stores the RAW polymorphic id ("vod:42"), and profile_id 0
-- means "default / legacy row written before per-profile scoping existed".
--
-- user_profiles (00007) already carries every field of the local drift
-- UserProfiles table (display_name, avatar_color, is_active, created_at);
-- the local model has no additional avatar fields, so no change is needed
-- there.

-- ---------------------------------------------------------------------------
-- watch_progress_sync: add profile dimension and re-key
-- ---------------------------------------------------------------------------
alter table public.watch_progress_sync
  add column if not exists profile_id integer not null default 0;

-- The old primary key (user_id, content_id) is unique, so re-keying with
-- profile_id default 0 cannot create duplicates.
alter table public.watch_progress_sync
  drop constraint if exists watch_progress_sync_pkey;

alter table public.watch_progress_sync
  add constraint watch_progress_sync_pkey
  primary key (user_id, profile_id, content_id);

-- ---------------------------------------------------------------------------
-- favorites_sync: add profile dimension and re-key
-- ---------------------------------------------------------------------------
alter table public.favorites_sync
  add column if not exists profile_id integer not null default 0;

alter table public.favorites_sync
  drop constraint if exists favorites_sync_pkey;

alter table public.favorites_sync
  add constraint favorites_sync_pkey
  primary key (user_id, profile_id, content_id);

-- ---------------------------------------------------------------------------
-- playlists_sync: add profile dimension
-- ---------------------------------------------------------------------------
-- Playlists are not profile-scoped locally yet; every row is pushed with
-- profile_id 0. The unique constraint remains the existing primary key
-- (user_id, playlist_id). The column is added now so per-profile playlists
-- can be introduced without another migration.
alter table public.playlists_sync
  add column if not exists profile_id integer not null default 0;

-- ---------------------------------------------------------------------------
-- RLS policies (idempotent re-assert, mirroring 00005 / 00006): strictly
-- user-scoped — a user may only ever touch rows where user_id = auth.uid().
-- ---------------------------------------------------------------------------
alter table public.watch_progress_sync enable row level security;
drop policy if exists "watch_progress_owner_rw" on public.watch_progress_sync;
create policy "watch_progress_owner_rw" on public.watch_progress_sync
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

alter table public.favorites_sync enable row level security;
drop policy if exists "favorites_owner_rw" on public.favorites_sync;
create policy "favorites_owner_rw" on public.favorites_sync
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

alter table public.playlists_sync enable row level security;
drop policy if exists "playlists_sync_owner_rw" on public.playlists_sync;
create policy "playlists_sync_owner_rw" on public.playlists_sync
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
