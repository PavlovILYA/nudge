# Nudge

Nudge is a native iPhone application for persistent reminders. Current status: **infrastructure bootstrap**, version **0.0.1**, build **1**. The only screen displays “Nudge”, “Version 0.0.1”, and “Nudge is running”, using system light and dark appearances. Reminder functionality is not implemented.

## Stack and requirements

- Swift 6 and SwiftUI, without third-party dependencies.
- iPhone only, minimum iOS **26.0**; Bundle ID `com.pavlovilya.nudge`.
- GitHub Actions uses the explicitly selected **`xcode-27`** hosted runner and the latest installed stable Xcode 27 / bundled iOS SDK. The deployment target remains 26.0 even when the SDK is newer.
- The primary development machine is an Intel MacBook Pro 2018 on macOS Sequoia 15.8.1. Edit sources and use Git locally; a full compatible Xcode and SDK are required for local builds and previews. Command Line Tools alone cannot build this app. Do not upgrade this Mac or install unsupported Xcode to satisfy CI requirements.
- An iPhone 13 will need a supported iOS version and a separately verified signing/install method before device installation.

## Project

```text
Nudge.xcodeproj/                 Application target and shared Nudge scheme
Nudge/
  NudgeApp.swift                SwiftUI application entry point
  ContentView.swift             Static bootstrap screen
  Assets.xcassets/               Asset catalog
.github/workflows/ios-build.yml  Simulator and device build checks
AGENTS.md                       Contributor rules
```

Open with `open Nudge.xcodeproj`, or use File → Open in Xcode. Choose the shared **Nudge** scheme. No project generator or package installation is needed. Older Xcode may open the project but cannot validate it against an SDK it does not contain.

Unlike a JVM application, this project builds separate native binaries for the simulator and iPhone. The `.xcodeproj` holds target settings and source membership; the shared scheme tells Xcode and CI what to build. Xcode generates `Info.plist` from settings: `MARKETING_VERSION` sets `CFBundleShortVersionString` to `0.0.1`, while `CURRENT_PROJECT_VERSION` sets the separate `CFBundleVersion` to `1`.

## Continuous integration

The **iOS Build** workflow runs on pushes to `main`, pull requests targeting `main`, and manual dispatch. It uses read-only repository permissions, logs Xcode, Swift and SDK versions, and runs two independent Release build checks with `CODE_SIGNING_ALLOWED=NO`:

```sh
xcodebuild -project Nudge.xcodeproj -scheme Nudge \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Nudge.xcodeproj -scheme Nudge \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Each successful build is packaged with `ditto` and uploaded separately. The workflow does not deploy, publish releases, create tags, or sign code. No certificates, provisioning profiles, Apple API keys, or secrets are configured.

To download: open the repository's **Actions** tab → **iOS Build** → select a run → download an artifact under **Artifacts** (GitHub sign-in may be required). Artifacts are retained for 14 days. Extract the artifact download, then its application ZIP if GitHub wraps it in another ZIP.

| Artifact / format | Purpose | Installable on iPhone? |
| --- | --- | --- |
| `Nudge-0.0.1-iOS-Simulator` (`.app` in ZIP) | Runs in a compatible iOS Simulator on a Mac; architecture depends on the runner | No |
| `Nudge-0.0.1-iOS-Device-Unsigned` (`.app` in ZIP) | Validates physical-device SDK and architecture compilation | No: it has no installation signing/provisioning |
| Signed installable `.ipa` (not produced yet) | Properly packaged device application signed and provisioned for its distribution method | Only when the signature, provisioning, entitlements and device/OS meet that method's requirements |

An unsigned device `.app` is **not a signed IPA**, and renaming its ZIP does not make it installable. Compilation success alone does not validate signing, installation or runtime behavior. The simulator build can be installed into a compatible booted simulator using `xcrun simctl install booted /path/to/Nudge.app`; this Mac may lack the required simulator runtime or architecture.

## Workflow and next stages

Develop locally → push a feature branch → open a PR to `main` → verify both CI checks → review artifacts. Merge only with explicit authorization.

For eventual iPhone installation, download the unsigned device artifact and use a **verified compatible** method to sign and install it. Free Apple ID signing and third-party sideloading tools remain research options, not a promised working installation path. A later paid Apple Developer Program workflow may automate signed IPA generation. Signing credentials must stay outside the repository.

Future stages are signing/device validation, then deliberately scoped reminder functionality and later integrations. Voice input, AlarmKit, EventKit, SwiftData, calendar synchronization and LLM integration are outside this bootstrap.

Versioning follows Semantic Versioning (`MAJOR.MINOR.PATCH`). Marketing version and build number remain distinct; unrelated commits do not bump versions and no release tags are generated automatically.
