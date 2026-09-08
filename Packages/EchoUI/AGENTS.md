# EchoUI

SwiftUI only. Everything Echo puts on screen.

## The rule

The UI depends on the engine; the engine never depends on the UI. That direction
is enforced in `Packages/EchoEngine`, so the only way to break it here is to try
to make the engine call back into a view. Don't — read engine state, pass values
in.

No capture, transcription, summarization, model download or file layout in this
package. If a view needs work done, `EchoEngine` does it and the view shows the
result.

Targets default to `@MainActor` isolation, matching the app target. Anything that
should leave the main actor says so.

## Modules

| target | owns | depends on |
|---|---|---|
| `EchoDesignSystem` | colors, type, spacing, materials, shared controls | — |
| `EchoWorkspace` | the main window shell and navigation between surfaces | design system, engine |
| `EchoDocument` | one meeting: transcript, summary, live recording state | design system, engine |
| `EchoLibrary` | the list of past meetings: rows, selection, destructive actions | design system, engine |
| `EchoSearch` | search across meetings and the answer surface for one | design system, engine |
| `EchoIsland` | the floating panel and menu bar item for a detected call | design system, engine |
| `EchoOnboarding` | permissions, model download, the readiness gate | design system, engine |

The app target links the `EchoUI` product only, and reaches the engine through it.

## Where new code goes

- A view belongs to the surface it appears on.
- A control or token two surfaces share moves to `EchoDesignSystem`. Surfaces
  never import each other.
- Text on screen is English.
- Never fake audio: waveforms and levels come from real capture only.

Add a module only for a new surface. New target: `.swiftLanguageMode(.v6)`,
`.defaultIsolation(MainActor.self)`, a dependency on `EchoDesignSystem` and the
engine, a row in the table, and its name in the `EchoUI` product.
