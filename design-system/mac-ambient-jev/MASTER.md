# Mac Ambient Jev — UI Design System

Source guidance: [UI/UX Pro Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)

This file is the project-wide UI source of truth. Page-specific exceptions must be documented under `design-system/mac-ambient-jev/pages/`.

## Product model

Primary product category: **Voice Recorder & Memo**.
Secondary product category: **Productivity Tool**.

The interface is a macOS-native transcription utility. The main task is starting or importing a recording and reading the transcript with minimal interruption.

## Visual direction

Use **Minimalism & Swiss Style** as the base visual language, with only restrained **AI-Native UI** behavior where semantic processing needs to be visible.

- Prefer native macOS controls, materials, typography, spacing, toolbar placement, and window behavior.
- Do not imitate a web dashboard when a standard macOS pattern exists.
- Keep one visually primary action per screen.
- Avoid decorative gradients, ornamental glass effects, oversized cards, emoji icons, and unnecessary animation.
- Use SF Symbols consistently for structural icons.

## Typography

Use the macOS system type system instead of bundling Inter or another web font.

- Titles: system title/headline roles.
- Body: system body role.
- Metadata and timestamps: system caption roles; timers use monospaced digits.
- Do not encode hierarchy with color alone.
- Prefer wrapping to truncation for transcript content.

This platform-native choice overrides the web-font recommendation from the generic product dataset because Japanese text quality, Dynamic Type behavior, and macOS consistency are higher priorities.

## Color

Use semantic system colors in implementation rather than hard-coded palette values.

Product semantics derived from the Voice Recorder & Memo profile:

- Recording: red, only for recording state and the recording control.
- Waveform/transcription accent: app accent color.
- Primary text: `Color.primary`.
- Secondary metadata: `Color.secondary`.
- Background/surfaces/borders: system materials and separators.
- Error: system red plus text/icon; never red alone.
- Warning: system orange plus text/icon.

Light and dark mode must both remain legible. Do not invert a fixed light palette for dark mode.

## Spacing and sizing

Use a 4/8pt rhythm.

- xs: 4
- sm: 8
- md: 12
- lg: 16
- xl: 24
- xxl: 32

Interactive controls must retain comfortable macOS hit regions; icon-only controls require accessible labels.

## Core screen hierarchy

### Live transcription

1. Window toolbar: import as secondary action, recording as the primary action.
2. Compact status region: capture/processing state and any actionable warning.
3. Transcript: dominant content area.
4. Transcript metadata: timestamp, speaker, and semantic state shown with text plus visual styling.
5. Diagnostics and settings are secondary destinations, not mixed into the transcript flow.

## Interaction rules

- Use native `Button`, `Toggle`, `NavigationSplitView`, `List`, `ScrollView`, and toolbar APIs.
- Async controls must expose loading/disabled state.
- Preserve keyboard navigation and visible focus.
- Never rely on hover for an essential action.
- Auto-follow may animate only when Reduce Motion is off.
- Scrolling the transcript pauses auto-follow; a visible button restores it.
- Low-priority transcript content remains readable and is explicitly labeled instead of being indicated only by reduced opacity.
- Errors are displayed close to the affected action/state and use concrete Japanese wording.

## Accessibility requirements

- Normal text contrast target: WCAG AA 4.5:1 or platform semantic colors that preserve equivalent legibility.
- All icon buttons have accessible text labels.
- Recording, warning, failure, and low-priority states use text/icon semantics in addition to color.
- Respect Reduce Motion.
- Preserve text selection in transcript rows.
- Test keyboard-only operation and VoiceOver ordering before V1 acceptance.

## Motion

Motion is functional, not decorative.

- State transitions: use SwiftUI state animation only when it clarifies continuity.
- Transcript auto-scroll: animated only when Reduce Motion is disabled.
- No looping decorative motion.
- No geometry-changing press animation that shifts surrounding layout.

## Anti-patterns

Do not introduce:

- emoji as navigation/status icons;
- custom fonts solely for branding;
- arbitrary hexadecimal colors inside views;
- low-contrast gray transcript text;
- opacity-only semantic states;
- multiple equally prominent CTAs;
- web-style card grids for ordinary macOS settings;
- custom controls where native SwiftUI controls provide the required behavior.
