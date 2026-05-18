# Setup guide

End-to-end setup, starting from zero accounts. Estimate: 60–90 minutes if it's your first time with these services.

## 1. Supabase

1. Sign up at [supabase.com](https://supabase.com) and create a new project. Pick a region close to you. Save the database password somewhere safe — you'll be asked for it once and can't easily recover it.
2. Wait ~2 minutes for provisioning.
3. **SQL editor** → paste `supabase/schema.sql` → Run. This creates the `recordings` table, RLS policies, and adds the table to the Realtime publication.
4. **Storage** → New bucket → name it `recordings` → **Private** (default). Save.
5. **SQL editor** again → paste `supabase/storage_policies.sql` → Run. Creates per-user RLS on `storage.objects`.
6. **Authentication → Sign In / Providers → Email**:
   - "Enable email provider": ON
   - "Confirm email": **OFF** — otherwise new users have to click a confirmation link before they can sign in via OTP. The OTP flow we use does not need email confirmation.
7. **Authentication → Email Templates → Magic Link**: by default this template sends a clickable link with no 6-digit code. Replace the body with something that prominently shows `{{ .Token }}`. Example:
   ```html
   <h2>Your sign-in code</h2>
   <p>Enter this 6-digit code in the app:</p>
   <h1 style="font-size:32px;letter-spacing:4px;">{{ .Token }}</h1>
   ```
   Save changes. Apply the same change to the **Confirm signup** template as a fallback in case you re-enable confirmation later.
8. **Authentication → Email Templates → Email OTP Settings** (or `mailer_otp_length` in the auth config): set to **6 digits**. Supabase defaults to 8 — your iOS UI says "6-digit code" everywhere, so 8 will confuse users.
9. **Project Settings → API**. Copy:
   - Project URL (`https://<ref>.supabase.co`) → goes into `Config.swift`
   - `anon` `public` key (long JWT) → goes into `Config.swift`
   - `service_role` `secret` key → **keep this somewhere safe** for the next step. Never paste it into iOS code.

**Tip:** if you're driving this with an agent (Claude, etc.), the steps above can be done via the Supabase Management API instead of the dashboard. The agent can `PATCH /v1/projects/{ref}/config/auth` with `mailer_autoconfirm: true`, `mailer_otp_length: 6`, and custom `mailer_templates_*_content`. Single API call, no clicking around.

## 2. AssemblyAI

1. Sign up at [assemblyai.com](https://www.assemblyai.com). $50 free credit on signup at the time of writing — more than enough for testing.
2. **Dashboard → Account → API Keys**. Copy the key. Save somewhere safe.

## 3. Edge Functions (the transcription glue)

Install the Supabase CLI on macOS:

```bash
brew install supabase/tap/supabase
```

If brew tap fails with a `git config` error, clean up and retry:
```bash
sudo rm -rf /opt/homebrew/Library/Taps/supabase
brew install supabase/tap/supabase
```

Then, from the repo root:

```bash
# Easiest login: use a Personal Access Token instead of the browser flow.
# Generate at https://supabase.com/dashboard/account/tokens
supabase login --token sbp_YOUR_TOKEN

# Link this repo to your project
supabase link --project-ref YOUR-PROJECT-REF

# Set the three secrets
supabase secrets set ASSEMBLYAI_API_KEY=your_assemblyai_key
supabase secrets set WEBHOOK_SECRET=$(openssl rand -hex 32)
supabase secrets set WEBHOOK_URL=https://YOUR-PROJECT-REF.supabase.co/functions/v1/assemblyai_webhook

# Deploy both functions
supabase functions deploy assemblyai_webhook --no-verify-jwt
supabase functions deploy submit_for_transcription
```

**Common pitfall:** triple-check that `WEBHOOK_URL` was set to the full HTTPS URL, not accidentally to the secret value. If AssemblyAI later returns 502s pointing at "unreachable webhook," look here first.

**AssemblyAI's `speech_models` requirement:** `submit_for_transcription/index.ts` sends `speech_models: ["universal-2"]` in the request body. AssemblyAI rejects submissions without this field (added to their API in late 2025). If you fork the function and remove it, every transcription will 400.

To verify both functions deployed:

```bash
supabase functions list
```

Both should show `ACTIVE`.

## 4. iOS app

1. Install **Xcode 16+** (App Store). Xcode Cloud builds with the latest Xcode regardless, but you need 16+ locally for `PBXFileSystemSynchronizedRootGroup` projects.
2. **Open the existing Xcode project** at `TranscriptionAPPMVP/TranscriptionAPPMVP.xcodeproj`. (The repo ships an `.xcodeproj` so you don't have to create one.)
3. **Resolve packages**: File → Packages → Resolve Package Versions. Should pull in `supabase-swift` and its deps. If it doesn't, File → Add Package Dependencies → `https://github.com/supabase/supabase-swift` → Up to Next Major → tick `Supabase` library → Add to target.
4. **Create `Config.swift`** from the template:
   ```bash
   cp TranscriptionAPPMVP/TranscriptionAPPMVP/Config.swift.example \
      TranscriptionAPPMVP/TranscriptionAPPMVP/Config.swift
   ```
   Fill in your Supabase URL and anon key. `Config.swift` is gitignored.
5. **Target settings** (click the blue project icon → TranscriptionAPPMVP target):
   - **General → Identity → Bundle Identifier**: reverse-DNS you control, e.g. `com.yourname.TranscriptionAPPMVP`.
   - **General → Minimum Deployments → iOS**: 17.0 (or 17.6 — whatever's in the repo). Xcode 26 defaults to iOS 26 which excludes essentially every device.
   - **Signing & Capabilities** → Automatically manage signing → pick your Apple Developer team. Add **Background Modes** capability and tick only **Audio, AirPlay, and Picture in Picture**.
   - **Info** tab → add `Privacy - Microphone Usage Description` with a string like "TranscriptionAPPMVP records your voice so it can be transcribed."
6. **Share the scheme** (required for Xcode Cloud): Product → Scheme → Manage Schemes → tick **Shared** next to `TranscriptionAPPMVP`. Commit the resulting `.xcscheme` file under `.xcodeproj/xcshareddata/xcschemes/`.
7. **Build & run** on a real device or a recent simulator (iPhone 15 or 17, iOS 17/18). The simulator's microphone works but its audio quality is low; for realistic transcription tests use a real device.
8. **First-run flow**: sign in with your email, enter the 6-digit code from the email, tap Record, talk for 10 seconds, tap Stop, switch to History → watch the row go Uploading → Transcribing → Ready.

## 5. Troubleshooting

**OTP email arrives but contains no 6-digit code** — Step 1.7 was skipped. The Magic Link template needs `{{ .Token }}` added.

**OTP email never arrives** — Check spam. Supabase free tier uses a shared SMTP with strict rate limits. For >10 signups/hour, configure custom SMTP (Resend / SendGrid / Postmark).

**"new row violates row-level security policy" on upload** — Storage RLS compares `auth.uid()::text` (lowercase) against the first folder of the storage path. Swift's `UUID.uuidString` is uppercase. `UploadQueue.upload` already lowercases the user UUID; if you change that code path, make sure case still matches.

**Recording uploads but transcript never arrives** — Two causes:
  1. `WEBHOOK_URL` secret is wrong (set to the secret value or empty). Re-set it via `supabase secrets set WEBHOOK_URL=...` and redeploy the function.
  2. AssemblyAI returned an error. Check Supabase dashboard → Edge Functions → `submit_for_transcription` → Logs. Most common error in late-2025 onward: missing `speech_models` (see step 3).

**Recording doesn't continue when app is backgrounded** — Background Modes capability missing or doesn't include Audio.

**"Microphone access is denied"** — Settings → TranscriptionAPPMVP → Microphone → toggle on. The first launch must trigger the OS prompt, which only fires if `NSMicrophoneUsageDescription` is in the Info plist.
