import CoreGraphics
import Foundation
import Testing
@testable import KiCadPCBKit

/// The repo's examples/ directory, found relative to this source file.
let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("examples")

@Test func parsesNestedListsAndQuotedStrings() throws {
    let e = try SExprParser.parse(Data(#"(a (b 1 2.5) "q \"x\" y" (c))"#.utf8))
    #expect(e.name == "a")
    #expect(e.first("b")?.number(2) == 2.5)
    #expect(e.string(2) == #"q "x" y"#)
    #expect(e.first("c")?.items.count == 1)
}

@Test func rejectsUnbalancedInput() {
    #expect(throws: SExprError.self) { try SExprParser.parse(Data("(a (b)".utf8)) }
    #expect(throws: SExprError.self) { try SExprParser.parse(Data("   ".utf8)) }
}

@Test func rejectsNonBoardFiles() {
    #expect(throws: PCBError.self) { try PCBBoard(data: Data("(kicad_sch (version 1))".utf8)) }
}

@Test func arcPassesThroughMidpoint() {
    let pts = arcPoints(CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0))
    #expect(pts.first == CGPoint(x: 1, y: 0))
    #expect(pts.allSatisfy { abs(hypot($0.x, $0.y) - 1) < 1e-9 })
    #expect(pts.contains { $0.y > 0.99 })                 // went over the top, not underneath
}

@Test func fittedSizeKeepsAspectRatio() throws {
    let board = try PCBBoard(data: Data("""
        (kicad_pcb (gr_rect (start 0 0) (end 38 18) (layer "Edge.Cuts") (stroke (width 0.1))))
        """.utf8))
    #expect(board.bounds == CGRect(x: -1, y: -1, width: 40, height: 20))   // outline plus a 1 mm margin
    #expect(board.fittedSize(in: CGSize(width: 400, height: 400)) == CGSize(width: 400, height: 200))
}

@Test(arguments: ["LoomRide-v1.kicad_pcb", "Matrix-testLoad-v2.kicad_pcb"])
func parsesAndDrawsExample(_ name: String) throws {
    let board = try PCBBoard(url: examples.appendingPathComponent(name))
    #expect(board.copperLayers.contains("F.Cu"))
    #expect(board.bounds.width > 0 && board.bounds.height > 0)

    let size = board.fittedSize(in: CGSize(width: 256, height: 256))
    let ctx = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    PCBRenderer.draw(board, in: ctx, rect: CGRect(origin: .zero, size: size))
    #expect(ctx.makeImage() != nil)
}
