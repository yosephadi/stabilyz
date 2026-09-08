# 17. Technology Stack & Deployment Target

| Item | Choice | Notes |
|---|---|---|
| Minimum iOS | **17.0** [PRD §7] | Enables `@Observable`, SwiftData, modern Charts APIs |
| Swift | 5.10+ toolchain; **strict concurrency checking enabled from day one**, Swift 6 language mode adopted when stable [REC] | PRD concurrency posture demands early data-race safety |
| UI | SwiftUI + Observation | |
| Persistence | SwiftData | §6 |
| Charts | Swift Charts | Trend lines [PRD §5] |
| Sensors | Core Motion (CMMotionManager, CMPedometer, CMMotionActivityManager [REC]) | §7 |
| DSP | Accelerate / vDSP | Filtering + autocorrelation; justified: hand-rolled FFT/convolution in pure Swift would be slower and riskier; Apple-native |
| Audio | AVFoundation / AVAudioEngine | §10 |
| Crypto | **CryptoKit (AES-GCM) + CommonCrypto (PBKDF2)** | §13; both platform-vetted [PRD: vetted platform crypto only] |
| Files | FileManager, UniformTypeIdentifiers, SwiftUI fileImporter / share sheet | |
| Logging | os (Logger + OSSignposter) | §20 |
| Testing | XCTest, XCUITest | §19 |
| SPM (external) | **None** | |

**Third-party dependencies: none.** Justification per the required framing: every needed capability (UI, persistence, charts, sensors, DSP, audio, AEAD, PBKDF2, file exchange, logging, testing) has a sufficient, Apple-supported implementation. Each external package would add supply-chain risk, App-Store-review surface, and binary bloat with no capability gap closed. (The one place a third-party library is often suggested — Argon2 — is unnecessary: PBKDF2-HMAC-SHA256 with per-export salt and calibrated iterations is a PRD-sanctioned option available via CommonCrypto.)
