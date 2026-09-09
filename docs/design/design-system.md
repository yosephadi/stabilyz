# Stabilyz — Design System

*Simple, clean, minimalist. Built for a user base spanning young adults to
users in their 70s+ — clarity and legibility outrank visual flourish
everywhere in this document.*

---

## 1. Principles

- **Calm, not clinical-cold.** Deep navy reads as trustworthy and precise
  without feeling like a hospital app.
- **One number, clearly.** The stability score is the product. Every
  screen that shows it should let it dominate — minimal chrome around it.
- **No decoration without function.** No gradients, no drop shadows, no
  icons that don't map to a real action or state.
- **Same shape, every screen.** Reuse a small set of components (card,
  primary button, list row) rather than one-off layouts, so a
  non-tech-savvy user builds muscle memory fast.

---

## 2. Color

### 2.1 Primary — deep-trust navy

| Token | Hex | Use |
|---|---|---|
| `primary-900` | `#0A1F3D` | Pressed states, high-emphasis text on light bg |
| `primary-700` | `#123A66` | Headers, nav bar (dark mode surface) |
| `primary-600` | `#1B4F8C` | **Brand color** — primary buttons, active states, links |
| `primary-500` | `#2E6BAE` | Secondary emphasis, icons |
| `primary-300` | `#8FB4D6` | Disabled-but-visible states, chart gridlines |
| `primary-100` | `#D9E6F2` | Selected-row fill, subtle highlight |
| `primary-50`  | `#F0F5FA` | Card fill on light backgrounds |

### 2.2 Neutrals

| Token | Hex (light) | Hex (dark) | Use |
|---|---|---|---|
| `ink-900` | `#14181F` | `#F2F3F5` | Primary text |
| `ink-600` | `#4B5563` | `#B8BEC7` | Secondary text |
| `ink-400` | `#8A909B` | `#7A828E` | Placeholder, disabled text |
| `ink-200` | `#DDE0E4` | `#2A2F37` | Dividers, borders |
| `ink-100` | `#EEF0F2` | `#1C2027` | Subtle fills |
| `bg-base` | `#FFFFFF` | `#0D1117` | Screen background |
| `bg-elevated` | `#FFFFFF` | `#161B22` | Cards, sheets |

### 2.3 Semantic (system states — kept separate from score color)

Score trend visualization stays **monochrome blue** (see 2.4) — these
semantic colors are reserved for system-level states only (permissions,
destructive confirmations, noisy-session warnings), so they never compete
visually with the score itself.

| Token | Hex | Use |
|---|---|---|
| `warning` | `#B7791B` | Noisy/insufficient-data screen, non-blocking alerts |
| `danger` | `#B3261E` | "Replace with Backup" destructive confirm, permission-denied state |

**Resolved (2026-09-10):** the amber/red pair stays exactly as specified.
Amber carries noisy sessions and other non-blocking alerts; red is
reserved for destructive confirmations and the permission-denied state,
and appears nowhere else. The monochrome call in §2.4 governs **score
rendering only** — a score is a relative index against the user's own
baseline, never a pass or a fail, so it must never be tinted with the
colors this app uses for "something went wrong". Keeping the two
vocabularies separate is what lets red mean *destructive* everywhere it
appears, which is the iOS convention this user base already reads
fluently.

### 2.4 Score color scale (monochrome, no green/red)

Relative index encoded by **saturation and value only**, not hue:

| Relative index | Token | Hex |
|---|---|---|
| ≥ 115 (notably above baseline) | `score-strong` | `#0A1F3D` |
| 105–114 | `score-good` | `#1B4F8C` |
| 95–104 (near baseline) | `score-neutral` | `#6B84A0` |
| 85–94 | `score-soft` | `#A9BDD2` |
| < 85 (notably below baseline) | `score-low` | `#D3DEEA` with `ink-900` numeral, not a hue change |

Direction (up/down vs. baseline) is communicated with an ↑/↓ glyph and
copy ("+8 vs your baseline"), never with color alone.

---

## 3. Typography

**SF Pro**, non-italic, Medium and Bold only, 15pt minimum per HIG.

| Style | Size | Weight | Use |
|---|---|---|---|
| Heading | 34px | Bold | Screen titles (Home score, onboarding field) |
| Subheading Bold | 28px | Bold | Section titles |
| Subheading Reg | 28px | Medium | Large numerals (e.g. score) when Bold is too heavy |
| Subheading 2 Bold | 20px | Bold | Card titles, list section headers |
| Subheading 2 Reg | 20px | Medium | Card titles, less emphasis |
| Body Text Bold | 17px | Bold | Emphasized body copy, button labels |
| Body Text Regular | 17px | Medium | Default body copy |
| Small Body Text Bold | 15px | Bold | Metadata labels, timestamps (bold) |
| Small Body Text Regular | 15px | Medium | Metadata, captions, footnotes — **floor size** |

Never go below 15px. Never use SF Pro's italic styles.

---

## 4. Layout & spacing

4pt base grid.

| Token | Value | Use |
|---|---|---|
| `space-1` | 4px | Icon-to-label gap |
| `space-2` | 8px | Tight internal padding |
| `space-3` | 12px | Default internal card padding (compact) |
| `space-4` | 16px | Standard internal padding, gap between related elements |
| `space-6` | 24px | Card padding (default), gap between unrelated groups |
| `space-8` | 32px | Section spacing |
| `space-12` | 48px | Major screen-section breaks |

- Screen margins: 20px left/right (standard iOS safe-area default).
- Minimum tap target: 44×44pt (HIG), non-negotiable given the user base
  skews toward less tech-savvy, older users.
- Corner radius: `8px` for buttons/inputs, `16px` for cards, `24px` for
  sheets/modals. No sharp corners anywhere.
- Elevation: **no drop shadows.** Separate surfaces with a 1px
  `ink-200` / `ink-200`(dark) hairline border or a subtle `bg-elevated`
  fill contrast instead.

---

## 5. Components

**Native only.** Every control below maps to a stock SwiftUI/UIKit
component with our color and type tokens applied — nothing is
custom-drawn. Given how much this user base already relies on system
conventions (§9), staying inside standard iOS controls buys familiarity
for free and keeps VoiceOver/Dynamic Type support correct without extra
work.

### Navigation
- `NavigationStack` throughout, system **Large Title** style for screen
  titles — this already renders at 34pt Bold, so it maps directly onto
  the Heading style in §3 with zero custom type work.
- `TabView` with SF Symbols for the top-level destinations (Home,
  History, Settings) — a native iOS tab bar rather than a custom
  dashboard-button layout. Selected tab tinted `primary-600`.

### Buttons
- **Primary**: `Button` with `.buttonStyle(.borderedProminent)`,
  `.tint(primary-600)`, `.controlSize(.large)`. Label uses the system
  button font (aligns with Body Text Bold).
- **Secondary**: `.buttonStyle(.bordered)`, `.tint(primary-600)`.
- **Destructive**: `.buttonStyle(.bordered)` or plain, `.tint(danger)` —
  reserved for "Replace with Backup" and similar irreversible actions,
  and for the native `role: .destructive` on any `Button`/`.alert`
  action so iOS applies its standard destructive styling automatically.
- Disabled state uses the system's automatic disabled dimming — no
  custom disabled-color override needed.

### Grouped content (Settings, History, session detail)
Native `List` with `.listStyle(.insetGrouped)` — this is the iOS
equivalent of a "card": system-provided fill, corner radius, and row
dividers already match §4's radius/spacing intent, so no custom card
view is built. Row height follows the system default (already ≥44pt).

### Toggles (Step Feedback, Metronome cue)
Native `Toggle`, `.tint(primary-600)`.

### Segmented / closed-choice inputs (Test Mode, onboarding fields)
Native `Picker` with `.pickerStyle(.segmented)` for 2–3 options (Quick
Test / Full Test), or `Picker` with `.pickerStyle(.inline)` inside a
`List` row for longer closed-choice fields (amputation level, side).
Never a custom dropdown.

### Destructive confirmations (restore-overwrite flow)
Native `.confirmationDialog` (action sheet) for
Cancel / Export current data first / Replace with backup — this is the
exact iOS pattern for a destructive multi-choice decision, so it's used
as-is rather than a custom modal.

### System permission (Motion & Fitness)
Rely entirely on the native iOS permission prompt; a plain-text
pre-permission explanation screen (system `Text`, no custom illustration
required) precedes it if the app needs to explain *why* before asking.

### Score display (Home / Score Screen)
The one place layout is still bespoke, because there's no native
"hero metric" component — but it's built from native `Text` views only
(`.font(.system(size: 34, weight: .bold))` etc., per §3), colored per
§2.4, centered, with the baseline comparison in Small Body Text Regular
directly beneath. No card/border around it — sits directly on
`bg-base` so it reads as the page's primary content.

---

## 6. Charts (Session History & Trend)

Built with **Swift Charts** (already the PRD's stated choice).

- `AreaMark` for the filled region under the trend line, `primary-600`
  at ~15% opacity in light mode / ~25% in dark mode (flat fill, no
  gradient — stays consistent with the no-gradients principle in §1).
- `LineMark` drawn on top of the same data, 2pt stroke, solid
  `primary-600`.
- Optional `PointMark` at each session, small filled circle colored per
  the §2.4 score scale, so an individual session's relative strength is
  still visible at a glance even though the line/fill stay monochrome.
- Gridlines: `primary-300` (light) / a dimmed `primary-300` (dark),
  thin, no axis border box.
- Quick Test vs. Full Test split via the same native segmented `Picker`
  used for mode selection elsewhere — switching modes swaps the chart's
  data source, not its visual style.
- Baseline reference line (once established): a thin dashed
  `RuleMark` at the baseline value, labeled "baseline" in Small Body
  Text Regular.

---

## 7. Iconography

- SF Symbols only — matches the SF Pro type family and stays visually
  consistent with the rest of iOS, which matters for a less tech-savvy
  user base already familiar with system conventions.
- Weight: Regular or Medium, matched to nearby text weight.
- Color: `ink-600` for neutral/utility icons, `primary-600` for
  interactive/active icons. Never decorative — every icon maps to a
  real action or state.

---

## 8. Dark mode

Navy is already dark-leaning, so dark mode mostly inverts the neutral
scale rather than the brand color:

- `bg-base` → `#0D1117`, `bg-elevated` → `#161B22`
- `primary-600` stays the interactive brand color in both modes; use
  `primary-300` instead of `primary-600` for large filled areas in dark
  mode (a full `primary-900` fill on a near-black background loses
  contrast against `bg-base`).
- Score scale (§2.4) inverts value direction: lighter blues read as
  "stronger" against a dark background, so swap `score-strong` and
  `score-low` hex pairs between modes rather than reusing the light-mode
  scale as-is.
- Never rely on pure black (`#000000`) — `#0D1117` keeps enough warmth to
  avoid OLED smearing and matches iOS system dark surfaces.

---

## 9. Accessibility

- Dynamic Type: support up to at least Accessibility Large — the score
  numeral and onboarding labels are the highest-priority elements to
  scale correctly.
- Contrast: `ink-900` on `bg-base` and `primary-600` on white both clear
  WCAG AA (4.5:1) at Body Text size; verify `score-neutral` /
  `score-soft` against `bg-base` specifically, since those are the two
  lowest-contrast score tokens.
- Never encode information by color alone (see §2.4 — the ↑/↓ glyph and
  numeral comparison carry the meaning, color reinforces it).
- VoiceOver: score numeral should announce as "Stability score 112,
  8 points above your baseline," not just the bare number.

---

## Open questions

- **App icon / launch screen concept** — deferred, revisit later.
- **Empty states** — Home before any sessions exist, History with zero
  sessions in a mode — still open. You mentioned possibly using
  illustration here; once you've thought it through, this section
  should get a short spec (illustration style, copy, and how it differs
  from the noisy-session state) rather than being left as a generic
  placeholder.
