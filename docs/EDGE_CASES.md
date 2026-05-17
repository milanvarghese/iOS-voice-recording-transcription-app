# Edge cases & how they're addressed

Mapping each concern Milan flagged to the specific mechanism in this codebase.

## Recording

| # | Concern | How it's handled | Where |
|---|---------|------------------|-------|
| 1 | Recording captures nothing | (a) Mic permission is checked before the recorder starts; (b) the live audio level meter gives the user visual proof that the mic is hot | `AudioRecorder.requestMicPermission`, `LevelMeter` in `RecordingView` |
| 2 | Recording lost after pause + close | `AVAudioRecorder` writes M4A to disk continuously. Pause keeps the file. App kill leaves the file on disk; `AudioRecorder.orphanedFiles()` finds it on next launch and you can re-enqueue it | `AudioRecorder` (note: hooking `orphanedFiles()` into app launch is a follow-up — see "future work" below) |
| 3 | Failed upload blocks new recordings | `UploadQueue` is independent of `AudioRecorder`. New recordings can always start. The queue persists to UserDefaults so it survives launches | `UploadQueue` |
| 4 | No way to delete a bad recording mid-session | Trash button on `RecordingView` calls `discardCurrentRecording()` which stops the recorder and deletes the on-disk file | `AudioRecorder.discardCurrentRecording`, `RecordingView.controls` |
| 5 | Recording in progress but timer at zero | The UI timer reads directly from `recorder.currentTime` — there's no separate counter that can drift. If the timer is 0, the recorder really isn't recording | `AudioRecorder.startMetering`, `RecordingView` |
| 6 | Two recording sessions cancel each other out | `AudioRecorder` is a `MainActor` singleton with an `isRecording` guard. A second `start()` throws `RecorderError.alreadyRecording` | `AudioRecorder.start` |
| 7 | Upload fails silently | Failed uploads update the row to `status = failed` with `error_message`. The History row shows a red "Failed" badge | `UploadQueue.processNext`, `RecordingRow.statusBadge` |
| 8 | Switching apps fails the recording (Maps, etc.) | (a) Info.plist has `UIBackgroundModes: audio` — iOS doesn't suspend us in the background; (b) we observe `AVAudioSession.interruptionNotification` and auto-resume when the interruption ends | `Info.plist`, `AudioRecorder.handleInterruption` |
| 9 | Upload issues for long files | `supabase-swift`'s storage upload uses TUS resumable upload for files >6MB. A dropped network resumes from the last completed byte rather than restarting. For a 1-hour M4A at 64kbps (~30MB) this matters a lot | `SupabaseService.uploadAudio` |
| 10 | History + naming | Default title is the timestamp; History view has a "Rename" swipe action; Delete swipe action removes both the row and the storage object | `HistoryView`, `HistoryViewModel.rename/delete`, default `title` in schema |

## Transcription

| # | Concern | How it's handled |
|---|---------|------------------|
| 1 | How to send an hour-long audio file | We don't stream to a synchronous API. We upload once to Supabase Storage, then submit an async job to AssemblyAI with a signed URL. AssemblyAI fetches the file itself and processes it server-side. No client-side chunking needed |
| 2 | How the app gets notified that transcription is complete | Two layers: (a) the `recordings` table is on the Realtime publication; `HistoryViewModel` subscribes, so the History row updates live while the app is open. (b) For "app is closed when transcript finishes" — add APNs push from the webhook (see future work below). For v1, the user will see the new transcript next time they open History |
| 3 | (open) — implied: speaker labels / formatting | AssemblyAI is invoked with `speaker_labels: true`, `punctuate: true`, `format_text: true`. The full structured JSON is stored in `transcript_json` for richer display later |

## Auth / scaling

- **OTP rate limits**: Supabase's default email sender is rate-limited and unsuitable for >50 users/day. For scaling, switch to custom SMTP (Resend / SendGrid / Postmark) in Auth settings. This is a config change, not a code change.
- **Race condition: same user, two devices** — RLS only restricts by `user_id`, so two devices for the same user both work. Recording rows include device-agnostic timestamps; History shows both devices' recordings in one feed.

## Future work (not in this MVP)

The following are deliberately deferred. Each has a clear "when you should add this" trigger.

1. **Orphan recovery on launch**: hook `AudioRecorder.orphanedFiles()` into `TranscriptionAPPMVPApp.init` and present a "Resume previous recording?" prompt. **Trigger:** if any user reports they ever lost a long recording.
2. **APNs push notifications**: register for remote notifications in `AppDelegate`, send the token to a `device_tokens` table, and have the AssemblyAI webhook POST to `https://api.push.apple.com` with the transcript-ready alert. **Trigger:** as soon as users start recording long enough that they close the app while it's processing.
3. **Live chunked upload during recording** (vs. upload-on-stop): split the M4A into N-minute segments and upload as each segment finalizes. **Trigger:** if hour-long uploads on flaky cell connections are biting users. The architecture already supports it — just split `AudioRecorder` to roll the file every N minutes, and enqueue each segment.
4. **AssemblyAI submission retry**: if the Edge Function call from the iOS app fails, the row stays in `uploaded` forever. Add a "Retry transcription" action in the History row. **Trigger:** first time you see a stuck-in-uploaded row.
5. **Background URLSession**: today, uploads stop if the user kills the app. A `URLSessionConfiguration.background(...)` upload session keeps going. **Trigger:** as soon as you ship and people background the app during big uploads.
