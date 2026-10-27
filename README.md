# KiCad QuickLook

A macOS QuickLook extension for KiCad boards (`.kicad_pcb`) and schematics (`.kicad_sch`). Press
Space on a file in Finder and you get a fit-to-window overview. **Pinch to zoom** and **scroll with two
fingers to pan**. A mouse wheel also zooms. Double-click, or double-tap with two fingers, to fit the
picture to the window again. KiCad does not need to be installed or running, because the files are
parsed and drawn directly.

**Boards:** a legend in the corner lists the copper and silkscreen layers. Click a layer to bring it to
the front, with the rest faded, and click it again to go back to the overview. **View from back** shows
the board as seen from the bottom: mirrored, with the back layers on top, and with the same colours
(B.Cu stays blue). The preview draws copper (tracks, pads, zone fills), vias, holes, front and back
silkscreen (including visible text) and the board outline.

**Schematics:** the sheet is drawn in KiCad's default colours, with its page frame and title block. That
includes symbols with their pins and fields, wires, buses, junctions, labels, notes, and hierarchical
sheet boxes with their pins. Zoom in to read small text: it is redrawn sharp at every zoom level. Only the
previewed file is shown. QuickLook may not read other files, so a sub-sheet can't be opened from its
box. Preview the sub-sheet's own file instead.

Both are overviews, not replacements for KiCad. Text uses the system font rather than KiCad's stroke
font.

## Layout

| Path | What it is |
| --- | --- |
| `KiCadPCBKit/` | Swift package: S-expression parser, board and schematic models, CoreGraphics renderers, `kiql-render` CLI, tests |
| `KiCadQL.xcodeproj` | Xcode project: host app plus the Preview extension |
| `KiCadQL/` | Host app. It exists to carry the extension and declare the `.kicad_pcb` and `.kicad_sch` file types |
| `KiCadQLPreview/` | QuickLook preview extension (spacebar) |
| `examples/` | Sample boards and schematics for testing |
| `docs/XCODE.md` | Step-by-step guide for building and installing with Xcode |

## Try the renderer without Xcode

```sh
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200
swift run -c release --package-path KiCadPCBKit kiql-render examples/SkySense-bank.kicad_sch out.png 2000
swift run -c release --package-path KiCadPCBKit kiql-render examples/SkySense-bank.kicad_sch out.png 2000 --sheet ssen3
swift test --package-path KiCadPCBKit
```

## Build the QuickLook extension

See [docs/XCODE.md](docs/XCODE.md).

## Sharing

`KiCadQL.app` can be zipped and sent to someone else (Finder ▸ Compress, or
`ditto -c -k --keepParent KiCadQL.app KiCadQL.zip`), but how smoothly it opens depends on how it was
signed. Export it with Product ▸ Archive so it is a Release build, which runs on both Apple Silicon
and Intel Macs. The recipient needs macOS 14 or later.

**Signed with a free Apple ID ("Personal Team")**: Gatekeeper rejects it on other Macs, because an
*Apple Development* signature is only meant for your own machines. The recipient has to approve it:

1. Move `KiCadQL.app` to `/Applications` and open it once. When the "cannot be opened" warning
   appears, click Done.
2. Go to System Settings ▸ Privacy & Security, scroll down and click **Open Anyway** next to
   KiCadQL. Alternatively, run `xattr -dr com.apple.quarantine /Applications/KiCadQL.app` in Terminal.
3. Open the app again. If needed, enable *KiCad PCB Preview* in System Settings ▸ General ▸ Login
   Items & Extensions ▸ Quick Look.

**Signed with a paid Apple Developer Program account ($99/year)**: export with Product ▸ Archive ▸
Distribute App ▸ **Direct Distribution**. Xcode signs the app with a *Developer ID* certificate and
has Apple notarize it. Recipients can then unzip it, drag it to `/Applications` and open it with no
warnings. This is the build to attach to a GitHub release.

**From source**: anyone with Xcode can build it themselves by following
[docs/XCODE.md](docs/XCODE.md).

To check how a copy is signed: `codesign -dvv KiCadQL.app` (look at the first `Authority=` line) and
`spctl -a -vv KiCadQL.app` (this says `accepted` for a notarized Developer ID build).
