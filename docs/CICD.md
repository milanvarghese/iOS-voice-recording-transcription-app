# Xcode Cloud setup

Xcode Cloud is Apple's first-party CI/CD service. It builds the app on every push — no YAML files in the repo.

**Current state:** Xcode Cloud successfully builds the App Store `.ipa` on every push to `main`. The TestFlight upload step is currently done manually via Transporter due to an export-distribution quirk explained below. Fixing the quirk gets you fully automated push → TestFlight, but isn't a blocker for shipping.

Estimate to set up the first time: 30–45 minutes.

## Prerequisites

- **Apple Developer Program membership** ($99/year). Xcode Cloud isn't usable without this.
- **App created in App Store Connect** (Xcode Cloud's setup wizard will create one automatically if it doesn't exist).
- **Xcode project committed locally** (the repo already has it at `TranscriptionAPPMVP/TranscriptionAPPMVP.xcodeproj`).
- **Repo connected to GitHub** with the Apple Xcode Cloud GitHub App authorized on your account.

## 1. Authorize GitHub in Xcode

Xcode 16+ moved this under Settings:

1. Xcode → **Settings → Source Control → +** → GitHub.
2. Account: your GitHub username. Token: paste a Personal Access Token with `repo`, `admin:public_key`, and `user` scopes (click "Create a Token on GitHub" — pre-selects the right scopes).
3. Click Sign In.

You can skip this manual step — the Xcode Cloud wizard will prompt for the same auth mid-flow.

## 2. Create the workflow

1. In Xcode: **Integrate → Create Workflow…**
2. **Select Product**: pick the `TranscriptionAPPMVP` app target → Next.
3. **Review Workflow**: defaults are fine.
   - **Start Condition**: Branch Changes on `main`. Every push triggers a build.
   - **Environment**: latest Xcode + latest macOS.
   - **Actions**: **Archive – iOS** with **Distribution Preparation: TestFlight (Internal Testing Only)**. This is the critical setting — without it, the build can't produce a TestFlight-ready archive.
   - **Post-Actions**: add **TestFlight Internal Testing – iOS**. Pick your `InternalTesters` group (create one in App Store Connect → TestFlight → Internal Testing first if needed).
4. **Grant Access to Source Code**: click "Grant Access" on the `milanvarghese/iOS-voice-recording-transcription-app` row (or whatever your repo is). The pointfreeco / supabase rows in the same dialog are public dependencies — you can skip those.
5. **App Store Connect**: if no app record exists yet, click "Create" to auto-generate one using your bundle ID.
6. Wizard completes. First build kicks off automatically.

## 3. Add the secret environment variables

Xcode Cloud needs `SUPABASE_URL` and `SUPABASE_ANON_KEY` so `ci_scripts/ci_post_clone.sh` can write `Config.swift` at build time.

1. App Store Connect → your app → **Xcode Cloud** tab → **Settings** (gear icon) → **Environment**.
2. Add → name `SUPABASE_URL`, value `https://<your-ref>.supabase.co`, **Secret** unchecked.
3. Add → name `SUPABASE_ANON_KEY`, value your real anon key (the long `eyJh…` JWT), **Secret** checked.
4. Save.

These are workflow-scoped. If you add more workflows later you can promote them to app-wide.

## 4. The `ci_scripts/` folder

Located at `TranscriptionAPPMVP/ci_scripts/`. Three scripts:

- **`ci_post_clone.sh`** — writes `Config.swift` from `SUPABASE_URL` + `SUPABASE_ANON_KEY` env vars. This is the only one that does real work.
- **`ci_pre_xcodebuild.sh`** — sanity-checks that `Config.swift` exists before `xcodebuild` starts.
- **`ci_post_xcodebuild.sh`** — no-op placeholder.

**Important:** the folder must sit either at the repo root or next to the `.xcodeproj`. We put it next to `.xcodeproj` (`TranscriptionAPPMVP/ci_scripts/`) because that location is more reliable when the Xcode project is in a subdirectory. Earlier in the project's history the scripts were at the repo root and Xcode Cloud sometimes failed to discover them.

## 5. The export-distribution quirk (why TestFlight delivery is still manual)

This is the only thing standing between you and fully automated TestFlight delivery.

**Symptom:** every Xcode Cloud build shows status **❌ Failed** with **2 warnings**, even when nothing is actually wrong:

> Exporting for Ad Hoc Distribution failed. Please download the logs artifact for more information.
> Exporting for Development Distribution failed. Please download the logs artifact for more information.

**What's happening:** Xcode Cloud's "Archive – iOS" action tries to produce **three** export formats per build — App Store, Ad Hoc, and Development. With automatic signing, only the App Store flavor gets a valid distribution certificate. The other two fail with `exit code: 70` because there's no matching certificate/profile. Even though the **App Store export succeeds and produces a working `.ipa`**, Xcode Cloud flags the whole action as failed because of the other two, which causes the TestFlight post-action to be skipped (`Did Not Run`).

So the artifact you actually want (`TranscriptionAPPMVP 1.0 app-store`, ~2 MB `.ipa`) sits in the build's Artifacts tab, untouched.

**Workaround:** download it manually and upload via Apple Transporter. See `docs/TESTFLIGHT.md`.

**Real fix (when you care about full automation):** create Ad Hoc and Development provisioning profiles for your bundle ID so all three exports succeed.

1. [developer.apple.com/account](https://developer.apple.com/account) → Certificates, Identifiers & Profiles → Profiles → **+**.
2. Create an **iOS App Development** profile tied to `com.yourname.TranscriptionAPPMVP`, attached to at least one registered device (plug an iPhone into your Mac via USB and Xcode will offer to register it).
3. Create an **Ad Hoc Distribution** profile, also tied to your bundle ID and devices.
4. Trigger another Xcode Cloud build. With matching profiles, all three exports succeed, the Archive action turns green, and the TestFlight post-action automatically uploads the `.ipa`.

This isn't worth doing for a small TestFlight cohort. It is worth doing once you're shipping multiple builds per week.

## 6. Add tests (the part that justifies the workflow)

A CI workflow without tests is just an expensive build trigger. There's no test target yet — adding one is on the deferred list in `docs/EDGE_CASES.md`. Highest-value test targets:

- **`AudioRecorder`** — start/pause/resume/stop/discard state machine. Stub `AVAudioRecorder` behind a protocol.
- **`UploadQueue`** — FIFO + retry behavior. Fake `SupabaseService`, assert state transitions on success/failure.
- **`HistoryViewModel`** — fetch / rename / removeFromPhone / deleteForever / retryTranscription against a fake service.
- **Edge Functions** — Deno has a built-in test runner. Faster on a Linux GitHub Actions runner than on macOS Xcode Cloud.

Add a `TranscriptionAPPMVPTests` target (File → New → Target → Unit Testing Bundle). Tests run automatically in the Xcode Cloud "Test" action.

## 7. Costs

Xcode Cloud free tier: **25 compute hours/month**. A clean archive of this app takes ~3 min, so roughly 500 builds/month — easily plenty for solo development.

Above the free tier: $49.99/mo for 100 hours, $99.99/mo for 250 hours, $199.99/mo for 1,000 hours.

## 8. Common gotchas

- **"Couldn't find scheme"** — Schemes need to be **shared** for Xcode Cloud to see them. Product → Scheme → Manage Schemes → tick "Shared" → commit the resulting `.xcscheme` under `*.xcodeproj/xcshareddata/xcschemes/`.
- **`ci_post_clone.sh` doesn't run** — Xcode Cloud only runs scripts from `ci_scripts/` at the repo root or alongside the `.xcodeproj`. We're using the latter location.
- **First build fails on "Config.swift not found"** — `SUPABASE_URL` / `SUPABASE_ANON_KEY` env vars not set in App Store Connect → Xcode Cloud → Settings → Environment. Set them, then **Start Build** manually (a fresh push works too).
- **Build runs forever / times out** — workflow default timeout is 60 minutes. If you're hitting it on a clean build, something else is wrong; check the logs in Xcode Cloud → Builds.
- **"GitHub App not installed in org"** — Only relevant if you try to grant access to repos owned by external orgs (pointfreeco, supabase). You can't install Apple's app in someone else's org. Skip those rows; public deps clone anonymously during build.
- **Build "fails" but the App Store `.ipa` is in Artifacts** — That's the export-distribution quirk above. The `.ipa` is fine; download and Transporter-upload it.
