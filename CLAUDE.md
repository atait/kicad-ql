# CLAUDE.md

A macOS QuickLook preview extension for KiCad `.kicad_pcb` files. It parses the board
file directly and draws it with CoreGraphics, with no dependency on KiCad. The goal is one
fit-to-window overview, not a faithful render: there is no zoom, and the only controls are the layer legend
and the back-view toggle.

## Layout

- `KiCadPCBKit/`: Swift package. All parsing and drawing lives here, so it can be built and tested with
  plain `swift` and no Xcode.
  - `SExpr.swift`: byte-level S-expression parser. Atoms are kept as strings; numbers are parsed on demand.
  - `PCBBoard.swift`: walks the tree into per-layer `Shape`s, zone fills, vias and holes, in board mm (y down).
  - `Geometry.swift`: transforms, arcs from 3 points, pad outlines, gr_/fp_ graphics.
  - `Text.swift`: gr_text, fp_text and footprint `property` text as glyph outlines (system font
    standing in for KiCad's stroke font; cap height = text size). Hidden text is skipped, footprint
    text is kept upright, `${REFERENCE}`/`${VALUE}` are substituted, and `mirror` is honoured.
  - `PCBRenderer.swift`: draws a `PCBBoard` fitted into a rect of a y-up `CGContext`, either as the
    overview or with one layer in focus.
    - Overview order: B.SilkS (yellowish) → copper back to front (translucent) → vias → holes →
      F.SilkS (off-white, translucent) → Edge.Cuts. Copper zone fills are the layer colour, a little
      desaturated and translucent, so tracks stand out on them.
    - `focus: layer`: every other layer is drawn in flat grey at 25% opacity, then the focused layer is
      drawn opaque on top. Silkscreen gets a dark edge, so it reads over the light background. Vias are
      treated as copper. Holes and Edge.Cuts always go last.
    - `fromBack: true` mirrors x and reverses the stacking (B.SilkS nearest, F.SilkS furthest), in the
      overview and in focus mode. Colours keep their physical meaning. Back silkscreen text, which KiCad
      stores mirrored, then reads correctly.
    - `layers(of:)` lists the layers that can be focused, front to back. `color(of:)` gives each one's
      colour, for the legend.
  - `Sources/kiql-render`: CLI that renders a board to PNG for checking renderer changes.
- `KiCadQL.xcodeproj`: host app `KiCadQL/` embeds `KiCadQLPreview/`, which links the local
  `KiCadPCBKit` package. The extension is **view-based** (`QLIsDataBasedPreview` = NO):
  `PreviewViewController` hosts `BoardView`, which redraws with `PCBRenderer` and cross-fades (0.07 s) on a
  focus or side change, and `LegendView`, an `NSVisualEffectView` with one toggle per layer (nearest the
  viewer first) and a "View from back" toggle that also reverses the list. The legend is
  hidden below 300×220 pt, and the board is fitted so that it stays clear of the legend. Clicks and
  hover reach the view in the Finder spacebar panel, `qlmanage -p` and the column-view preview pane;
  keyboard input does not, because QuickLook keeps the keys. Use colours that adapt to Light and Dark
  Mode (e.g. `NSVisualEffectView`). A `cgColor` taken once at setup stays fixed and can end up white
  on white in Dark Mode. There is deliberately no thumbnail extension: Finder
  icons were too small to be useful, so it was removed.
  The project uses file-system-synchronized folders, so new `.swift` files in those folders are picked
  up automatically.
- `examples/`: real boards (KiCad 7 and KiCad 10 formats; `LSHM-2-Dsub-v2` has 4 copper layers), used
  by the tests.
- `brainstorm/`: original prototype. It is gitignored and should not be committed.

## Commands

```sh
swift build --package-path KiCadPCBKit
swift test  --package-path KiCadPCBKit
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200 --focus B.SilkS
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200 --back
# build the app without a signing team (ad-hoc), to check that it compiles:
xcodebuild -project KiCadQL.xcodeproj -scheme KiCadQL -derivedDataPath /tmp/kiql-dd \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build
qlmanage -r && qlmanage -r cache        # reset QuickLook after installing a new build
qlmanage -p examples/LoomRide-v1.kicad_pcb       # preview from the terminal
pluginkit -mv -p com.apple.quicklook.preview | grep -i kicad   # is the extension registered?
```

After a renderer change, render both examples with `kiql-render`, both the overview and each `--focus`
layer, from the front and with `--back`, and look at the PNGs.

## Conventions and gotchas

- The user is new to Swift and Xcode. When a change needs an Xcode GUI step, explain it explicitly,
  and keep `docs/XCODE.md` up to date.
- `project.pbxproj` was written by hand (objectVersion 77). Bundle IDs derive from the project-level
  `BUNDLE_ID_PREFIX` build setting.
- Prefer editing `project.pbxproj` only for small, well-understood changes. For anything else, describe
  the change for the user to make in Xcode.
- macOS has no system UTI for `.kicad_pcb`, and KiCad.app does not declare one. The host app's
  `Info.plist` imports `org.kicad.pcb` (the `UTImportedTypeDeclarations` key). The extension lists
  that identifier in `QLSupportedContentTypes`. If you change it, change it in both places.
- The extension must stay sandboxed. QuickLook grants read access to the file being previewed.
- KiCad file format differences to keep handling: `module` (v5) vs `footprint`; `(width)` vs
  `(stroke (width))`; `(fill solid|none)` (v7–8) vs `(fill yes|no)` (v9+); layer numbering changed in v9+.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
