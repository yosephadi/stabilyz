# 3. Application Layer Architecture

```text
┌────────────────────────────────────────────────────────┐
│ Presentation — SwiftUI Views (render only)             │
├────────────────────────────────────────────────────────┤
│ Feature / State — @Observable ViewModels, Router       │
├────────────────────────────────────────────────────────┤
│ Domain — entities, baseline logic, validity rules,     │
│           scoring interfaces, error taxonomy           │
├────────────────────────────────────────────────────────┤
│ Algorithms (pure) — DSP, segmentation, features,       │
│           metrics, composite scoring (versioned)       │
├────────────────────────────────────────────────────────┤
│ Services — Motion, Pedometer, Audio, SecureArchive,    │
│           Export/Import, Logging (protocol-fronted)    │
├────────────────────────────────────────────────────────┤
│ Persistence — SwiftData models, repositories, mapping  │
├────────────────────────────────────────────────────────┤
│ Apple Frameworks — CoreMotion, AVFoundation, CryptoKit,│
│           CommonCrypto, SwiftData, Charts, Accelerate  │
└────────────────────────────────────────────────────────┘
```

| Layer | Responsibility | May depend on | Must NOT depend on | Examples |
|---|---|---|---|---|
| Presentation | Render state; forward user intents | Feature layer, DesignSystem | Domain internals, Services, Persistence | `ScoreScreen`, `RecordingView`, `OnboardingFieldView` |
| Feature / State | View state, navigation state, intent orchestration, error presentation | Domain, service **protocols**, DesignSystem | Concrete Apple framework types (except SwiftUI), raw sensor types | `SessionFlowViewModel`, `AppRouter`, `ScoreViewModel` |
| Domain | Entities, value types, session validity rules, baseline rules, scoring *contracts*, error taxonomy | Stdlib + Foundation | SwiftUI, CoreMotion, AVFoundation, SwiftData, CryptoKit, any service | `GaitSession`, `Baseline`, `TestMode`, `SessionValidity`, `GaitScoringAlgorithm` protocol |
| Algorithms | Pure computation: preprocessing, segmentation, quality, features, metrics, composite | Stdlib, Foundation, Accelerate/vDSP | SwiftUI, CoreMotion, SwiftData, AVFoundation, CryptoKit | `PreprocessingStage`, `WalkingSegmentDetector`, `AutocorrelationFeatures`, `CompositeScorer` |
| Services | Wrap Apple frameworks behind protocols; own hardware/lifecycle behavior | Domain, Algorithms (as inputs), Apple frameworks | Presentation, Feature, other Services (cross-talk via actors) | `CoreMotionSensorService`, `CMMotionPedometerService`, `AudioFeedbackService`, `SecureArchiveService` |
| Persistence | Store/fetch domain data; map entities↔domain; schema versioning | Domain, SwiftData | Presentation, Feature, Algorithms | `GaitSessionRepository`, `BaselineRepository`, `UserProfileRepository`, `StoreContainer` |
| Apple Frameworks | Platform capability | — | — | (the actual APIs) |

**Explicit boundary rules:**

1. `Algorithms` and `Domain` compile with **no Apple-framework imports except `Foundation`** (`Accelerate` additionally permitted in `Algorithms`) — this is what makes the gait science independently testable and evolvable. Foundation is admitted because the domain model in §5 is specified in terms of `Date`, `UUID` and `Duration`, which have no stdlib equivalents; the rule's intent is to exclude SwiftUI, CoreMotion, AVFoundation, SwiftData and CryptoKit, and that intent is unchanged.
2. Only `Services` and `Persistence` import CoreMotion / AVFoundation / SwiftData / CryptoKit.
3. `Presentation` never imports a Service or Persistence type.
4. Crossing layers uses domain value types or protocols — never leaks framework objects upward (e.g., a `CMSample`-like raw type from CoreMotion is converted to a domain `SensorSample` at the service boundary).
