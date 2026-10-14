# KiCad QuickLook

A macOS QuickLook extension for KiCad boards (`.kicad_pcb`). Press space on a board in Finder and you
get a fit-to-window overview. KiCad does not need to be installed or running, because the board file
is parsed and drawn directly.

The render is an overview, not a replacement for KiCad. It draws copper (tracks, pads, zone fills),
vias, holes, front silkscreen graphics and the board outline. It skips text.

## Layout

| Path | What it is |
| --- | --- |
| `KiCadPCBKit/` | Swift package: S-expression parser, board model, CoreGraphics renderer, `kiql-render` CLI, tests |
| `KiCadQL.xcodeproj` | Xcode project: host app plus the Preview extension |
| `KiCadQL/` | Host app. It exists to carry the extension and declare the `.kicad_pcb` file type |
| `KiCadQLPreview/` | QuickLook preview extension (spacebar) |
| `examples/` | Sample boards for testing |
| `docs/XCODE.md` | Step-by-step guide for building and installing with Xcode |

## Try the renderer without Xcode

```sh
swift run -c release --package-path KiCadPCBKit kiql-render examples/LoomRide-v1.kicad_pcb out.png 1200
swift test --package-path KiCadPCBKit
```

## Build the QuickLook extension

See [docs/XCODE.md](docs/XCODE.md).
