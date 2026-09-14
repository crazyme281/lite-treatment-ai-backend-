# Native build setup — Push Notifications & Screen Shielding

Everything code-side is implemented for real (native plugins, real FCM v1 send,
real Capacitor native projects). What's listed below is the credentials/config
that only you can supply — an Anthropic assistant can't create Firebase or
Apple Developer accounts on your behalf.

## 1. Push Notifications

### Android (Firebase Cloud Messaging)
1. Create a Firebase project at https://console.firebase.google.com (or use an
   existing one).
2. Add an Android app to it with package name `com.litetreatment.app`
   (must match `capacitor.config.ts`'s `appId`).
3. Download the generated `google-services.json` and place it at:
   `android/app/google-services.json`
   (The Gradle wiring for this already exists in `android/app/build.gradle` —
   it conditionally applies the Google Services plugin only if this file is
   present. Nothing else to edit there.)
4. In Firebase Console → Project Settings → Service Accounts, click
   "Generate new private key" — downloads a JSON file.
5. Set it as a Supabase Edge Function secret named exactly
   `FCM_SERVICE_ACCOUNT_JSON` (paste the entire file's JSON content as the
   secret value). This is what `send-case-alert` uses to authenticate to
   FCM's HTTP v1 API — the actual OAuth2 JWT-bearer + send implementation is
   already written and deployed; it just needs this secret to activate.

### iOS (APNs via Firebase)
1. In your Apple Developer account, create an APNs Auth Key (Certificates,
   Identifiers & Profiles → Keys → "+"), enabling Apple Push Notifications
   service. Download the `.p8` file — Apple only lets you download it once.
2. In the same Firebase project, add an iOS app with bundle ID
   `com.litetreatment.app`, upload that `.p8` key under
   Project Settings → Cloud Messaging → Apple app configuration.
3. Download `GoogleService-Info.plist` and add it to the Xcode project
   (drag into `ios/App/App/` in Xcode, checking "Copy items if needed" and
   target membership "App").
4. `App.entitlements` already declares `aps-environment: development` — for a
   TestFlight/App Store build, change this value to `production` before
   archiving.
5. In Xcode, confirm the target's "Signing & Capabilities" shows
   "Push Notifications" (it should auto-detect from the entitlements file
   already in this repo) and "Background Modes → Remote notifications"
   (already set in `Info.plist`).

### DND-bypass specifically (both platforms)
Everything above delivers a normal push. Bypassing Do Not Disturb / silent
mode for critical alerts requires Apple's separate **Critical Alerts
entitlement** (`com.apple.developer.usernotifications.critical-alerts`),
which Apple grants per-app on request — mostly to health/safety apps — via
a form in your Apple Developer account, not via any code change. Android has
no exact equivalent; the closest is a high-priority notification channel
with sound/vibration overriding some Do Not Disturb configurations, which
`send-case-alert` already requests via `android: { priority: "high" }`.

## 2. Screen Shielding

No credentials needed — this only requires building the app natively:

```
cd ionic-frontend
npm install
npm run build
npx cap sync
npx cap open android   # opens Android Studio
npx cap open ios       # opens Xcode (macOS only)
```

Run on a **physical device** — the Android emulator and iOS Simulator don't
reliably exercise FLAG_SECURE / screen-recording detection the way real
hardware does.

**iOS note:** I hand-edited `ios/App/App.xcodeproj/project.pbxproj` to wire
`ScreenShieldPlugin.swift` into the build target (it's structurally valid —
braces/parens balance — but I could not open this in actual Xcode to confirm
it compiles, since this environment has no Xcode installed). If Xcode
complains about the file on first open, the fallback is: delete the two
`ScreenShieldPlugin.swift` entries from the project navigator if broken, then
drag the file back in from Finder with "Add to target: App" checked — a
30-second manual fix, not a rewrite.

## What's genuinely NOT possible on iOS, by design

No app — including this one — can outright *prevent* a screenshot on stock
iOS; Apple provides no such API. What this build actually does on iOS:
hides content from the app-switcher snapshot (reliable), auto-blanks the
screen for the duration of any detected active screen recording (reliable,
verified to work regardless of WKWebView), and detects (not prevents)
screenshots after the fact, logging them to `audit_log`. See the comment
block at the top of `ScreenShieldPlugin.swift` for the full technical
breakdown.
