import CoreGraphics
import Foundation
import Testing
@testable import KiCadPCBKit

@Test(arguments: ["SkySense-bank.kicad_sch", "SkyKey-AT42QT1011.kicad_sch"])
func parsesAndDrawsSchematic(_ name: String) throws {
    let sch = try Schematic(url: examples.appendingPathComponent(name))
    #expect(sch.bounds == CGRect(x: 0, y: 0, width: 297, height: 210))      // A4
    #expect(sch.items.contains { $0.kind == .wire })
    #expect(sch.items.contains { $0.kind == .body })

    let size = sch.fittedSize(in: CGSize(width: 256, height: 256))
    let ctx = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    SchematicRenderer.draw(sch, in: ctx, rect: CGRect(origin: .zero, size: size))
    #expect(ctx.makeImage() != nil)
}

@Test func findsHierarchicalSheets() throws {
    let sch = try Schematic(url: examples.appendingPathComponent("SkySense-bank.kicad_sch"))
    #expect(sch.sheets.count == 8)
    #expect(sch.sheets.allSatisfy { $0.file == "SkyKey-AT42QT1011.kicad_sch" })
    #expect(Set(sch.sheets.map(\.name)) == Set((1...8).map { "ssen\($0)" }))
    #expect(sch.items.contains { $0.kind == .bus } && sch.items.contains { $0.kind == .busJunction })
}

@Test func rejectsBoardsAndViceVersa() {
    #expect(throws: SchematicError.self) { try Schematic(data: Data("(kicad_pcb (version 1))".utf8)) }
    #expect(throws: PCBError.self) { try PCBBoard(data: Data("(kicad_sch (version 1))".utf8)) }
}

@Test func paperSizes() throws {
    func page(_ paper: String) throws -> CGSize { try Schematic(data: Data("(kicad_sch \(paper))".utf8)).bounds.size }
    #expect(try page(#"(paper "A3")"#) == CGSize(width: 420, height: 297))
    #expect(try page(#"(paper "A4" portrait)"#) == CGSize(width: 210, height: 297))
    #expect(try page(#"(paper "User" 100 50)"#) == CGSize(width: 100, height: 50))
    #expect(try page("") == CGSize(width: 297, height: 210))
}

/// A one-line library symbol, pointing up in library coordinates (y up), placed at 10,10.
private func placedLine(_ placement: String) throws -> CGRect {
    let sch = try Schematic(data: Data("""
        (kicad_sch
          (lib_symbols (symbol "L:Up" (symbol "Up_0_1" (polyline (pts (xy 0 0) (xy 0 2))))))
          (symbol (lib_id "L:Up") \(placement) (unit 1)))
        """.utf8))
    return try #require(sch.items.first { $0.kind == .body }).shape.path.boundingBoxOfPath
}

@Test func placesLibrarySymbols() throws {
    // y up in the library is up on the sheet, where y points down
    #expect(try placedLine("(at 10 10 0)") == CGRect(x: 10, y: 8, width: 0, height: 2))
    // 90° is counter-clockwise on screen: up turns to the left
    #expect(try placedLine("(at 10 10 90)") == CGRect(x: 8, y: 10, width: 2, height: 0))
    // mirrored about the x axis: up turns down
    #expect(try placedLine("(at 10 10 0) (mirror x)") == CGRect(x: 10, y: 10, width: 0, height: 2))
}
