// kiql-render: test the renderer outside QuickLook.
//   swift run -c release --package-path KiCadPCBKit kiql-render board.kicad_pcb out.png [max_px]
import Foundation
import KiCadPCBKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: kiql-render board.kicad_pcb out.png [max_px]")
    exit(1)
}
let maxPx = CGFloat(args.count > 3 ? Double(args[3]) ?? 1600 : 1600)

let t0 = Date()
let board = try PCBBoard(url: URL(fileURLWithPath: args[1]))
let t1 = Date()

let size = board.fittedSize(in: CGSize(width: maxPx, height: maxPx))
let w = Int(size.width), h = Int(size.height)
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
PCBRenderer.draw(board, in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
let t2 = Date()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(3) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)

print(String(format: "parsed %.3f s, drew %.3f s, %d×%d px, copper layers: %@",
             t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), w, h,
             board.copperLayers.joined(separator: " ")))
