import CoreGraphics

/// Draws a PCBBoard fitted (aspect preserved, centred) into `rect` of a y-up CGContext.
public enum PCBRenderer {
    static let background = hexColor("#fbfbf8")
    static let copperColors: [String: String] = [
        "F.Cu": "#c8102e", "B.Cu": "#1f5fbf", "In1.Cu": "#2e8b57", "In2.Cu": "#d48a00",
        "In3.Cu": "#8e44ad", "In4.Cu": "#16a085", "In5.Cu": "#b9770e", "In6.Cu": "#5d6d7e",
    ]
    /// Off-white with a hint of yellow on the front; the back is a little more yellow.
    static let frontSilk = hexColor("#f4efd6"), backSilk = hexColor("#ecdc9c")

    public static func draw(_ board: PCBBoard, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(background)
        ctx.fill(rect)

        let b = board.bounds
        guard b.width > 0, b.height > 0 else { return }
        let s = min(rect.width / b.width, rect.height / b.height)
        // KiCad's y points down: put the board's top edge (b.minY) at the top of the rect.
        ctx.translateBy(x: rect.midX - b.width * s / 2, y: rect.midY + b.height * s / 2)
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // back silkscreen sits under all the copper, showing through where the copper is translucent
        silk(board.shapes["B.SilkS"] ?? [], backSilk, alpha: 0.9, ctx)

        // Copper, back to front. Each layer is drawn opaque into its own transparency group and composited
        // at one alpha, so overlapping pads and tracks on a layer don't darken each other.
        for layer in board.copperLayers.sorted(by: { stackIndex($0) > stackIndex($1) }) {
            let c = hexColor(copperColors[layer] ?? "#7f8c8d")
            ctx.setAlpha(layer == "F.Cu" ? 0.85 : 0.7)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(c.copy(alpha: 0.45) ?? c)
            paint(board.zoneFills[layer] ?? [], ctx)
            ctx.setFillColor(c)
            ctx.setStrokeColor(c)
            paint(board.shapes[layer] ?? [], ctx)
            ctx.endTransparencyLayer()
        }
        ctx.setAlpha(1)

        // vias over all copper, then every hole punched through to the background
        ctx.setFillColor(hexColor("#555555"))
        for v in board.vias { ctx.fillEllipse(in: circleRect(v.center, v.size / 2)) }
        ctx.setFillColor(background)
        for v in board.vias { ctx.fillEllipse(in: circleRect(v.center, v.drill / 2)) }
        for h in board.holes {
            ctx.addPath(h)
            ctx.fillPath()
        }

        // front silkscreen over everything but the outline
        silk(board.shapes["F.SilkS"] ?? [], frontSilk, alpha: 0.8, ctx)

        // outline at a constant ~1.2 pt, whatever the zoom
        ctx.setStrokeColor(hexColor("#000000"))
        ctx.setLineWidth(1.2 / s)
        for sh in board.shapes["Edge.Cuts"] ?? [] {
            ctx.addPath(sh.path)
            ctx.strokePath()
        }
    }

    /// One silkscreen layer as a single translucent group, so overlapping strokes and glyphs don't stack.
    private static func silk(_ shapes: [Shape], _ color: CGColor, alpha: CGFloat, _ ctx: CGContext) {
        guard !shapes.isEmpty else { return }
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        paint(shapes, ctx)
        ctx.endTransparencyLayer()
        ctx.setAlpha(1)
    }

    private static func paint(_ shapes: [Shape], _ ctx: CGContext) {
        for sh in shapes {
            ctx.addPath(sh.path)
            switch sh.style {
            case .fill:
                ctx.fillPath()
            case .stroke(let w):
                ctx.setLineWidth(w)
                ctx.strokePath()
            }
        }
    }

    /// F.Cu = 0, In1.Cu = 1, …, B.Cu = 1000. Higher is further back.
    private static func stackIndex(_ layer: String) -> Int {
        if layer == "F.Cu" { return 0 }
        if layer == "B.Cu" { return 1000 }
        if layer.hasPrefix("In"), let n = Int(layer.dropFirst(2).dropLast(3)) { return n }
        return 500
    }

    private static func circleRect(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }
}

func hexColor(_ s: String, alpha: CGFloat = 1) -> CGColor {
    let v = UInt32(s.dropFirst(), radix: 16) ?? 0x7f8c8d
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}
