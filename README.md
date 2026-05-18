# TranscriptionAPPMVP

An iOS app that records long-form audio (minutes to hours), uploads it to cloud storage, transcribes it asynchronously with AssemblyAI, and shows each user their own history of recordings + transcripts.

**Stack**
- iOS-native: Swift 5.9 + SwiftUI, iOS 17+
- Backend: Supabase (Postgres + Auth + Storage + Edge Functions)
- Transcription: AssemblyAI (async API with webhooks, `universal-2` model)
- Structured field extraction: Anthropic Claude (Sonnet 4.6) via an Edge Function — content-adaptive JSON schema
- Auth: Email OTP (6-digit code)
- CI/CD: Xcode Cloud (builds the archive); TestFlight upload via Apple Transporter
- Push notifications: planned, not built (see `docs/EDGE_CASES.md`)

---

## Status — what's shipping today

End-to-end pipeline is working in TestFlight. You can sign in, record, upload, transcribe, play back, retry, and delete.

| Feature | State |
|---|---|
| Email OTP sign-in (6-digit code) | ✅ Working |
| Record long-form audio (minutes to hours) | ✅ Working |
| Live audio level meter + bound-to-disk timer | ✅ Working |
| Background recording (calls / app switch) | ✅ Working — `UIBackgroundModes: audio` + interruption handler |
| Upload to Supabase Storage with per-user RLS | ✅ Working — UUIDs lowercased to match Postgres' `auth.uid()::text` |
| Async transcription via AssemblyAI | ✅ Working — `universal-2` speech model |
| Live History updates via Supabase Realtime | ✅ Working |
| Transcript viewing | ✅ Working — text is selectable |
| **Claude-powered structured field extraction** | ✅ Working — content-adaptive JSON, auto-runs after transcription |
| **Dark code-block UI for extracted fields** | ✅ Working — syntax-highlighted JSON, selectable text |
| **Manual re-extract button** | ✅ Working — tap the wand/refresh icon in detail view |
| Audio playback (play / pause / scrubber) | ✅ Working — local file when present, signed URL fallback |
| **Pause / resume during recording** | ✅ Working — labeled buttons + RECORDING / PAUSED status pill |
| Retry transcription on `failed` rows | ✅ Working |
| "Remove from Phone" vs "Delete forever" | ✅ Working — local cache vs full cloud delete |
| Rename a recording | ✅ Working |
| **Polished dark-theme login UI** | ✅ Working — locked colors, focus rings, gradient action button |
| **Developer credit + version in Settings** | ✅ Working — About section + login footer |
| **Memory-mapped audio upload** | ✅ Working — multi-hour M4As no longer load into RAM |
| **Encryption-compliance auto-pass** | ✅ Working — `ITSAppUsesNonExemptEncryption=false` in Info.plist |
| Xcode Cloud build automation | ✅ Working (with one quirk — see `docs/CICD.md`) |
| TestFlight delivery | ⚠️ Manual via Transporter — see `docs/TESTFLIGHT.md` |
| APNs push when a transcript completes | ⏭ Deferred — see `docs/EDGE_CASES.md` |
| Orphan-recording recovery on app launch | ⏭ Deferred |
| Background `URLSession` uploads | ⏭ Deferred |
| Live chunked upload during recording | ⏭ Deferred |
| Unit tests | ⏭ Deferred — wiring is in place, no test target yet |

---

## Architecture (end-to-end flow)

```
[ iPhone ]                  [ Supabase ]            [ AssemblyAI ]      [ Anthropic ]
   |                              |                       |                    |
   | 1. Email OTP sign-in         |                       |                    |
   |----------------------------->|                       |                    |
   |<--- session JWT -------------|                       |                    |
   |                              |                       |                    |
   | 2. Record. M4A streams to    |                       |                    |
   |    disk; UI timer bound to   |                       |                    |
   |    recorder.currentTime.     |                       |                    |
   |    Pause / resume keeps the  |                       |                    |
   |    same file open.           |                       |                    |
   |                              |                       |                    |
   | 3. Stop. UploadQueue inserts |                       |                    |
   |    recordings row + uploads  |                       |                    |
   |    M4A (mmap'd, resumable).  |                       |                    |
   |----------------------------->|                       |                    |
   |                              |                       |                    |
   | 4. Invoke submit_for_        |                       |                    |
   |    transcription Edge Fn.    |                       |                    |
   |----------------------------->|                       |                    |
   |                              | 5. Signs URL,         |                    |
   |                              |    POSTs to           |                    |
   |                              |    AssemblyAI         |                    |
   |                              |    (universal-2).     |                    |
   |                              |---------------------->|                    |
   |                              |<--- job_id -----------|                    |
   |                              |                       |                    |
   |                              |       6. AssemblyAI processes              |
   |                              |          (~30% of audio duration).         |
   |                              |                       |                    |
   |                              |<--- webhook ----------|                    |
   |                              | 7a. assemblyai_webhook                     |
   |                              |     writes transcript, status=done         |
   |                              |                       |                    |
   |                              | 7b. Chains to                              |
   |                              |     extract_fields, which calls            |
   |                              |     Claude Sonnet 4.6 ----------------->   |
   |                              |<--- structured JSON ------------------     |
   |                              | 7c. Writes extracted_fields to row         |
   |                              |                       |                    |
   |<--- realtime row update -----|                       |                    |
   |                              |                       |                    |
   | 8. History row flips to      |                       |                    |
   |    Ready. Detail view shows  |                       |                    |
   |    audio player + transcript |                       |                    |
   |    + dark code block with    |                       |                    |
   |    extracted_fields JSON.    |                       |                    |                                 |
```

### Design invariants (don't violate)

- **Phone never holds audio in memory.** Every sample lands in the M4A file as it's captured. If the OS kills the app, the partial file survives on disk.
- **UI timer reads `AVAudioRecorder.currentTime` directly.** No separate counter. If the timer is moving, audio is being written.
- **Upload runs independently of the recorder.** A stuck upload never blocks `start()`.
- **Cloud is the source of truth.** The local M4A is a cache. "Remove from Phone" clears the cache; the cloud row stays. "Delete" wraps both in a confirmation dialog.
- **No `service_role` key in iOS.** Anon key only. The service-role key only lives in Supabase Edge Function secrets.
- **Storage RLS lives in two places that must agree.** The DB policy checks `auth.uid() = user_id`. The Storage policy checks the first folder of the path matches `auth.uid()::text` — which is *lowercase* on Postgres' side. Swift's `UUID.uuidString` is uppercase by default, so the iOS code lowercases the user UUID before building the storage path. Don't undo that.

---

## Project layout

```
TranscriptionAPPMVP/
├── README.md                              ← you are here
├── CLAUDE.md                              ← agent instructions, hard rules
├── LICENSE                                ← MIT
├── .gitignore                             ← Config.swift, .DS_Store, build artifacts
├── TranscriptionAPPMVP/                   ← Xcode project lives here
│   ├── TranscriptionAPPMVP.xcodeproj
│   ├── ci_scripts/                        ← Xcode Cloud hooks
│   │   ├── ci_post_clone.sh               ← writes Config.swift from env vars
│   │   ├── ci_pre_xcodebuild.sh
│   │   └── ci_post_xcodebuild.sh
│   └── TranscriptionAPPMVP/               ← Swift source
│       ├── TranscriptionAPPMVPApp.swift
│       ├── Config.swift.example           ← committed template
│       ├── Config.swift                   ← real keys, gitignored
│       ├── Assets.xcassets/               ← app icon (placeholder PNG)
│       ├── Info.plist                     ← reference; modern Xcode uses build settings
│       ├── Models/
│       │   └── Recording.swift
│       ├── Services/
│       │   ├── AudioRecorder.swift        ← singleton, MainActor, owns AVAudioRecorder
│       │   ├── SupabaseService.swift      ← all Supabase calls live here
│       │   └── UploadQueue.swift          ← persistent FIFO, runs independently
│       ├── ViewModels/
│       │   ├── AuthViewModel.swift
│       │   ├── RecorderViewModel.swift
│       │   └── HistoryViewModel.swift
│       └── Views/
│           ├── RootView.swift
│           ├── AuthView.swift
│           ├── RecordingView.swift
│           ├── HistoryView.swift          ← swipe: Rename / Remove from Phone / Delete
│           └── TranscriptDetailView.swift ← audio player + transcript + retry button
├── supabase/
│   ├── schema.sql                         ← run once in Supabase SQL editor
│   ├── storage_policies.sql               ← run after creating `recordings` bucket
│   └── functions/
│       ├── submit_for_transcription/index.ts   ← iOS → AssemblyAI (with universal-2)
│       └── assemblyai_webhook/index.ts         ← AssemblyAI → DB
└── docs/
    ├── SETUP.md          ← from-zero: Supabase + AssemblyAI + Xcode + first run
    ├── TESTFLIGHT.md     ← Xcode Cloud build + manual Transporter upload
    ├── CICD.md           ← Xcode Cloud workflow, the export-distribution quirk
    └── EDGE_CASES.md     ← which user concerns each piece of code addresses
```

---

## Quick start

Full step-by-step is in `docs/SETUP.md` — the short version:

1. **Supabase**: create a project. Run `supabase/schema.sql` then `supabase/storage_policies.sql` in the SQL editor. Create a private bucket named `recordings`. Disable "Confirm email" in Auth → Sign In / Providers → Email so OTP works without a verification round-trip. Update the **Magic Link** email template to include `{{ .Token }}` (otherwise the email has no OTP code).
2. **AssemblyAI**: sign up, copy your API key.
3. **Anthropic**: sign up at [console.anthropic.com](https://console.anthropic.com), generate an API key — used by the `extract_fields` Edge Function to pull structured info from transcripts.
4. **Edge Functions**: `supabase login && supabase link --project-ref <your-ref>`, set secrets (`ASSEMBLYAI_API_KEY`, `ANTHROPIC_API_KEY`, `WEBHOOK_SECRET`, `WEBHOOK_URL`), deploy all three functions (`assemblyai_webhook`, `submit_for_transcription`, `extract_fields`).
5. **iOS app**: open `TranscriptionAPPMVP/TranscriptionAPPMVP.xcodeproj`. Copy `Config.swift.example` to `Config.swift` and fill in your Supabase URL + anon key. Add the supabase-swift package if not already resolved. Add Background Modes (Audio) capability + `Privacy - Microphone Usage Description` to the target Info.
6. **Run on simulator or device** → sign in with your email → record → check History.
7. **TestFlight**: see `docs/TESTFLIGHT.md`.

---

## Cost estimates (for 50 users)

Assuming each user records 1 hour per week:

- AssemblyAI: 50 users × 4 hr/mo × current pricing ≈ **$30–75/mo** depending on `universal-2` vs `universal-3-pro`.
- Supabase Free tier covers Auth, 500MB DB, 1GB storage, 2GB bandwidth — enough to start. Pro tier ($25/mo) is the first upgrade you'll need when you cross 1GB storage (roughly 30 hours of recordings at 64 kbps mono AAC).
- Xcode Cloud Free: 25 compute hours/mo (≈75–150 builds for this app).

For 1M users you'd switch to Supabase Team/Enterprise, move heavy storage to S3 with lifecycle policies, and negotiate AssemblyAI volume pricing — but the application code stays the same.

---

## CI / CD

Xcode Cloud builds the archive automatically on every push to `main`. The actual TestFlight upload is currently done manually via the **Apple Transporter** app — there's a quirk with Xcode Cloud's default workflow that tries to export the archive for ad-hoc *and* development distribution alongside the App Store export. Without dedicated certificates for those, both fail and Xcode Cloud marks the whole build "failed" even though the App Store `.ipa` was produced correctly. We download that `.ipa` from the build's Artifacts and send it through Transporter manually. **`docs/CICD.md`** explains the issue and how to fix it properly when you want fully automated delivery.

`ci_scripts/ci_post_clone.sh` materializes `Config.swift` at build time from `SUPABASE_URL` and `SUPABASE_ANON_KEY` env vars set in App Store Connect → Xcode Cloud → Settings → Environment. Real keys never touch git.
