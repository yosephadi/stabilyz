# Stabilyz — Technical Design Document

**iOS Application for Self-Directed Gait Stability Measurement in Prosthetic Limb Users**

**Status:** Draft v1.0 — for engineering implementation
**Source of truth:** *Stabilyz PRD (stabilyz-prd.md)*
**Target:** TestFlight, physical iPhone, iOS 17+

---

## Sections

1. [Product & Technical Context](01-product-technical-context.md)
2. [Recommended Architecture](02-recommended-architecture.md)
3. [Application Layer Architecture](03-application-layer-architecture.md)
4. [Feature Architecture](04-feature-architecture.md)
5. [Domain & Data Model](05-domain-data-model.md)
6. [Persistence Architecture](06-persistence-architecture.md)
7. [Motion & Sensor Architecture](07-motion-sensor-architecture.md)
8. [Signal Processing & Scoring Pipeline](08-signal-processing-scoring-pipeline.md)
9. [Baseline Architecture](09-baseline-architecture.md)
10. [Audio Feedback Architecture](10-audio-feedback-architecture.md)
11. [Navigation Architecture](11-navigation-architecture.md)
12. [Dependency Injection](12-dependency-injection.md)
13. [Data Export, Encryption & Restore Architecture](13-data-export-encryption-restore-architecture.md)
14. [Concurrency & Async Architecture](14-concurrency-async-architecture.md)
15. [Error Handling Strategy](15-error-handling-strategy.md)
16. [Project / Folder Structure](16-project-folder-structure.md)
17. [Technology Stack & Deployment Target](17-technology-stack-deployment-target.md)
18. [Security & Privacy Architecture](18-security-privacy-architecture.md)
19. [Testing Strategy](19-testing-strategy.md)
20. [Observability, Logging & Diagnostics](20-observability-logging-diagnostics.md)
21. [Technical Risks & Unknowns](21-technical-risks-unknowns.md)
22. [Recommended Implementation Order](22-recommended-implementation-order.md)
23. [Engineering Task Breakdown](23-engineering-task-breakdown.md)
24. [Architecture Decision Records](24-architecture-decision-records.md)
25. [Final Technical Blueprint](25-final-blueprint.md)

---

## Document Conventions

| Marker | Meaning |
|---|---|
| **[PRD]** | Directly required by the PRD — non-negotiable |
| **[REC]** | Technical recommendation / assumption where the PRD leaves implementation open |
| **[OPEN]** | Deliberately unresolved by the PRD — must not be silently closed by engineering |

The PRD references in this document use `PRD §n` for numbered PRD sections and `PRD OQ-n` for the resolved Open Questions at the end of the PRD.
