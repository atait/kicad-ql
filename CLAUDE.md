# CLAUDE.md

A macOS QuickLook preview extension for KiCad `.kicad_pcb` boards and `.kicad_sch` schematics. It
parses the file directly and draws it with CoreGraphics, with no dependency on KiCad. The goal is a
fit-to-window overview that can be zoomed (pinch, or a mouse wheel) and panned (two-finger scroll), not
a faithful render. Boards also have the layer legend and the back-view toggle.

## Layout

- `KiCadPCBKit/`: Swift package. All parsing and drawing lives here, so it can be built and tested with
  plain `swift` and no Xcode.
  - `SExpr.swift`: byte-level S-expression parser. Atoms are kept as strings; numbers are parsed on demand.
  - `PCBBoard.swift`: walks the tree into per-layer `Shape`s, zone fills, vias and holes, in board mm (y down).
  - `Geometry.swift`: transforms, arcs from 3 points, pad outlines, gr_/fp_ graphics.
  - `Text.swift`: text as glyph outlines (system font standing in for KiCad's stroke font; cap
    height = text size), shared by boards and schematics. For boards: gr_text, fp_text and footprint
    `property`. Hidden text is skipped, footprint text is kept upright, `${REFERENCE}`/`${VALUE}` are
    substituted, and `mirror` is honoured. `textExtent` measures text the same way, for label outlines.
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
    - `zoom:` is how much the caller has already scaled the context, so the outline stays thin.
  - `Schematic.swift`: one sheet of a `.kicad_sch` as shapes in sheet mm (y down), each tagged with a
    `Kind` that sets its colour and drawing order. Covers placed symbols from `lib_symbols` (library
    coordinates are **y up**: flip y, rotate, mirror, translate; unit 0 plus the placed unit), pins with
    names and numbers, visible fields, wires, buses, bus entries, junctions, no-connects, local/global/
    hierarchical labels, sheets with their pins, notes, graphics, and the default page frame and title
    block (paper size from `(paper …)`).
    - Placed-symbol fields are stored unrotated. Their text box is turned about the field position as
      the symbol is, and the text is drawn centred in it, horizontal or vertical (as KiCad does).
    - References come from `(instances … (path "<instancePath>" (reference …)))`. A root sheet uses
      `/<its uuid>`; a sub-sheet opened from it uses `/<root uuid>/<sheet uuid>`.
    - Sub-sheets live in other files. `sheets` lists them; they are only opened on request.
    - Not drawn: images, netclass flags, rule areas, `${…}` fields (removed), most pin decorations
      (only inverted and clock).
  - `SchematicRenderer.swift`: KiCad's default colours on the paper colour; skips items off-screen and
    keeps lines at least a hairline wide whatever the zoom. `pageTransform` maps sheet mm to the view,
    for hit-testing.
  - `Sources/kiql-render`: CLI that renders a board or schematic to PNG for checking renderer changes.
    `--zoom Z --at X,Y` renders a zoomed-in crop; `--sheet NAME` renders a sub-sheet.
- `KiCadQL.xcodeproj`: host app `KiCadQL/` embeds `KiCadQLPreview/`, which links the local
  `KiCadPCBKit` package. The extension is **view-based** (`QLIsDataBasedPreview` = NO).
  `ZoomPanView` holds the zoom (1 = fitted, up to 40) and offset. It handles `magnify`, `scrollWheel`
  (precise deltas pan, a mouse wheel zooms), and `smartMagnify` and double-click (back to fit), and
  subclasses redraw vector content through `zoomTransform`. For a board, `PreviewViewController` hosts
  `BoardView` (a `ZoomPanView`), which redraws with `PCBRenderer` and cross-fades (0.07 s) on a
  focus or side change, and `LegendView`, an `NSVisualEffectView` with one toggle per layer (nearest the
  viewer first) and a "View from back" toggle that also reverses the list. The legend is
  hidden below 300×220 pt, and the board is fitted so that it stays clear of the legend. Flipping to
  the back resets the zoom. For a schematic it hosts `SchematicView` (a `ZoomPanView`) and `SheetBar`.
  Double-clicking a sheet box tries to open that file. The sandbox normally refuses, and `SheetBar`
  says so for a few seconds; when it works, `SheetBar` shows a back button. Clicks and hover reach the
  view in the Finder spacebar panel, `qlmanage -p` and the column-view preview pane (pinch and scroll
  are expected to as well, but that hasn't been confirmed in QuickLook yet). Keyboard input does not,
  because QuickLook keeps the keys. Use colours that adapt to Light and Dark
  Mode (e.g. `NSVisualEffectView`). A `cgColor` taken once at setup stays fixed and can end up white
  on white in Dark Mode. There is deliberately no thumbnail extension: Finder
  icons were too small to be useful, so it was removed.
  The project uses file-system-synchronized folders, so new `.swift` files in those folders are picked
  up automatically.
- `examples/`: real boards (KiCad 7 and KiCad 10 formats; `LSHM-2-Dsub-v2` has 4 copper layers) and
  schematics (KiCad 10; `SkySense-bank` has eight sub-sheets of `SkyKey-AT42QT1011`), used by the
  tests.
- `brainstorm/`: original prototype. It is gitignored and should not be committed.

## Commands

```sh
swift build --package-path KiCadPCBKit
swift test  --package-path KiCadPCBKit
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200 --focus B.SilkS
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200 --back
swift run -c release --package-path KiCadPCBKit kiql-render examples/SkySense-bank.kicad_sch out.png 2000
swift run -c release --package-path KiCadPCBKit kiql-render examples/SkySense-bank.kicad_sch out.png 1400 --zoom 7 --at 55,45
swift run -c release --package-path KiCadPCBKit kiql-render examples/SkySense-bank.kicad_sch out.png 2000 --sheet ssen3
/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli sch export svg -o outdir file.kicad_sch   # KiCad's own picture
# build the app without a signing team (ad-hoc), to check that it compiles:
xcodebuild -project KiCadQL.xcodeproj -scheme KiCadQL -derivedDataPath /tmp/kiql-dd \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build
qlmanage -r && qlmanage -r cache        # reset QuickLook after installing a new build
qlmanage -p examples/LoomRide-v1.kicad_pcb       # preview from the terminal
pluginkit -mv -p com.apple.quicklook.preview | grep -i kicad   # is the extension registered?
```

After a board renderer change, render the board examples with `kiql-render`, both the overview and each
`--focus` layer, from the front and with `--back`, and look at the PNGs. After a schematic change,
render both `.kicad_sch` examples (a whole page, and a `--zoom` crop) and compare them with KiCad's own
SVG, exported with `kicad-cli` into a scratch directory (not `examples/`).

## Conventions and gotchas

- The user is new to Swift and Xcode. When a change needs an Xcode GUI step, explain it explicitly,
  and keep `docs/XCODE.md` up to date.
- `project.pbxproj` was written by hand (objectVersion 77). Bundle IDs derive from the project-level
  `BUNDLE_ID_PREFIX` build setting.
- Prefer editing `project.pbxproj` only for small, well-understood changes. For anything else, describe
  the change for the user to make in Xcode.
- macOS has no system UTI for `.kicad_pcb` or `.kicad_sch`, and KiCad.app does not declare one. The
  host app's `Info.plist` imports `org.kicad.pcb` and `org.kicad.sch` (the `UTImportedTypeDeclarations`
  key). The extension lists those identifiers in `QLSupportedContentTypes`. If you change one, change it
  in both places.
- The extension must stay sandboxed. QuickLook grants read access to the file being previewed, and only
  to that file, so sub-sheets in other files normally can't be opened from a preview. We chose this
  over a temporary-exception entitlement.
- Board file format differences to keep handling: `module` (v5) vs `footprint`; `(width)` vs
  `(stroke (width))`; `(fill solid|none)` (v7–8) vs `(fill yes|no)` (v9+); layer numbering changed in v9+.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
