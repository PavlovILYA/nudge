# Nudge iOS Bootstrap Implementation Plan

**Goal:** A dependency-free SwiftUI iPhone app v0.0.1 with verified simulator and unsigned device Release builds in GitHub Actions, submitted as an unmerged PR.

**Architecture:** Conventional checked-in Xcode project, one application target and shared scheme. Two Swift files provide the entry point and static system-styled screen. No generator, signing setup, or business features.

**Tech stack:** Swift, SwiftUI, iOS 26.0+, Xcode 27 CI runner.

- [x] Create the application target, shared scheme, assets, and version/build settings.
- [x] Add a two-destination Release CI matrix with signing disabled and separate ZIP artifacts.
- [x] Document local constraints, artifact/signing distinctions, workflow, and durable contributor rules.
- [x] Validate project/plist/XML/Swift/workflow syntax locally; review the full diff.
- [x] Commit and push the feature branch, open a PR to main, inspect actual CI and artifacts, fix failures if needed. Never merge.

The user's detailed task is the specification. Work in the requested checkout and feature branch. Compilation on the local Command Line Tools installation cannot validate SwiftUI or the iOS SDK; GitHub Actions is the compilation acceptance gate. The static bootstrap screen does not warrant unit-test scaffolding.

Local verification: project plist and settings, source references, shared scheme XML, asset JSON, Swift syntax, workflow YAML/shell syntax and actionlint passed. actionlint needs an external config allowing the documented `xcode-27` label because its bundled runner list omits it. Independent read-only review found no significant issues. Compilation and artifact validation remain the CI gate.

CI verification: https://github.com/PavlovILYA/nudge/actions/runs/43249782656 passed both Release builds using Xcode 27.2 / Swift 6.4.2 / iOS SDK 27.2. Downloaded both ZIPs and verified bundle identifiers, version 0.0.1, build 1, minimum iOS 26.0, iPhone family, platform distinction and executable presence. PR #1 is open against main. Official checkout/upload actions updated to v7 after the first run reported Node 20 deprecation; verify the final head again before handoff.
