# Xcode Cloud setup

Xcode Cloud is Apple's first-party CI/CD service. It builds the app, runs tests, and (optionally) ships to TestFlight automatically — all configured through Xcode and App Store Connect, no YAML files in the repo.

Estimate: 30–45 minutes the first time.

## Prerequisites

- **Apple Developer Program membership** ($99/year). Xcode Cloud isn't usable without this.
- **App created in App Store Connect** (see `docs/TESTFLIGHT.md` step 2).
- **Xcode project exists locally.** You must have created the `.xcodeproj` and committed it (see `docs/SETUP.md` step 4). Xcode Cloud configures from inside Xcode — there's nothing to do until the project exists.
- **Repo connected to GitHub** (or GitLab / Bitbucket). Xcode Cloud needs read access to clone it.

## 1. Connect Xcode to your repo

If you haven't already:

1. Open the project in Xcode.
2. **Source Control → New Git Repository** (only if the project isn't already in git — which it should be from `docs/SETUP.md`).
3. **Source Control → "<your repo>" → Configure → Remotes** — verify the GitHub remote URL is present.

## 2. Create the first Xcode Cloud workflow

1. In Xcode: **Product → Xcode Cloud → Create Workflow**.
2. Pick the **TranscriptionAPPMVP** app target. Xcode will ask App Store Connect to provision Xcode Cloud for this app — takes ~30 seconds.
3. Xcode shows the default workflow. Customize it:
   - **Name:** `CI on main`
   - **Start Conditions:** Branch Changes → Source branch: `main` → Files and Folders: Any. (This runs the workflow on every push to `main`.)
   - **Environment:** macOS = latest. Xcode = latest release.
   - **Actions:**
     - **Build** — Scheme: `TranscriptionAPPMVP`, Platform: iOS, Configuration: Debug.
     - **Test** — Scheme: `TranscriptionAPPMVP`, Test Plan: (whatever test plan you've set up; pick "All Tests" if none).
     - **Archive** — Distribution: TestFlight (Internal Only). (Skip this until you've actually shipped to TestFlight once via Xcode — see `docs/TESTFLIGHT.md`.)
   - **Post-Actions:** TestFlight External Testing Notify → off (use Internal first). Slack / email notifications → optional.

4. Save.

## 3. Add the secret environment variables

Xcode Cloud needs `SUPABASE_URL` and `SUPABASE_ANON_KEY` so `ci_scripts/ci_post_clone.sh` can write `Config.swift` at build time.

1. Open **[App Store Connect](https://appstoreconnect.apple.com)** → your app → **Xcode Cloud** tab → **Settings (gear icon) → Environment**.
2. Add **Environment Variable** → name: `SUPABASE_URL` → value: `https://YOUR-PROJECT-REF.supabase.co` → leave **Secret** unchecked (URLs aren't secrets).
3. Add **Environment Variable** → name: `SUPABASE_ANON_KEY` → value: the anon key from Supabase → **check "Secret"** (this hides the value in logs).

Scope: leave at the workflow level for now. If you add multiple workflows later (preview branches, etc.), you can promote them to app-wide.

## 4. Trigger the first build

Push any commit to `main` (or use **Xcode → Report Navigator → Cloud → Start Build** to fire it manually).

Watch the build in App Store Connect → your app → Xcode Cloud → Builds. You'll see four phases:
1. **Clone** — repo is checked out.
2. **Post-Clone** — `ci_scripts/ci_post_clone.sh` runs. Look here if `Config.swift` is missing.
3. **Build** — `xcodebuild` does its thing.
4. **Test** — your XCTest / Swift Testing suite runs in a simulator.

If the first build fails on "Config.swift not found" or similar — you forgot step 3. Double-check the env var names match exactly.

## 5. Add tests (the part that justifies the workflow)

A CI workflow without tests is just an expensive build trigger. For this app, the testable surface is:

- **`AudioRecorder`** — extract the state machine (start/pause/resume/stop/discard transitions) into something testable. The actual `AVAudioRecorder` should sit behind a protocol you can stub.
- **`UploadQueue`** — pure FIFO logic + retry behavior. Fake the `SupabaseService` and assert that the right state transitions happen on success/failure.
- **`HistoryViewModel`** — fetch / rename / delete flows against a fake service.
- **Edge Functions** — Deno has a built-in test runner. These can run in a separate, much faster Linux CI (GitHub Actions free tier) since they don't need macOS.

Add a `TranscriptionAPPMVPTests` target in Xcode (File → New → Target → Unit Testing Bundle). Tests in there run automatically in the Xcode Cloud "Test" action.

## 6. Costs

Xcode Cloud free tier: **25 compute hours/month**. A clean build + test for this app is ~5–8 minutes, so ~3 builds/hour. That covers ~75–150 builds/month — fine for solo dev.

Above the free tier: $49.99/mo for 100 hours, $99.99/mo for 250 hours, $199.99/mo for 1,000 hours.

## 7. Common gotchas

- **"Couldn't find scheme"** — schemes need to be **shared** for Xcode Cloud to see them. In Xcode: Product → Scheme → Manage Schemes → tick "Shared" next to your scheme → commit the resulting `.xcscheme` file under `<project>.xcodeproj/xcshareddata/xcschemes/`.
- **`ci_post_clone.sh` doesn't run** — Xcode Cloud only runs scripts from `ci_scripts/` at the repo root **or** alongside the `.xcodeproj`. We have ours at repo root.
- **Build fails with "no signing certificate"** — Xcode Cloud manages signing automatically *only* for the Archive action. For Build/Test actions you can use "Sign to Run Locally" (no provisioning profile needed).
- **Tests fail in CI but pass locally** — usually a missing simulator. Specify the destination explicitly in the workflow (e.g. "iPhone 15, iOS 17.5").
- **Build runs forever / times out** — workflow default timeout is 60 minutes. If you're hitting it on a clean build, something's wrong; check the logs in Xcode Cloud → Builds.
