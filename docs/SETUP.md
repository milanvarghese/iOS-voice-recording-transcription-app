# Setup guide

End-to-end setup, starting from zero accounts. Estimate: 45–90 minutes if it's your first time with these services.

## 1. Supabase

1. Sign up at [supabase.com](https://supabase.com) and create a new project. Pick a region close to you.
2. Wait ~2 minutes for the project to provision.
3. Go to **SQL editor** → paste the contents of `supabase/schema.sql` → Run.
4. Go to **Storage** → New bucket → name it `recordings` → **set it to Private** (the default).
5. Back in **SQL editor**, paste `supabase/storage_policies.sql` → Run.
6. Go to **Authentication → Providers → Email** and confirm "Enable Email provider" + "Enable email OTP" are on. (Email confirmation can be off for OTP-only flow.)
7. **Authentication → URL Configuration**: not relevant for OTP; skip.
8. Go to **Project Settings → API**. Copy:
   - Project URL (e.g. `https://abcdefgh.supabase.co`) → `Config.swift` → `supabaseURL`
   - `anon` `public` key → `Config.swift` → `supabaseAnonKey`
   - `service_role` `secret` key → keep this for step 3 below. **NEVER paste it into the iOS app.**

## 2. AssemblyAI

1. Sign up at [assemblyai.com](https://www.assemblyai.com). $50 free credit on signup at the time of writing — more than enough for testing.
2. **Dashboard → Account → API Keys**. Copy the key.

## 3. Edge Functions (the transcription glue)

You need the Supabase CLI installed locally. On macOS:

```bash
brew install supabase/tap/supabase
```

Then, from the project root:

```bash
# Login + link the local repo to your Supabase project
supabase login
supabase link --project-ref YOUR-PROJECT-REF

# Set the secrets the functions need
supabase secrets set ASSEMBLYAI_API_KEY=your_assemblyai_key
supabase secrets set WEBHOOK_SECRET=$(openssl rand -hex 32)

# Deploy the webhook FIRST so we can resolve its URL
supabase functions deploy assemblyai_webhook --no-verify-jwt

# Note the URL it prints, then set it as a secret so submit_for_transcription knows where to point AssemblyAI's callback
supabase secrets set WEBHOOK_URL=https://YOUR-PROJECT-REF.supabase.co/functions/v1/assemblyai_webhook

supabase functions deploy submit_for_transcription
```

To test the functions end-to-end, sign in from the app, record a 10-second clip, and watch the **Edge Function logs** in the Supabase dashboard.

## 4. iOS app

1. Install Xcode 15+ (App Store).
2. Open Xcode → **File → New → Project → iOS → App**.
   - Product name: `TranscriptionAPPMVP`
   - Interface: SwiftUI
   - Language: Swift
   - Minimum deployment: iOS 17.0
3. Close the project. In Finder, drag the files from `ios/TranscriptionAPPMVP/` over the equivalent locations in the Xcode project folder, replacing the auto-generated `ContentView.swift` and `TranscriptionAPPMVPApp.swift`.
4. Re-open the Xcode project. Right-click the project in the navigator → **Add Files…** → select the new folders (Models, Services, ViewModels, Views, Config.swift) so Xcode tracks them.
5. **Add the Supabase Swift package**: File → Add Package Dependencies → paste `https://github.com/supabase/supabase-swift` → Add. Pick the latest stable version, add the `Supabase` library to your target.
6. **Info.plist**: open the auto-generated Info area for your target and add:
   - `Privacy - Microphone Usage Description` → the string from `Info.plist` in this repo.
   - **Signing & Capabilities → + Capability → Background Modes** → check "Audio, AirPlay, and Picture in Picture".
7. Copy `Config.swift.example` to `Config.swift` (in the same folder) and fill in your Supabase URL + anon key from step 1. `Config.swift` is gitignored so your keys never leave your machine — `Config.swift.example` is what gets committed.
8. Run on a real device (the simulator's microphone works but is hilariously bad). Sign in with your email, hit Record, talk for 20 seconds, hit Stop, switch to History, watch the row go from Uploading → Transcribing → Ready.

## 5. Troubleshooting

**"Microphone access is denied"** — Settings → TranscriptionAPPMVP → Microphone → toggle on.

**Recording doesn't continue when app is backgrounded** — Verify the Background Modes capability is added with the Audio checkbox.

**Upload completes but transcript never arrives** — Check Edge Function logs in the Supabase dashboard. Most common cause is `WEBHOOK_URL` not set correctly, so AssemblyAI calls a 404.

**OTP email never arrives** — Check spam. Supabase free tier uses a shared SMTP with strict rate limits. For >10 signups/hour, configure custom SMTP in Authentication → Email Settings (Resend, SendGrid, or Postmark all work).
