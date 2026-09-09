# CLAUDE.md — Stabilyz

iOS app for prosthetic limb users to self-measure walking stability. Local-only, offline, single-user. No backend, no accounts, no networking code, no third-party dependencies. iOS 17+, SwiftUI, SwiftData.

## Source of truth (read before coding)

- `docs/stabilyz-prd.md` — the product requirements. AUTHORITATIVE.
- `docs/README.md` — index of the 25-part technical design doc (TDD). The TDD lives in `docs/01-...` through `docs/25-...` — read the file(s) relevant to the current task before writing code.
- Never invent product features. Only build what the PRD/TDD specify.
- Markers: `[PRD]` = required, non-negotiable · `[REC]` = decided tech recommendation, follow it · `[OPEN]` = deliberately unresolved. NEVER silently resolve an `[OPEN]` item — use a clearly-labeled placeholder and flag it to the user instead.

## Hard architecture rules (`docs/03-application-layer-architecture.md` — violating these = redo)

- Layers: Presentation → Feature/State → Domain → Algorithms → Services → Persistence. `Domain/` and `Algorithms/` import NO Apple frameworks (Accelerate is allowed in `Algorithms/` only).
- Only `Services/` and `Persistence/` may import CoreMotion, AVFoundation, SwiftData, CryptoKit, or CommonCrypto.
- No DSP, scoring, or baseline math in ViewModels or Views.
- All baseline queries and scoring calls take an explicit `TestMode` parameter.
- Persist metrics as JSON blobs; scalar columns only for queried fields (`id`, `mode`, `startedAt`, `validity`, `relativeIndex`, `algorithmVersion`).
- No custom cryptography. AES-GCM via CryptoKit, PBKDF2 via CommonCrypto only.
- Default actor isolation is `nonisolated` — every `@Observable` view model must be explicitly `@MainActor`.
- User-facing copy says "gait consistency" — never "symmetry/asymmetry" for the autocorrelation output (that term is reserved for the unilateral step-time comparison).
- Invalid/noisy sessions: never scored, never baseline-counted, never shown in history, never exported.

## Project layout

- Repo root contains `CLAUDE.md`, `README.md`, `.gitignore`, `docs/`.
- `Stabilyz/Stabilyz/` — app source code (all Swift files go here), organized by layer per `docs/16-project-folder-structure.md`:
  - `App/` — entry point, composition root, router root.
  - `Features/` — one folder per feature.
  - `Domain/` — pure Swift, no Apple frameworks.
  - `Algorithms/` — pure Swift + Accelerate only.
  - `Services/` — protocol-fronted Apple framework adapters.
  - `Persistence/` — SwiftData entities, repositories, store container.
  - `DesignSystem/` — colors, typography, shared components, accessible styles.
  - `Utilities/` — Clock, FileIO, RandomSource, time anchors, extensions.
- `Stabilyz/StabilyzTests/` — unit tests.
- `Stabilyz/StabilyzUITests/` — UI tests.
- `Stabilyz/Stabilyz.xcodeproj` — NEVER edit this file.

## Build & test

- From repo root: `xcodebuild -scheme Stabilyz -destination 'platform=iOS Simulator,name=iPhone 17' test`
- If the simulator name fails, list available simulators with `xcrun simctl list devices available` and use one of those.
- Run tests after every change. NEVER end a session with the build or tests broken.
- New `.swift` files in the source/test folders should compile automatically (Xcode 16 synchronized folders). If a new file is not being compiled, ASK THE USER to add it to the target in Xcode — never edit `.xcodeproj`.

## Workflow

- One task per session, from `docs/23-engineering-task-breakdown.md`.
- Write tests alongside implementation for anything in `Domain/` or `Algorithms/` (pure Swift — no mocks needed).
- Small commits, imperative messages ("Add TestMode domain model").
- Do not modify `docs/` or this file unless explicitly asked.
- If a task is ambiguous or depends on an `[OPEN]` item, stop and ask.
