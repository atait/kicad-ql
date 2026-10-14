# CLAUDE.md

macOS QuickLook preview and thumbnail extensions for KiCad `.kicad_pcb` files. They parse the board
file directly and draw it with CoreGraphics, with no dependency on KiCad. The goal is one
fit-to-window overview, not a faithful render: there is no zoom, no layer toggles and no text.

## Layout

- `KiCadPCBKit/`: Swift package. All parsing and drawing lives here, so it can be built and tested with
  plain `swift` and no Xcode.
  - `SExpr.swift`: byte-level S-expression parser. Atoms are kept as strings; numbers are parsed on demand.
  - `PCBBoard.swift`: walks the tree into per-layer `Shape`s, zone fills, vias and holes, in board mm (y down).
  - `Geometry.swift`: transforms, arcs from 3 points, pad outlines, gr_/fp_ graphics.
  - `PCBRenderer.swift`: draws a `PCBBoard` fitted into a rect of a y-up `CGContext`.
  - `Sources/kiql-render`: CLI that renders a board to PNG for checking renderer changes.
- `KiCadQL.xcodeproj`: host app `KiCadQL/` embeds `KiCadQLPreview/` (data-based `QLPreviewProvider`)
  and `KiCadQLThumbnail/` (`QLThumbnailProvider`). Both extensions link the local `KiCadPCBKit` package.
  The project uses file-system-synchronized folders, so new `.swift` files in those folders are picked
  up automatically.
- `examples/`: real boards (KiCad 7 and KiCad 10 formats), used by the tests.
- `brainstorm/`: original prototype. It is gitignored and should not be committed.

## Commands

```sh
swift build --package-path KiCadPCBKit
swift test  --package-path KiCadPCBKit
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200
# build the app without a signing team (ad-hoc), to check that it compiles:
xcodebuild -project KiCadQL.xcodeproj -scheme KiCadQL -derivedDataPath /tmp/kiql-dd \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build
qlmanage -r && qlmanage -r cache        # reset QuickLook after installing a new build
qlmanage -p examples/LoomRide-v1.kicad_pcb       # preview from the terminal
qlmanage -t -s 512 -o /tmp examples/LoomRide-v1.kicad_pcb   # thumbnail to a file
pluginkit -mv -p com.apple.quicklook.preview | grep -i kicad   # is the extension registered?
```

After a renderer change, render both examples with `kiql-render` and look at the PNGs.

## Conventions and gotchas

- The user is new to Swift and Xcode. When a change needs an Xcode GUI step, explain it explicitly,
  and keep `docs/XCODE.md` up to date.
- `project.pbxproj` was written by hand (objectVersion 77). Bundle IDs derive from the project-level
  `BUNDLE_ID_PREFIX` build setting.
- Prefer editing `project.pbxproj` only for small, well-understood changes. For anything else, describe
  the change for the user to make in Xcode.
- macOS has no system UTI for `.kicad_pcb`, and KiCad.app does not declare one. The host app's
  `Info.plist` imports `org.kicad.pcb` (the `UTImportedTypeDeclarations` key). Both extensions list
  that identifier in `QLSupportedContentTypes`. If you change it, change it in all three places.
- Extensions must stay sandboxed. QuickLook grants read access to the file being previewed.
- KiCad file format differences to keep handling: `module` (v5) vs `footprint`; `(width)` vs
  `(stroke (width))`; `(fill solid|none)` (v7–8) vs `(fill yes|no)` (v9+); layer numbering changed in v9+.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
