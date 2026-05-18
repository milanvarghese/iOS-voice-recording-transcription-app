# Shipping to TestFlight

Two paths:

- **Automated via Xcode Cloud + Transporter** (current): Xcode Cloud builds the archive on every push; you download the `.ipa` and run Transporter manually to upload to TestFlight. ~5 min of human time per release.
- **Fully automated**: requires fixing the Xcode Cloud export-distribution quirk (see `docs/CICD.md`). Once fixed, every push to `main` lands in TestFlight with zero manual steps.

This doc covers the manual-Transporter path because that's what's working today.

## Prerequisites (one-time)

- **Apple Developer account** ($99/year). Sign up at [developer.apple.com](https://developer.apple.com). Approval takes hours to a couple of days.
- **App record in App Store Connect**. If you've already run the Xcode Cloud setup (`docs/CICD.md`), this was created automatically. Otherwise create it manually: App Store Connect → My Apps → + → New App. Bundle ID must match your Xcode target.
- **Apple ID emails of your testers**. They install via the [TestFlight app](https://apps.apple.com/app/testflight/id899247664).
- **Transporter app installed**: free from the Mac App Store. [Direct link](https://apps.apple.com/app/transporter/id1450874784).

## 1. Make sure the build is ready to upload

Two things often trip the first upload:

1. **App icon must exist.** Apple Transporter rejects archives without a 120×120 (or 1024×1024 + auto-generation) PNG in `Assets.xcassets/AppIcon.appiconset/`. The repo ships a placeholder mic-silhouette PNG — replace it with real branding when you have it, but **don't ship without one**.
2. **Build number must be unique.** Every TestFlight upload needs a build number Apple hasn't seen before for this version. Xcode Cloud auto-bumps the build number to match its build counter (so build #9 in Xcode Cloud becomes version `1.0(9)`). If you do a local Archive instead, bump the Build field in target → General → Identity manually.

## 2. Trigger an Xcode Cloud build

Push to `main`:

```bash
git push
```

Xcode Cloud auto-triggers a build (about 5–8 min). Watch progress at App Store Connect → your app → Xcode Cloud → Builds.

**Expect the build to show as "Failed" with 2 warnings** even though it actually succeeded. The "failures" are unrelated ad-hoc / development export attempts that don't have certificates; the App Store export inside the same archive run is successful and produces a usable `.ipa`. See `docs/CICD.md` for the long story.

## 3. Download the App Store `.ipa`

1. App Store Connect → your app → **Xcode Cloud** → click the latest build (red ❌ status is fine if there's a yellow ⚠️ next to "Archive – iOS").
2. Sidebar → **Archive – iOS → Artifacts**.
3. You'll see ~4 files. Click **Download** next to **`TranscriptionAPPMVP 1.0 app-store`** (the ~2 MB `.ipa`). The other files (full archive, logs, XCResult) aren't needed.

## 4. Upload via Transporter

1. Open the **Transporter** app on your Mac. Sign in with your Apple ID if first time.
2. Drag the `.ipa` file into the Transporter window.
3. Transporter validates the package (10–30 sec). Common rejections at this step:
   - **"Missing required icon file"** — the icon isn't actually in the archive. Re-check `Assets.xcassets/AppIcon.appiconset/`.
   - **"Build number already exists"** — Apple already saw this build number. Push another commit (Xcode Cloud will bump the number) or bump it manually.
4. Click **Deliver**. Upload takes 1–3 min.
5. Green "Delivery succeeded" → done.

## 5. Approve compliance + distribute

1. Wait ~5–15 min for Apple's server-side processing. You'll get an email "TranscriptionAPPMVP 1.0(N) has finished processing" when ready.
2. App Store Connect → your app → **TestFlight** tab. The build appears under "iOS Builds".
3. A yellow **"Missing Compliance"** banner sits next to the build. Click it → "Does your app use encryption?" → **No**. This is the standard exemption for apps that only use Apple's built-in HTTPS / URLSession (we don't bundle OpenSSL or any custom crypto).
4. Status flips to **"Ready to Test"** within ~30 seconds.

## 6. Set up testers (one-time per group)

If you haven't already created an Internal Testing group:

1. TestFlight tab → left sidebar → **Internal Testing** → **+** next to "Internal Group".
2. Name it `Internal Testers` (or anything). Enable **automatic distribution** so new builds go out as soon as they're ready.
3. Add testers by Apple ID email.

Builds you've already uploaded auto-distribute to the group. New uploads also auto-distribute thanks to step 2.

## 7. On the tester's device

1. Install [TestFlight](https://apps.apple.com/app/testflight/id899247664) from the App Store.
2. Sign in with the Apple ID you added to the group.
3. TranscriptionAPPMVP appears in the list. Tap **Install**.
4. Open the app. Sign in with your email → OTP → record → enjoy.

## 8. Iterating on builds

Every code change:

1. `git push` to `main`.
2. Wait for Xcode Cloud build (~5–8 min).
3. Download new `.ipa` from Artifacts.
4. Drag into Transporter → Deliver.
5. Wait for "processing complete" email (~5–15 min).
6. Testers see "Update available" in TestFlight (or auto-update if they have it on).

Total turnaround: ~15–20 min per release.

## Common gotchas

- **The Xcode Cloud build looks failed but artifacts are there** — That's the normal state right now (see `docs/CICD.md`). The App Store `.ipa` in Artifacts is the real deliverable.
- **Validation failed: "Missing required icon"** — Empty `AppIcon.appiconset/`. Drop in a 1024×1024 PNG and update `Contents.json` to reference it. The repo's placeholder icon ships with this already; if you replaced or deleted it, restore.
- **Validation failed: "Build number already exists"** — App Store Connect rejects duplicate build numbers per version. Push another commit so Xcode Cloud bumps the number.
- **Build doesn't show up in TestFlight after upload** — wait 15 more minutes; Apple's processing is slow sometimes. If still missing after 1 hour, check App Store Connect → Apps → your app → **Distribution** → recent uploads for an error.
- **Tester gets "App not available in your region"** — In App Store Connect → Pricing and Availability, make sure your country is in the availability list for TestFlight.
- **App crashes on tester's device but works locally** — Usually a `Config.swift` placeholder leaked into the archive. The CI script materializes `Config.swift` from env vars; verify `SUPABASE_URL` and `SUPABASE_ANON_KEY` are set correctly in App Store Connect → Xcode Cloud → Settings → Environment.
