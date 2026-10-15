import CoreGraphics

/// Draws a PCBBoard fitted (aspect preserved, centred) into `rect` of a y-up CGContext.
public enum PCBRenderer {
    /// Fills `rect` before the board is drawn. Views around the board should use it too.
    public static let background = hexColor("#fbfbf8")
    static let copperColors: [String: String] = [
        "F.Cu": "#c8102e", "B.Cu": "#1f5fbf", "In1.Cu": "#2e8b57", "In2.Cu": "#d48a00",
        "In3.Cu": "#8e44ad", "In4.Cu": "#16a085", "In5.Cu": "#b9770e", "In6.Cu": "#5d6d7e",
    ]
    /// Off-white with a hint of yellow on the front; the back is a little more yellow.
    static let frontSilk = hexColor("#f4efd6"), backSilk = hexColor("#ecdc9c")

    /// Every focused view dims the other layers to this grey and opacity, so they stay as context.
    static let dimColor = hexColor("#808080"), dimAlpha: CGFloat = 0.25
    /// Dark edge drawn around focused silkscreen, so off-white still reads over a light background.
    static let silkHalo = hexColor("#4a4430")
    /// Copper zone fills are the layer colour this much greyer, at this opacity, so tracks stand out on them.
    static let zoneDesaturation: CGFloat = 0.3, zoneAlpha: CGFloat = 0.45

    /// The layers a viewer can focus, front to back: F.SilkS, F.Cu, In1.Cu…, B.Cu, B.SilkS.
    /// Silkscreen layers are listed only if the board has something on them.
    public static func layers(of board: PCBBoard) -> [String] {
        var out = board.copperLayers.sorted { stackIndex($0) < stackIndex($1) }
        if board.shapes["F.SilkS"] != nil { out.insert("F.SilkS", at: 0) }
        if board.shapes["B.SilkS"] != nil { out.append("B.SilkS") }
        return out
    }

    /// The colour a layer is drawn in, for legends.
    public static func color(of layer: String) -> CGColor {
        switch layer {
        case "F.SilkS": frontSilk
        case "B.SilkS": backSilk
        default: hexColor(copperColors[layer] ?? "#7f8c8d")
        }
    }

    /// With `focus` nil this is the overview. With a layer from `layers(of:)`, that layer is drawn
    /// opaque on top and every other layer is drawn grey and faint underneath it.
    ///
    /// `fromBack` shows the board as seen from the bottom: mirrored left to right, with the back layers
    /// nearest the viewer. Colours keep their meaning (B.Cu is still blue), and back silkscreen text,
    /// which KiCad stores mirrored, reads the right way round.
    public static func draw(_ board: PCBBoard, in ctx: CGContext, rect: CGRect, focus: String? = nil,
                            fromBack: Bool = false) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(background)
        ctx.fill(rect)

        let b = board.bounds
        guard b.width > 0, b.height > 0 else { return }
        let s = min(rect.width / b.width, rect.height / b.height)
        // KiCad's y points down: put the board's top edge (b.minY) at the top of the rect. From the back,
        // x is mirrored too, so the board's left edge (b.minX) goes on the right.
        let sx = fromBack ? -s : s
        ctx.translateBy(x: rect.midX - b.width * sx / 2, y: rect.midY + b.height * s / 2)
        ctx.scaleBy(x: sx, y: -s)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        var stack = Array(layers(of: board).reversed())           // furthest from the viewer first
        if fromBack { stack.reverse() }
        let nearSilk = fromBack ? "B.SilkS" : "F.SilkS", nearCopper = fromBack ? "B.Cu" : "F.Cu"
        if let focus, stack.contains(focus) {
            for layer in stack where layer != focus {
                drawLayer(layer, board, dimColor, alpha: dimAlpha, ctx)
            }
            let copper = focus.hasSuffix(".Cu")
            if !copper { drawVias(board, alpha: dimAlpha, ctx) }  // vias are copper: faint under focused silk
            drawLayer(focus, board, color(of: focus), alpha: 1, halo: !copper, ctx)
            if copper { drawVias(board, alpha: 1, ctx) }
            punchHoles(board, ctx)
        } else {
            // Overview: the far silkscreen under the copper, so it shows through where the copper is
            // translucent; copper far to near; vias and holes; near silkscreen over everything but the outline.
            for layer in stack where layer != nearSilk {
                let alpha: CGFloat = layer.hasSuffix(".SilkS") ? 0.9 : layer == nearCopper ? 0.85 : 0.7
                drawLayer(layer, board, color(of: layer), alpha: alpha, ctx)
            }
            drawVias(board, alpha: 1, ctx)
            punchHoles(board, ctx)
            drawLayer(nearSilk, board, color(of: nearSilk), alpha: 0.8, ctx)
        }

        // outline at a constant ~1.2 pt, whatever the zoom
        ctx.setStrokeColor(hexColor("#000000"))
        ctx.setLineWidth(1.2 / s)
        for sh in board.shapes["Edge.Cuts"] ?? [] {
            ctx.addPath(sh.path)
            ctx.strokePath()
        }
    }

    /// One layer as a single translucent group, so overlapping pads, tracks, strokes and glyphs don't
    /// darken each other. Copper zone fills are drawn lighter than tracks and pads.
    private static func drawLayer(_ layer: String, _ board: PCBBoard, _ color: CGColor, alpha: CGFloat,
                                  halo: Bool = false, _ ctx: CGContext) {
        let shapes = board.shapes[layer] ?? [], zones = board.zoneFills[layer] ?? []
        guard !shapes.isEmpty || !zones.isEmpty else { return }
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if halo {
            // the same shapes, stroked wider in a dark colour, then the real colour on top
            ctx.setFillColor(silkHalo)
            ctx.setStrokeColor(silkHalo)
            paint(shapes, ctx, widen: 0.16)
        }
        ctx.setFillColor(zoneColor(color))
        paint(zones, ctx)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        paint(shapes, ctx)
        ctx.endTransparencyLayer()
        ctx.setAlpha(1)
    }

    /// `color` mixed `zoneDesaturation` of the way towards the grey of the same brightness.
    private static func zoneColor(_ color: CGColor) -> CGColor {
        guard let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                                      options: nil)?.components, c.count >= 3 else { return color }
        let grey = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        func mix(_ v: CGFloat) -> CGFloat { v + (grey - v) * zoneDesaturation }
        return CGColor(srgbRed: mix(c[0]), green: mix(c[1]), blue: mix(c[2]), alpha: zoneAlpha)
    }

    /// Every via drill and pad hole, filled with the background colour.
    private static func punchHoles(_ board: PCBBoard, _ ctx: CGContext) {
        ctx.setFillColor(background)
        for v in board.vias { ctx.fillEllipse(in: circleRect(v.center, v.drill / 2)) }
        for h in board.holes {
            ctx.addPath(h)
            ctx.fillPath()
        }
    }

    private static func drawVias(_ board: PCBBoard, alpha: CGFloat, _ ctx: CGContext) {
        ctx.setFillColor(hexColor("#555555", alpha: alpha))
        for v in board.vias { ctx.fillEllipse(in: circleRect(v.center, v.size / 2)) }
    }

    /// `widen` > 0 strokes every shape that much wider (fills get a stroke of that width), for halos.
    private static func paint(_ shapes: [Shape], _ ctx: CGContext, widen: CGFloat = 0) {
        for sh in shapes {
            ctx.addPath(sh.path)
            switch sh.style {
            case .fill where widen > 0:
                ctx.setLineWidth(widen)
                ctx.drawPath(using: .fillStroke)
            case .fill:
                ctx.fillPath()
            case .stroke(let w):
                ctx.setLineWidth(w + widen)
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
