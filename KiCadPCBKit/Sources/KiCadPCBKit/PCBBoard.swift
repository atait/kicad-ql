import Foundation
import CoreGraphics

/// One drawable piece of a layer, in board millimetres (KiCad coordinates, y pointing down).
struct Shape {
    enum Style { case fill, stroke(CGFloat) }      // stroke width in mm; 0 draws a hairline
    let path: CGPath
    let style: Style
}

public enum PCBError: Error { case notABoard }

/// What an overview needs from a .kicad_pcb: copper (tracks, pads, copper graphics, zone fills as last
/// filled), vias and holes, front silkscreen graphics, and the board outline. Text is skipped.
public final class PCBBoard: @unchecked Sendable {        // never mutated after init
    public private(set) var copperLayers: [String] = []
    private(set) var shapes: [String: [Shape]] = [:]
    private(set) var zoneFills: [String: [Shape]] = [:]
    private(set) var vias: [(center: CGPoint, size: CGFloat, drill: CGFloat)] = []
    private(set) var holes: [CGPath] = []
    public private(set) var bounds: CGRect = .zero

    /// Non-copper layers that are kept.
    static let otherLayers: Set<String> = ["F.SilkS", "Edge.Cuts"]

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        let root = try SExprParser.parse(data)
        guard root.name == "kicad_pcb" else { throw PCBError.notABoard }
        // header: (layers (0 "F.Cu" signal) (2 "B.Cu" signal) …)
        let declared = (root.first("layers")?.items.dropFirst() ?? [])
            .compactMap { $0.string(1) }
            .filter { $0.hasSuffix(".Cu") }
        copperLayers = declared.isEmpty ? ["F.Cu", "B.Cu"] : declared

        for e in root.items.dropFirst() {
            guard let name = e.name else { continue }
            switch name {
            case "segment", "arc": track(e)
            case "via": via(e)
            case "zone": zone(e)
            case "footprint", "module": footprint(e)
            default:
                if name.hasPrefix("gr_"), let layer = e.first("layer")?.string(1) {
                    add(graphicShapes(e, .identity), on: layer)
                }
            }
        }
        bounds = computeBounds()
    }

    /// The largest size with the board's aspect ratio that fits in `box`.
    public func fittedSize(in box: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return box }
        let s = min(box.width / bounds.width, box.height / bounds.height)
        return CGSize(width: max(1, (bounds.width * s).rounded()), height: max(1, (bounds.height * s).rounded()))
    }

    // MARK: - items

    private func add(_ s: [Shape], on layer: String) {
        guard !s.isEmpty, layer.hasSuffix(".Cu") || Self.otherLayers.contains(layer) else { return }
        shapes[layer, default: []] += s
    }

    /// (segment (start)(end)(width)(layer)) and (arc (start)(mid)(end)(width)(layer))
    private func track(_ e: SExpr) {
        guard let layer = e.first("layer")?.string(1), let w = e.first("width")?.number(1),
              let a = e.point("start"), let b = e.point("end") else { return }
        let pts = e.point("mid").map { arcPoints(a, $0, b) } ?? [a, b]
        add([Shape(path: polyline(pts), style: .stroke(CGFloat(w)))], on: layer)
    }

    private func via(_ e: SExpr) {
        guard let c = e.point("at"), let size = e.first("size")?.number(1) else { return }
        let drill = e.first("drill")?.number(1) ?? size / 2
        vias.append((c, CGFloat(size), CGFloat(drill)))
    }

    /// Zone fills are stored in the file as (filled_polygon (layer …) (pts …)), already fractured.
    private func zone(_ e: SExpr) {
        for fp in e.all("filled_polygon") {
            guard let layer = fp.first("layer")?.string(1), let pts = fp.first("pts") else { continue }
            zoneFills[layer, default: []].append(Shape(path: polyline(polyPoints(pts), closed: true), style: .fill))
        }
    }

    private func footprint(_ e: SExpr) {
        let at = e.first("at")
        let origin = CGPoint(x: at?.number(1) ?? 0, y: at?.number(2) ?? 0)
        let t = placement(origin, CGFloat(at?.number(3) ?? 0))
        // Back-side footprints are stored already flipped, so rotation + translation is the whole transform.
        for item in e.items.dropFirst() {
            guard let n = item.name else { continue }
            if n == "pad" {
                pad(item, footprint: t)
            } else if n.hasPrefix("fp_"), let layer = item.first("layer")?.string(1) {
                add(graphicShapes(item, t), on: layer)
            }
        }
    }

    /// (pad "1" smd roundrect (at x y [angle]) (size w h) (layers …) (roundrect_rratio r) (drill …) …)
    private func pad(_ e: SExpr, footprint ft: CGAffineTransform) {
        guard let at = e.first("at"), let px = at.number(1), let py = at.number(2),
              let sw = e.first("size")?.number(1) else { return }
        let w = CGFloat(sw), h = CGFloat(e.first("size")?.number(2) ?? sw)
        let center = CGPoint(x: px, y: py).applying(ft)
        // In a board file the pad's (at … angle) already includes the footprint's rotation.
        let pt = placement(center, CGFloat(at.number(3) ?? 0))
        let kind = e.string(2) ?? "smd"
        var shape = e.string(3) ?? "rect"

        if kind != "np_thru_hole" {
            var copper: [Shape] = []
            if shape == "custom" {
                shape = e.first("options")?.first("anchor")?.string(1) ?? "rect"
                for prim in e.first("primitives")?.items.dropFirst() ?? [] {
                    copper += graphicShapes(prim, pt, defaultFilled: true)
                }
            }
            let rratio = CGFloat(e.first("roundrect_rratio")?.number(1) ?? 0.25)
            copper.insert(Shape(path: padOutline(shape, w, h, rratio: rratio, pt), style: .fill), at: 0)
            for layer in padLayers(e) { add(copper, on: layer) }
        }
        // (drill 1.0) | (drill oval 1.0 2.0) | (drill 1.0 (offset …)); the offset is ignored
        if let d = e.first("drill") {
            let oval = d.string(1) == "oval"
            let dw = CGFloat(d.number(oval ? 2 : 1) ?? 0)
            let dh = oval ? CGFloat(d.number(3) ?? Double(dw)) : dw
            if dw > 0 { holes.append(padOutline(dw == dh ? "circle" : "oval", dw, dh, rratio: 0, pt)) }
        }
    }

    private func padLayers(_ e: SExpr) -> [String] {
        var out: [String] = []
        for name in (e.first("layers")?.items.dropFirst() ?? []).compactMap(\.atom) {
            if name == "*.Cu" { out += copperLayers }
            else if name == "F&B.Cu" { out += ["F.Cu", "B.Cu"] }
            else if name.hasSuffix(".Cu") { out.append(name) }
        }
        return out
    }

    private func computeBounds() -> CGRect {
        var b = CGRect.null
        for s in shapes["Edge.Cuts"] ?? [] { b = b.union(s.path.boundingBoxOfPath) }
        if b.isNull {                                     // no outline: fit everything
            for list in shapes.values { for s in list { b = b.union(s.path.boundingBoxOfPath) } }
            for list in zoneFills.values { for s in list { b = b.union(s.path.boundingBoxOfPath) } }
        }
        return b.isNull ? .zero : b.insetBy(dx: -1, dy: -1)
    }
}
