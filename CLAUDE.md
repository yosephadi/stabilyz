CLAUDE.md — Stabilyz
iOS app for prosthetic limb users to self-measure walking stability.Local-only, offline, single-user. No backend, no accounts, no networkingcode, no third-party dependencies. iOS 17+, SwiftUI, SwiftData.

Source of truth (read before coding)
docs/stabilyz-prd.md — the product requirements. AUTHORITATIVE.
docs/stabilyz-technical-design-document.md — the technical design (TDD).(This doc is being split into numbered files 01–25; keep references updated.)
Read the TDD section(s) relevant to the current task before writing code.
Never invent product features. Only build what the PRD/TDD specify.
Markers: [PRD] = required, non-negotiable · [REC] = decided techrecommendation, follow it · [OPEN] = deliberately unresolved.NEVER silently resolve an [OPEN] item — use a clearly-labeled placeholderand flag it to the user instead.
Hard architecture rules (from TDD §3 — violating these = redo)
Layers: Presentation → Feature/State → Domain → Algorithms → Services →Persistence. Domain/ and Algorithms/ import NO Apple frameworks(Accelerate is allowed in Algorithms only).
Only Services/ and Persistence/ may import CoreMotion, AVFoundation,SwiftData, CryptoKit, or CommonCrypto.
No DSP, scoring, or baseline math in ViewModels or Views.
All baseline queries and scoring calls take an explicit TestMode parameter.
Persist metrics as JSON blobs; scalar columns only for queried fields(id, mode, startedAt, validity, relativeIndex, algorithmVersion).
No custom cryptography. AES-GCM via CryptoKit, PBKDF2 via CommonCrypto only.
User-facing copy says "gait consistency" — never "symmetry/asymmetry" forthe autocorrelation output (that term is reserved for the unilateralstep-time comparison).
Invalid/noisy sessions: never scored, never baseline-counted, never shownin history, never exported.
Project layout
Repo root contains CLAUDE.md, README.md, .gitignore, docs/.
Stabilyz/Stabilyz/ — app source code (all Swift files go here).
Stabilyz/StabilyzTests/ — unit tests.
Stabilyz/Stabilyz.xcodeproj — NEVER edit this file.
Build & test
From repo root:xcodebuild -scheme Stabilyz -destination 'platform=iOS Simulator,name=iPhone 16' test
If the simulator name fails, list available simulators withxcrun simctl list devices available and use one of those.
Run tests after every change. NEVER end a session with the build ortests broken.
New .swift files in the source/test folders should compile automatically(Xcode 16 synchronized folders). If a new file is not being compiled,ASK THE USER to add it to the target in Xcode — never edit .xcodeproj.
Workflow
One task per session, from the TDD's task breakdown (§23).
Write tests alongside implementation for anything in Domain/ orAlgorithms/ (pure Swift — no mocks needed).
Small commits, imperative messages ("Add TestMode domain model").
Do not modify docs/ or this file unless explicitly asked.
If a task is ambiguous or depends on an [OPEN] item, stop and ask.
