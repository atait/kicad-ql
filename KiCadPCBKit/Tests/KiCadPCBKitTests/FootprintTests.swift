import CoreGraphics
import Foundation
import Testing
@testable import KiCadPCBKit

@Test func parsesAndDrawsFootprint() throws {
    let fp = try PCBBoard(url: examples.appendingPathComponent("Crystal_HC49-U-3Pin_Vertical.kicad_mod"))
    #expect(fp.isFootprint)
    // three through-hole pads on *.Cu and *.Mask; no courtyard, no paste
    #expect(PCBRenderer.layers(of: fp) == ["F.Fab", "F.SilkS", "F.Mask", "F.Cu", "B.Cu", "B.Mask"])
    #expect(fp.holes.count == 3)
    #expect(fp.padNumbers.count == 3)
    #expect(fp.shapes["F.CrtYd"] == nil)
    // two lines, two arcs and "REF**"; the hidden KiLib_Generator property isn't drawn
    #expect(fp.shapes["F.SilkS"]?.count == 5)
    for pad in fp.shapes["F.Cu"] ?? [] { #expect(fp.bounds.contains(pad.path.boundingBoxOfPath)) }

    let size = fp.fittedSize(in: CGSize(width: 256, height: 256))
    let ctx = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    PCBRenderer.draw(fp, in: ctx, rect: CGRect(origin: .zero, size: size))
    #expect(ctx.makeImage() != nil)
}

@Test func readsKiCad5ModuleWithoutPaste() throws {
    let fp = try PCBBoard(data: Data("""
        (module R_0603 (layer F.Cu)
          (fp_line (start -1 -0.5) (end 1 -0.5) (layer F.SilkS) (width 0.12))
          (pad 1 smd rect (at -0.8 0) (size 0.8 0.9) (layers F.Cu F.Paste F.Mask))
          (pad 2 smd rect (at 0.8 0) (size 0.8 0.9) (layers F.Cu F.Paste F.Mask)))
        """.utf8))
    #expect(fp.isFootprint)
    #expect(fp.copperLayers == ["F.Cu"])
    #expect(PCBRenderer.layers(of: fp) == ["F.SilkS", "F.Mask", "F.Cu"])
    #expect(fp.shapes["F.Paste"] == nil)
    #expect(fp.holes.isEmpty)
}

@Test func boardsKeepNoFootprintLayers() throws {
    let board = try PCBBoard(url: examples.appendingPathComponent("LoomRide-v1.kicad_pcb"))
    #expect(!board.isFootprint)
    #expect(board.padNumbers.isEmpty)
    #expect(PCBBoard.footprintLayers.allSatisfy { board.shapes[$0] == nil })
}

@Test func rejectsSymbolLibraries() {
    #expect(throws: PCBError.self) { try PCBBoard(data: Data("(kicad_symbol_lib (version 1))".utf8)) }
}

/// svg2mod writes KiCad 5 polygons: no fill token means filled, unless it says (fill none).
@Test func kiCad5PolygonsAreFilledAndEdgeCutsCanBeFocused() throws {
    let fp = try PCBBoard(data: Data("""
        (module Logo (layer F.Cu)
          (fp_poly (pts (xy 0 0) (xy 4 0) (xy 4 4)) (layer F.Cu) (width 0))
          (fp_poly (pts (xy 0 0) (xy 4 0) (xy 4 4)) (layer F.Mask) (width 0.16))
          (fp_poly (pts (xy -1 -1) (xy 5 -1) (xy 5 5) (xy -1 5)) (layer Edge.Cuts) (width 0.1) (fill none)))
        """.utf8))
    func styles(_ layer: String) -> [String] {
        (fp.shapes[layer] ?? []).map { if case .fill = $0.style { "fill" } else { "stroke" } }
    }
    #expect(styles("F.Cu") == ["fill"])
    #expect(styles("F.Mask") == ["fill", "stroke"])
    #expect(styles("Edge.Cuts") == ["stroke"])
    #expect(PCBRenderer.layers(of: fp) == ["F.Mask", "F.Cu", "Edge.Cuts"])
}
