# Edge cases & how they're addressed

Mapping each concern Milan flagged to the specific mechanism in this codebase. Also tracks which "future work" items have shipped vs are still deferred.

## Recording

| # | Concern | How it's handled | Where |
|---|---------|------------------|-------|
| 1 | Recording captures nothing | (a) Mic permission is checked before the recorder starts; (b) the live audio level meter gives the user visual proof that the mic is hot | `AudioRecorder.requestMicPermission`, `LevelMeter` in `RecordingView` |
| 2 | Recording lost after pause + close (incl. iOS killing the app mid-call) | `AVAudioRecorder` writes M4A to disk continuously. `start()` persists an in-progress marker; `finishCleanup()` clears it. On next app launch `AudioRecorder.recoverOrphanedRecording()` checks for a stale marker + matching file and auto-enqueues for upload. UIKit background task during interruptions widens iOS's keep-alive window further. | `AudioRecorder.recoverOrphanedRecording`, `AppDelegate.didFinishLaunchingWithOptions` |
| 3 | Failed upload blocks new recordings | `UploadQueue` is independent of `AudioRecorder`. New recordings can always start. The queue persists to UserDefaults so it survives launches. **Failed items now pop from the queue** instead of looping forever, so a stuck failure can't strand later recordings | `UploadQueue.processNext` |
| 4 | No way to delete a bad recording mid-session | Trash button on `RecordingView` calls `discardCurrentRecording()` which stops the recorder and deletes the on-disk file | `AudioRecorder.discardCurrentRecording`, `RecordingView.controls` |
| 5 | Recording in progress but timer at zero | The UI timer reads directly from `recorder.currentTime` — there's no separate counter that can drift. If the timer is 0, the recorder really isn't recording | `AudioRecorder.startMetering`, `RecordingView` |
| 6 | Two recording sessions cancel each other out | `AudioRecorder` is a `MainActor` singleton with an `isRecording` guard. A second `start()` throws `RecorderError.alreadyRecording` | `AudioRecorder.start` |
| 7 | Upload fails silently | Failed uploads update the row to `status = failed` with `error_message`. History shows a red "Failed" badge. The detail view exposes a **Retry transcription** button (when the audio reached Storage) | `UploadQueue.processNext`, `TranscriptDetailView.failedView` |
| 8 | Switching apps fails the recording (Maps, etc.) | (a) Info.plist has `UIBackgroundModes: audio` — iOS doesn't suspend us in the background; (b) we observe `AVAudioSession.interruptionNotification` and auto-resume when the interruption ends | `Info.plist`, `AudioRecorder.handleInterruption` |
| 9 | Upload issues for long files | `supabase-swift`'s storage upload uses TUS resumable upload for files >6MB. A dropped network resumes from the last completed byte rather than restarting | `SupabaseService.uploadAudio` |
| 10 | History + naming + deletion | Default title is the timestamp. Swipe actions: **Rename**, **Remove from Phone** (clears local cache, cloud preserved), **Delete** (with confirmation; removes cloud + DB + local). Cloud is the source of truth | `HistoryView`, `HistoryViewModel.removeFromPhone/deleteForever/rename` |
| 11 | Audio playback after transcription | `TranscriptDetailView` has play/pause/scrubber. Plays from the local M4A when present; falls back to a 1-hour Supabase signed URL otherwise. Local file stays on the phone after upload until the user removes it | `AudioPlayerViewModel`, `TranscriptDetailView`, `SupabaseService.signedAudioURL` |

## Transcription

| # | Concern | How it's handled |
|---|---------|------------------|
| 1 | How to send an hour-long audio file | We don't stream to a synchronous API. We upload once to Supabase Storage, then submit an async job to AssemblyAI with a signed URL. AssemblyAI fetches the file itself and processes it server-side. No client-side chunking needed |
| 2 | How the app gets notified that transcription is complete | The `recordings` table is on the Realtime publication; `HistoryViewModel.startListening` subscribes (`subscribeWithError`) so the History row and detail view update live. For "app is closed when transcript finishes" — APNs push from the webhook is still deferred (see "Future work"). For v1, the user sees the new transcript next time they open History |
| 3 | Speaker labels / formatting | AssemblyAI is invoked with `speech_models: ["universal-2"]`, `speaker_labels: true`, `punctuate: true`, `format_text: true`. The full structured JSON is stored in `transcript_json` for richer display later (not rendered in the iOS UI yet — only the plain text is) |
| 4 | AssemblyAI rejecting submissions | Edge Function specifies `speech_models` (a 2025 AssemblyAI API requirement). Without it, every submission 400s. If a submit fails for any other reason, the row is marked `failed` with the AssemblyAI body text; user gets a Retry button |
| 5 | Webhook security | `assemblyai_webhook` is deployed with `--no-verify-jwt` (AssemblyAI doesn't have a Supabase JWT to send). Authentication is via the `x-webhook-secret` header which AssemblyAI echoes back to us; we compare against `WEBHOOK_SECRET` |
| 6 | RLS mismatch between table and Storage | `recordings` table RLS compares UUIDs (normalized to lowercase by Postgres). Storage RLS compares the first folder of `name` to `auth.uid()::text` (also lowercase). iOS builds storage paths with `userId.uuidString.lowercased()` so the string comparison passes |

## Long-form audio and transcripts

This is the dimension the app was designed for — recordings minutes to hours long, transcripts that get correspondingly large. A few places where length matters and what protects them today:

| Concern | What protects us | Where |
|---------|------------------|-------|
| 3-hour M4A loaded into RAM at upload time | `Data(contentsOf:, options: [.mappedIfSafe])` memory-maps the file. The kernel pages bytes in as the upload reads them; the iOS process never holds the full file in heap | `SupabaseService.uploadAudio` |
| Multi-hour transcript exceeds Claude's context | Claude Sonnet 4.6 has a ~200k-token context window. A 3-hour transcript is ~25k tokens — well inside the window. Chunking only becomes necessary past ~10 hours of speech | `extract_fields/index.ts` |
| Long extracted JSON gets truncated by `max_tokens` | We use `max_tokens: 4096`, which fits a thorough meeting (30+ action items, attendees, decisions, etc.) without truncation. Bump if you start seeing cut-off JSON | `extract_fields/index.ts` |
| AssemblyAI signed URL expires before transcription | Signed URLs are issued for 24 hours. AssemblyAI typically processes within ~30% of audio duration; even an 8-hour file is comfortably within the window | `submit_for_transcription/index.ts` |
| Upload retry on flaky network mid-multi-GB file | supabase-swift's storage upload uses TUS resumable upload for files >6MB. Network drop resumes from the last completed byte rather than restarting | `SupabaseService.uploadAudio` |
| Playback of a 3-hour M4A on the phone | `AVAudioPlayer` decodes on demand; nothing is held in memory beyond a buffer. The scrubber is bound to `currentTime` so seek is constant-time | `AudioPlayerViewModel` |
| Realtime row update size | We don't push the audio over Realtime — only the row metadata (transcript text included). For a 3-hour transcript (~150 KB text) Realtime handles it fine; the only large field that does not get pushed is the underlying `transcript_json` which stays in the DB | Supabase Realtime publication on `recordings` |

If you do start handling extremely long content (10+ hours), the next moves would be: chunk the transcript before sending to Claude (split on speaker boundaries, summarize per chunk, then merge), and switch the iOS upload to a background `URLSession` so the OS can keep it running past the foreground time limit. Both are noted in the deferred list below.

## Auth / scaling

- **OTP rate limits**: Supabase's default email sender is rate-limited and unsuitable for >50 users/day. For scaling, switch to custom SMTP (Resend / SendGrid / Postmark) in Auth settings. This is a config change, not a code change.
- **OTP email template**: Supabase's default "Magic Link" template ships with a link only, no code. We override it to include `{{ .Token }}` (the 6-digit code) prominently. Set via Management API at project setup; see `docs/SETUP.md`.
- **`mailer_autoconfirm`**: turned on at the project level so new users can sign in via OTP immediately without a separate confirmation step.
- **Race condition: same user, two devices** — RLS only restricts by `user_id`, so two devices for the same user both work. Recording rows include device-agnostic timestamps; History shows both devices' recordings in one feed.

## Future work (not in this MVP)

### Shipped

- ✅ **AssemblyAI submission retry** — `TranscriptDetailView` shows a "Retry transcription" button on `.failed` rows when `storage_path` is set. Resets status and re-invokes the Edge Function.
- ✅ **Local audio retained after upload** — the local M4A stays on disk; "Remove from Phone" is a separate action from "Delete forever". Audio player falls back to cloud signed URL when local is missing.
- ✅ **Queue self-healing** — `UploadQueue` pops failed items instead of retrying forever. A poisoned pending recording can no longer block the queue.
- ✅ **Claude-powered structured field extraction** — `extract_fields` Edge Function (Sonnet 4.6) chains from the AssemblyAI webhook, returns a content-adaptive JSON object. Stored in `recordings.extracted_fields`, rendered as a syntax-highlighted dark code block in the detail view. Manual re-extract button included.
- ✅ **Memory-mapped audio upload** — `Data(contentsOf:, options: [.mappedIfSafe])` so a multi-hour M4A doesn't get fully loaded into the iOS process's heap.
- ✅ **Pause / resume during recording** — labeled buttons + RECORDING / PAUSED status pill above the timer. Capability was always in `AudioRecorder.pause/resume`; just made discoverable.
- ✅ **Login UI** — dark theme with locked colors, explicit foreground/background so the screen can't render unreadable under any system color scheme.
- ✅ **Encryption-compliance auto-pass** — `Info.plist` declares `ITSAppUsesNonExemptEncryption = false`. App Store Connect no longer prompts after every TestFlight upload.
- ✅ **Orphan recovery on launch with Continue/Save/Discard** — `AudioRecorder.start()` writes an in-progress marker to UserDefaults; `finishCleanup()` clears it. On app launch, `AudioRecorder.checkForOrphan()` notices a stale marker + matching M4A on disk and surfaces it as `pendingOrphan`. The Recording tab shows a card with three actions:
  - **Continue** → `AudioRecorder.resumeOrphan()` opens an `AVAudioRecorder` pointing at the same M4A; `record()` appends from the existing end-of-file. One seamless recording across the interruption.
  - **Save** → `saveOrphanWithoutResume()` enqueues for upload as-is (the older auto-recovery behavior).
  - **Discard** → `discardOrphan()` deletes the file and the marker. Confirmation dialog so it's never accidental.
  Combined with the UIKit background task during interruptions, this fully covers the "phone call killed the app" failure mode: the file survives the kill, and on next launch the user picks whether to continue, save, or scrap it.

### Still deferred

Each has a clear "when you should add this" trigger.

1. **APNs push notifications**: register for remote notifications, store device tokens, have the AssemblyAI webhook POST to `https://api.push.apple.com` with a "transcript ready" alert. **Trigger:** as soon as users start recording long enough that they close the app while it's processing.
2. **Live chunked upload during recording** (vs. upload-on-stop): split the M4A into N-minute segments and upload as each segment finalizes. **Trigger:** if hour-long uploads on flaky cell connections are biting users. Architecture already supports it.
3. **Background `URLSession` uploads**: today, uploads stop if the user kills the app. A `URLSessionConfiguration.background(...)` upload session keeps going. **Trigger:** as soon as you ship to non-test users who background the app during big uploads.
4. **Speaker-by-speaker transcript rendering**: AssemblyAI returns `utterances[]` with speaker labels in `transcript_json`; the iOS app currently only renders `transcript` (plain text). **Trigger:** when speaker attribution becomes a feature ask.
5. **Real Keychain storage for auth tokens**: `SupabaseAuthKeychainStorage` is currently backed by `UserDefaults` (the name is aspirational). Replace with `Security.framework` Keychain APIs. **Trigger:** before any user data sensitivity becomes a concern.
6. **Authorization check in `submit_for_transcription`**: the Edge Function uses the service role to look up the recording but doesn't enforce that the JWT caller owns it. A signed-in user could theoretically trigger transcription for another user's recording (they wouldn't see the result thanks to RLS, but they'd burn AssemblyAI credits). Add `.eq("user_id", callerId)` after decoding the JWT. **Trigger:** before multi-user public release.
7. **Unit tests**: no test target exists yet. Highest-value targets: `UploadQueue` state machine, `AudioRecorder` start/pause/resume/discard transitions, `HistoryViewModel` fetch/delete/retry, Deno tests for the Edge Functions. **Trigger:** before a second engineer joins the codebase.
8. **Automated TestFlight delivery via Xcode Cloud**: currently the archive comes out of Xcode Cloud but we manually upload via Transporter (see `docs/CICD.md`). Fixing requires either provisioning Ad Hoc + Development certificates so all three exports succeed, or finding a way to disable the unwanted ones.
