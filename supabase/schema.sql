-- TranscriptionAPPMVP — database schema
-- Run this in the Supabase SQL editor on a fresh project.
-- Users are stored in auth.users (managed by Supabase Auth). We only need a recordings table.

create type recording_status as enum (
  'draft',          -- created locally before any upload happened
  'uploading',      -- iOS app is uploading the M4A
  'uploaded',       -- file is in storage, not yet sent to AssemblyAI
  'transcribing',   -- AssemblyAI job in flight
  'done',           -- transcript saved on the row
  'failed'          -- error_message will be set
);

create table public.recordings (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  title             text not null default to_char(now(), 'YYYY-MM-DD HH24:MI'),
  duration_seconds  integer,
  status            recording_status not null default 'draft',
  storage_path      text,                  -- e.g. "<user_id>/<recording_id>.m4a"
  assemblyai_id     text,                  -- AssemblyAI job id, set when submitted
  transcript        text,                  -- full text, set on completion
  transcript_json   jsonb,                 -- structured transcript (words, timestamps)
  error_message     text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index recordings_user_id_created_at_idx
  on public.recordings (user_id, created_at desc);

create index recordings_assemblyai_id_idx
  on public.recordings (assemblyai_id)
  where assemblyai_id is not null;

-- keep updated_at fresh
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger recordings_set_updated_at
  before update on public.recordings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security: each user can only see/modify their own recordings.
-- This is the entire authorization model for the MVP.
-- ---------------------------------------------------------------------------
alter table public.recordings enable row level security;

create policy "recordings_select_own"
  on public.recordings for select
  using (auth.uid() = user_id);

create policy "recordings_insert_own"
  on public.recordings for insert
  with check (auth.uid() = user_id);

create policy "recordings_update_own"
  on public.recordings for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "recordings_delete_own"
  on public.recordings for delete
  using (auth.uid() = user_id);

-- The Edge Function uses the service_role key, which bypasses RLS, so the
-- webhook can write transcripts without impersonating the user.

-- ---------------------------------------------------------------------------
-- Realtime: let clients subscribe to row updates so the history view refreshes
-- when a transcript completes.
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.recordings;
