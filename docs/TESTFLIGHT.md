# Shipping to TestFlight

Getting the app to your friend's phone via TestFlight. Plan ~1 hour the first time you do this.

## Prerequisites

- An **Apple Developer account** ($99/year). Sign up at [developer.apple.com](https://developer.apple.com). Approval takes hours to a couple of days. There's no way around this — TestFlight requires a paid account.
- Your friend's **Apple ID email** (the one they use for the App Store on their phone).

## 1. Configure signing in Xcode

1. Open the project in Xcode. Click the top-level project in the file navigator.
2. Select the `TranscriptionAPPMVP` target → **Signing & Capabilities**.
3. Check **Automatically manage signing**.
4. Pick your Apple Developer team from the dropdown.
5. Set **Bundle Identifier** to something unique you control, e.g. `com.milanvarghese.transcriptionmvp`. Bundle IDs are reverse-DNS and globally unique on Apple's side.

## 2. Create the app in App Store Connect

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **My Apps → +** → New App.
2. Platform: iOS. Name: `Transcribe MVP` (App Store name — can differ from Xcode display name). Primary language: English. Bundle ID: pick the one you set above. SKU: anything unique, e.g. `transcribe-mvp-001`.

## 3. Build + upload

1. In Xcode, set the run target (top bar) to **Any iOS Device (arm64)**.
2. Bump the build number under **General → Identity → Build** (every TestFlight upload needs a fresh build number; just increment by 1).
3. Menu: **Product → Archive**. This takes a few minutes.
4. When the Organizer window opens with your archive, click **Distribute App → App Store Connect → Upload**.
5. Defaults are fine. Wait for "Upload succeeded" — then for the build to finish processing on Apple's side (usually 5–30 min; you'll get an email).

## 4. Set up TestFlight

1. In App Store Connect → your app → **TestFlight** tab.
2. Apple will show your build with "Missing Compliance" — click it and answer "Does your app use encryption?" → for HTTPS-only apps, the answer is **No** (HTTPS doesn't count for export-compliance purposes in Apple's standard exemption). Submit.
3. Under **Internal Testing**, create a group → add your friend's Apple ID email. Internal testers don't need Apple review and can install immediately.
   - (If your friend isn't part of your Apple Developer team, use **External Testing** instead. External testing requires a quick Apple review — usually approved same-day for utilities like this.)

## 5. Tester's side

Your friend installs the [TestFlight app](https://apps.apple.com/app/testflight/id899247664) from the App Store. They'll get an email invite with a redeem code — they tap the link from their iPhone, accept the invite in TestFlight, and the app installs.

## 6. Iterating

Every time you change Swift code:

1. Bump the build number.
2. Product → Archive → Distribute → upload.
3. Wait for processing email.
4. Testers get the update via TestFlight automatically (or with their automatic updates on, even more seamlessly).

## Common gotchas

- **"No signing certificate"** — Sign in to your Apple Developer account inside Xcode (Settings → Accounts), and click "Manage Certificates → +" → Apple Distribution.
- **Build doesn't show up in TestFlight** — wait 15 more minutes; processing can be slow.
- **Microphone permission missing** — your Info.plist additions didn't make it into the archive. Confirm `Privacy - Microphone Usage Description` is set on the target, not just the Info.plist file.
- **App crashes on launch only on the friend's device** — usually means you forgot to commit `Config.swift` with real values. Hardcode them for now; we can move them to a build-time config file later.
