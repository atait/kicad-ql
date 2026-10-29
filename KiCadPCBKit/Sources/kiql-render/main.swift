// kiql-render: test the renderers outside QuickLook.
//   swift run -c release --package-path KiCadPCBKit kiql-render board.kicad_pcb out.png [max_px] [--focus LAYER] [--back]
//   (a footprint, .kicad_mod, works the same way)
//   swift run -c release --package-path KiCadPCBKit kiql-render sheet.kicad_sch out.png [max_px] [--sheet NAME] [--zoom Z --at X,Y]
// --focus draws what the QuickLook preview shows after clicking that layer in the legend;
// --back draws the board as seen from the bottom ("View from back" in the legend).
// --sheet draws the sub-sheet with that name instead, as the preview does after double-clicking it.
// --zoom draws the picture Z times larger, cropped to max_px around X,Y (mm), as after pinching in.
import Foundation
import KiCadPCBKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var args = CommandLine.arguments
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let focus = option("--focus")
let sheetName = option("--sheet")
let zoom = CGFloat(option("--zoom").flatMap(Double.init) ?? 1)
let center = option("--at").map { $0.split(separator: ",").compactMap { Double($0) } }
let fromBack = args.contains("--back")
args.removeAll { $0 == "--back" }
guard args.count >= 3 else {
    print("""
        usage: kiql-render board.kicad_pcb|part.kicad_mod out.png [max_px] [--focus LAYER] [--back] [--zoom Z --at X,Y]
               kiql-render sheet.kicad_sch out.png [max_px] [--sheet NAME] [--zoom Z --at X,Y]
        """)
    exit(1)
}
let maxPx = CGFloat(args.count > 3 ? Double(args[3]) ?? 1600 : 1600)
let url = URL(fileURLWithPath: args[1])

/// Something that can be fitted into a rect and drawn, zoomed by `zoom` around `at` (in fitted pixels).
struct Picture {
    let bounds: CGRect
    let fittedSize: (CGSize) -> CGSize
    let draw: (CGContext, CGRect, CGFloat) -> Void
    let summary: String
}

let t0 = Date()
let picture: Picture
if url.pathExtension == "kicad_sch" {
    var sch = try Schematic(url: url)
    if let sheetName {
        guard let sheet = sch.sheets.first(where: { $0.name == sheetName }) else {
            print("no sheet \(sheetName); this schematic has: \(sch.sheets.map(\.name).joined(separator: " "))")
            exit(1)
        }
        sch = try Schematic(url: url.deletingLastPathComponent().appendingPathComponent(sheet.file),
                            instancePath: "/\(sch.uuid)/\(sheet.uuid)", sheetPath: "/\(sheet.name)/")
    }
    let s = sch
    picture = Picture(bounds: s.bounds, fittedSize: s.fittedSize(in:),
                      draw: { SchematicRenderer.draw(s, in: $0, rect: $1, zoom: $2) },
                      summary: "sheets: " + s.sheets.map { "\($0.name) (\($0.file))" }.joined(separator: ", "))
} else {
    let board = try PCBBoard(url: url)
    if let focus, !PCBRenderer.layers(of: board).contains(focus) {
        print("no layer \(focus); this board has: \(PCBRenderer.layers(of: board).joined(separator: " "))")
        exit(1)
    }
    picture = Picture(bounds: board.bounds, fittedSize: board.fittedSize(in:),
                      draw: { PCBRenderer.draw(board, in: $0, rect: $1, focus: focus, fromBack: fromBack, zoom: $2) },
                      summary: "layers: " + PCBRenderer.layers(of: board).joined(separator: " "))
}
let t1 = Date()

let size = picture.fittedSize(CGSize(width: maxPx, height: maxPx))
let w = Int(size.width), h = Int(size.height)
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
let rect = CGRect(x: 0, y: 0, width: w, height: h)
if zoom != 1 {
    // put the point X,Y (mm, y down) in the middle of the picture
    let b = picture.bounds, s = min(CGFloat(w) / b.width, CGFloat(h) / b.height)
    let c = center.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } ?? CGPoint(x: b.midX, y: b.midY)
    let px = CGFloat(w) / 2 + (c.x - b.midX) * s, py = CGFloat(h) / 2 - (c.y - b.midY) * s
    ctx.translateBy(x: CGFloat(w) / 2 - px * zoom, y: CGFloat(h) / 2 - py * zoom)
    ctx.scaleBy(x: zoom, y: zoom)
}
picture.draw(ctx, rect, zoom)
let t2 = Date()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(3) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)

print(String(format: "parsed %.3f s, drew %.3f s, %d×%d px, %@",
             t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), w, h, picture.summary))
