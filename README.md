# TranscriptionAPPMVP

An iOS app that records long-form audio (minutes to hours), uploads it to cloud storage, transcribes it asynchronously, and shows each user their own history of recordings + transcripts.

**Stack**
- iOS-native: Swift 5.9 + SwiftUI, iOS 17+
- Backend: Supabase (Postgres + Auth + Storage + Edge Functions)
- Transcription: AssemblyAI (async API with webhooks)
- Auth: Email OTP (6-digit code)
- Push notifications: APNs via Supabase Edge Function (optional for v1)

---

## Architecture (end-to-end flow)

```
[ iPhone ]                              [ Supabase ]                    [ AssemblyAI ]
   |                                         |                                 |
   | 1. Sign in (email + OTP)                |                                 |
   |---------------------------------------->|                                 |
   |<--- session JWT ----------------------- |                                 |
   |                                         |                                 |
   | 2. Tap Record. AVAudioRecorder writes   |                                 |
   |    M4A to local disk continuously,      |                                 |
   |    in 30-second segments. Timer is      |                                 |
   |    bound to recorder.currentTime.       |                                 |
   |                                         |                                 |
   | 3. Tap Stop. Insert row into            |                                 |
   |    `recordings` (status=uploading).     |                                 |
   |    Upload finalized M4A to Storage      |                                 |
   |    via tus-resumable protocol.          |                                 |
   |---------------------------------------->|                                 |
   |                                         |                                 |
   | 4. Upload completes. App calls          |                                 |
   |    Edge Function `submit_for_transcription` |                              |
   |    with the recording_id.               |                                 |
   |---------------------------------------->|                                 |
   |                                         | 5. Edge Function generates      |
   |                                         |    signed URL for the file,     |
   |                                         |    POSTs job to AssemblyAI      |
   |                                         |    with webhook URL.            |
   |                                         |-------------------------------->|
   |                                         |<--- job id ------------------- |
   |                                         | Sets status=transcribing,       |
   |                                         | stores assemblyai_id.           |
   |                                         |                                 |
   |                                         |          6. AssemblyAI does     |
   |                                         |             its work (~30%      |
   |                                         |             of audio duration). |
   |                                         |                                 |
   |                                         |<--- webhook: transcript ready --|
   |                                         | 7. Webhook handler writes       |
   |                                         |    transcript to row,           |
   |                                         |    status=done,                 |
   |                                         |    sends APNs push (or          |
   |                                         |    relies on realtime sub).     |
   |<--- realtime row update ----------------|                                 |
   |                                         |                                 |
   | 8. History view updates live.           |                                 |
```

### Why this shape

The phone never holds audio in memory — every audio sample lands on disk inside `AVAudioRecorder` as it's captured. If the OS kills the app, the partial M4A is still on disk and can be uploaded next launch. **This is what makes "lose recording on close" not happen.**

The upload runs as a background-eligible `URLSession` task using tus (resumable). If the network drops mid-upload, the next attempt resumes from the last completed byte instead of restarting. For a 1-hour M4A (~30MB at 64 kbps AAC), this matters.

Transcription is handed off to AssemblyAI's async endpoint. We do not stream audio to a synchronous Whisper-style API — that would limit us to short files and tie up our backend. AssemblyAI calls our webhook when done, our webhook updates the DB row, and the iOS app sees the update via Supabase Realtime (or a push if the app is backgrounded).

---

## Project layout

```
TranscriptionAPPMVP/
├── README.md                          ← you are here
├── ios/                               ← drop these into a new Xcode project
│   ├── TranscriptionAPPMVP/
│   │   ├── TranscriptionAPPMVPApp.swift
│   │   ├── Info.plist                 ← mic + background audio permissions
│   │   ├── Config.swift.example       ← template (committed)
│   │   ├── Config.swift               ← Supabase URL + anon key (gitignored; copy from .example)
│   │   ├── Models/
│   │   │   └── Recording.swift
│   │   ├── Services/
│   │   │   ├── SupabaseService.swift
│   │   │   ├── AudioRecorder.swift
│   │   │   ├── UploadQueue.swift
│   │   │   └── TranscriptionService.swift
│   │   ├── Views/
│   │   │   ├── RootView.swift
│   │   │   ├── AuthView.swift
│   │   │   ├── RecordingView.swift
│   │   │   ├── HistoryView.swift
│   │   │   └── TranscriptDetailView.swift
│   │   └── ViewModels/
│   │       ├── AuthViewModel.swift
│   │       ├── RecorderViewModel.swift
│   │       └── HistoryViewModel.swift
├── supabase/
│   ├── schema.sql                     ← run this in the SQL editor
│   ├── storage_policies.sql           ← bucket + RLS for storage
│   └── functions/
│       ├── submit_for_transcription/
│       │   └── index.ts
│       └── assemblyai_webhook/
│           └── index.ts
└── docs/
    ├── SETUP.md                       ← Supabase + AssemblyAI + Xcode setup
    ├── TESTFLIGHT.md                  ← shipping to your friend
    └── EDGE_CASES.md                  ← how each failure mode is handled
```

---

## Quick start

1. **Supabase**: see `docs/SETUP.md` step 1. Create project, run `supabase/schema.sql` and `supabase/storage_policies.sql` in the SQL editor, create the `recordings` storage bucket.
2. **AssemblyAI**: sign up at assemblyai.com, copy your API key.
3. **Edge Functions**: deploy the two functions in `supabase/functions/` via Supabase CLI, set `ASSEMBLYAI_API_KEY` and `WEBHOOK_SECRET` as secrets.
4. **iOS app**: open Xcode, create a new SwiftUI project named `TranscriptionAPPMVP` (iOS 17+, Swift), add the [supabase-swift](https://github.com/supabase/supabase-swift) Swift package, drop the files in `ios/` into the project. Copy `Config.swift.example` to `Config.swift` and fill in your Supabase URL and anon key (`Config.swift` is gitignored so your keys won't be committed).
5. **Run on simulator** → email yourself an OTP → record → verify upload + transcript.
6. **TestFlight**: see `docs/TESTFLIGHT.md`.

---

## Cost estimates (for 50 users)

Assuming each user records 1 hour per week:

- AssemblyAI: 50 users × 4 hr/mo × $0.37 = **~$74/mo**
- Supabase Free tier covers Auth, 500MB DB, 1GB storage, 2GB bandwidth — enough to start. Pro tier ($25/mo) is the first upgrade you'll need when you cross 1GB storage (roughly 30 hours of recordings).
- APNs is free.

For 1M users you'd switch to Supabase Team/Enterprise, move heavy storage to S3 with lifecycle policies, and negotiate AssemblyAI volume pricing — but the application code stays the same.

---

## CI / CD

Continuous build + test + TestFlight delivery runs on **Xcode Cloud** (Apple's first-party CI). The setup lives in two places:

- **`ci_scripts/`** — shell hooks Xcode Cloud invokes automatically. `ci_post_clone.sh` materializes `Config.swift` from secret env vars so the build doesn't need committed keys.
- **App Store Connect → Your App → Xcode Cloud → Workflows** — defines what to build, what to test, and where to deliver (e.g. TestFlight internal group on every push to `main`).

Full setup walkthrough: **`docs/CICD.md`**.

