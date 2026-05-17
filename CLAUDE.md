# TranscriptionAPPMVP — Claude project notes

iOS app that records long-form audio (minutes to hours), uploads it to Supabase Storage, transcribes it with AssemblyAI, and shows each user their own history. Demo target is TestFlight share with one friend; design ceiling is ~1M users.

## Stack

- **iOS**: Swift 5.9 + SwiftUI, iOS 17+. No Objective-C, no UIKit unless wrapping an unavoidable API.
- **Backend**: Supabase (Postgres + Auth + Storage + Edge Functions). No custom servers.
- **Transcription**: AssemblyAI async API + webhook. Never a synchronous Whisper-style call.
- **Auth**: Email OTP only.
- **Cross-platform**: NOT supported. iOS only for now. Reject Flutter/RN suggestions unless a concrete Android user appears.

## Architecture (load-bearing — do not violate)

The app has three independent subsystems:

1. **`AudioRecorder`** (singleton, `MainActor`) — owns `AVAudioRecorder`, writes M4A to disk continuously, never holds audio in RAM. The UI timer reads `recorder.currentTime` directly; never use a parallel `Timer` counter.
2. **`UploadQueue`** (singleton) — persistent FIFO that runs independently of the recorder. A stuck upload must never block a new recording.
3. **Transcription pipeline** — kicked off by the `submit_for_transcription` Edge Function after upload. AssemblyAI calls `assemblyai_webhook` on completion. The iOS app learns about completion via Supabase Realtime subscription on `public.recordings`.

These three subsystems are deliberately decoupled. When adding features, keep them that way.

## Project layout

```
ios/TranscriptionAPPMVP/      ← drop into a new Xcode project
  Config.swift                ← Supabase URL + anon key
  Models/Recording.swift
  Services/                   ← SupabaseService, AudioRecorder, UploadQueue
  ViewModels/                 ← AuthViewModel, RecorderViewModel, HistoryViewModel
  Views/                      ← RootView, AuthView, RecordingView, HistoryView, TranscriptDetailView
supabase/
  schema.sql                  ← run in Supabase SQL editor
  storage_policies.sql        ← run AFTER creating the `recordings` bucket
  functions/
    submit_for_transcription/ ← invoked from iOS app
    assemblyai_webhook/       ← invoked by AssemblyAI
docs/
  SETUP.md, TESTFLIGHT.md, EDGE_CASES.md
```

## Where to make common changes

- **Recording behavior** (pause/resume/discard, interruption handling, audio format) → `Services/AudioRecorder.swift`.
- **Upload retry, queue persistence, status transitions** → `Services/UploadQueue.swift`.
- **DB schema changes** → `supabase/schema.sql` + write a migration; never edit the table in the Supabase UI without backporting to this file.
- **What we send to AssemblyAI** (speaker labels, language, etc.) → `supabase/functions/submit_for_transcription/index.ts`.
- **What we store from the transcript** → `supabase/functions/assemblyai_webhook/index.ts`.
- **History rendering, rename, delete** → `Views/HistoryView.swift` + `ViewModels/HistoryViewModel.swift`.

## Hard rules (do not break)

1. **NEVER** put the Supabase `service_role` key in iOS. Anon key only. Service role lives in Edge Function secrets.
2. **NEVER** use a parallel timer in the recording UI. Read `AVAudioRecorder.currentTime`.
3. **NEVER** couple uploads to recording. A failed upload must not block `start()`.
4. **NEVER** bypass Row Level Security by querying with the service role from the client.
5. **NEVER** stream audio to a synchronous transcription endpoint. Use AssemblyAI's async + webhook flow.
6. Storage paths are always `<user_id>/<recording_id>.m4a`. The storage RLS policy enforces this.

## Build / deploy

```bash
# Edge Functions (after `supabase login` + `supabase link`)
supabase functions deploy assemblyai_webhook --no-verify-jwt
supabase functions deploy submit_for_transcription

# Secrets required
supabase secrets set ASSEMBLYAI_API_KEY=...
supabase secrets set WEBHOOK_SECRET=$(openssl rand -hex 32)
supabase secrets set WEBHOOK_URL=https://<project-ref>.supabase.co/functions/v1/assemblyai_webhook

# iOS: Xcode → Product → Archive → Distribute App → App Store Connect → Upload
# Always bump build number (target → General → Identity → Build) before archiving.
```

## Style preferences

- Concrete recommendations with one-sentence rationale, not menus of options.
- Surface edge cases proactively (Milan's flagged 13 of them in the initial spec — see `docs/EDGE_CASES.md`).
- When proposing a new library or service, briefly note the scaling story up to 1M users.
- Swift: `@MainActor` on view models and UI-touching services. `Sendable` matters; avoid `Task { ... }` capturing non-Sendable things.
- TypeScript Edge Functions: Deno, plain `fetch`, no frameworks.

## Open / deferred work (not bugs)

See `docs/EDGE_CASES.md` "Future work" section for the deferred list with triggers (orphan-file recovery on launch, APNs push, live chunked upload, retry button for stuck transcriptions, background URLSession). None block the MVP demo.
