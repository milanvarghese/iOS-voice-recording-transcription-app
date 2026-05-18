-- Storage bucket + policies for audio files.
-- Run AFTER you've created a bucket named "recordings" in the Storage UI
-- (set it to PRIVATE — do not make it public).

-- Each user can only read/write objects whose path starts with their user id:
--   <user_id>/<recording_id>.m4a
-- This means a stolen URL from one user can't be used to fetch another user's audio.

create policy "recordings_storage_select_own"
  on storage.objects for select
  using (
    bucket_id = 'recordings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "recordings_storage_insert_own"
  on storage.objects for insert
  with check (
    bucket_id = 'recordings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "recordings_storage_update_own"
  on storage.objects for update
  using (
    bucket_id = 'recordings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "recordings_storage_delete_own"
  on storage.objects for delete
  using (
    bucket_id = 'recordings'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------------
-- pdf-templates bucket: per-user paths `<user_id>/<template_id>.pdf`
-- Same UUID-case caveat: iOS lowercases the user UUID before building the
-- path so this text comparison passes.
-- ---------------------------------------------------------------------------

create policy "templates_storage_select_own"
  on storage.objects for select
  using (
    bucket_id = 'pdf-templates'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "templates_storage_insert_own"
  on storage.objects for insert
  with check (
    bucket_id = 'pdf-templates'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "templates_storage_update_own"
  on storage.objects for update
  using (
    bucket_id = 'pdf-templates'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "templates_storage_delete_own"
  on storage.objects for delete
  using (
    bucket_id = 'pdf-templates'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
