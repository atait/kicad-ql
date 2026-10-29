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
    /// A footprint's silkscreen is mostly over bare background, so it is dark instead.
    static let footprintFrontSilk = hexColor("#262626"), footprintBackSilk = hexColor("#6b5d2e")
    /// Footprint-only layers: fab drawings and solder mask openings.
    static let otherColors: [String: String] = [
        "F.Fab": "#cdb76e", "B.Fab": "#dcab00", "F.Mask": "#a35dc4", "B.Mask": "#1aa39a",
    ]

    static let edgeColor = hexColor("#000000")
    /// Every focused view dims the other layers to this grey and opacity, so they stay as context.
    static let dimColor = hexColor("#808080"), dimAlpha: CGFloat = 0.25
    /// Dark edge drawn around focused silkscreen, so off-white still reads over a light background.
    static let silkHalo = hexColor("#4a4430")
    /// Copper zone fills are the layer colour this much greyer, at this opacity, so tracks stand out on them.
    static let zoneDesaturation: CGFloat = 0.3, zoneAlpha: CGFloat = 0.45

    /// The layers a viewer can focus, front to back: F.Fab, F.SilkS, F.Mask, F.Cu, In1.Cu…, B.Cu, B.Mask,
    /// B.SilkS, B.Fab. Non-copper layers are listed only if the board has something on them (fab and
    /// mask only ever do in a footprint). A footprint with an outline lists Edge.Cuts last.
    public static func layers(of board: PCBBoard) -> [String] {
        let front = ["F.Fab", "F.SilkS", "F.Mask"].filter { board.shapes[$0] != nil }
        var back = ["B.Mask", "B.SilkS", "B.Fab"].filter { board.shapes[$0] != nil }
        if board.isFootprint && board.shapes["Edge.Cuts"] != nil { back.append("Edge.Cuts") }
        return front + board.copperLayers.sorted { stackIndex($0) < stackIndex($1) } + back
    }

    /// The colour a layer is drawn in, for legends.
    public static func color(of layer: String, footprint: Bool = false) -> CGColor {
        switch layer {
        case "F.SilkS": footprint ? footprintFrontSilk : frontSilk
        case "B.SilkS": footprint ? footprintBackSilk : backSilk
        case "Edge.Cuts": edgeColor
        default: hexColor(copperColors[layer] ?? otherColors[layer] ?? "#7f8c8d")
        }
    }

    /// With `focus` nil this is the overview. With a layer from `layers(of:)`, that layer is drawn
    /// opaque on top and every other layer is drawn grey and faint underneath it.
    ///
    /// `fromBack` shows the board as seen from the bottom: mirrored left to right, with the back layers
    /// nearest the viewer. Colours keep their meaning (B.Cu is still blue), and back silkscreen text,
    /// which KiCad stores mirrored, reads the right way round.
    ///
    /// `zoom` is how much the caller has already scaled `ctx` up by, so the outline can stay thin.
    public static func draw(_ board: PCBBoard, in ctx: CGContext, rect: CGRect, focus: String? = nil,
                            fromBack: Bool = false, zoom: CGFloat = 1) {
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

        // Edge.Cuts is always the outline, drawn last; a footprint lists it only so it can be focused
        var stack = Array(layers(of: board).reversed()).filter { $0 != "Edge.Cuts" }   // furthest from the viewer first
        if fromBack { stack.reverse() }
        let nearSilk = fromBack ? "B.SilkS" : "F.SilkS", nearCopper = fromBack ? "B.Cu" : "F.Cu"
        let fp = board.isFootprint
        var dimOutline = false
        if let focus, stack.contains(focus) || (fp && focus == "Edge.Cuts") {
            for layer in stack where layer != focus {
                drawLayer(layer, board, dimColor, alpha: dimAlpha, ctx)
            }
            let copper = focus.hasSuffix(".Cu")
            if !copper { drawVias(board, alpha: dimAlpha, ctx) }  // vias are copper: faint under focused silk
            if focus != "Edge.Cuts" {
                drawLayer(focus, board, color(of: focus, footprint: fp), alpha: 1,
                          halo: !fp && focus.hasSuffix(".SilkS"), ctx)
            }
            dimOutline = fp && focus != "Edge.Cuts"         // a board keeps its outline as the frame
            if copper { drawVias(board, alpha: 1, ctx) }
            punchHoles(board, ctx)
            if copper { drawPadNumbers(board, lineWidth: 1.5 / (s * zoom), ctx) }
        } else {
            // Overview: mask openings first, so they show only where they are larger than the copper; the
            // layers behind the near copper, far to near (the far silkscreen shows through where the copper
            // is translucent); vias and holes; then the near silkscreen and fab over everything but the outline.
            let nearest = stack.lastIndex { $0.hasSuffix(".Cu") } ?? -1
            for layer in stack where layer.hasSuffix(".Mask") {
                drawLayer(layer, board, color(of: layer), alpha: 0.35, ctx)
            }
            for (i, layer) in stack.enumerated() where i <= nearest && !layer.hasSuffix(".Mask") {
                let alpha: CGFloat = layer.hasSuffix(".SilkS") || layer.hasSuffix(".Fab") ? 0.9
                                   : layer == nearCopper ? 0.85 : 0.7
                drawLayer(layer, board, color(of: layer, footprint: fp), alpha: alpha, ctx)
            }
            drawVias(board, alpha: 1, ctx)
            punchHoles(board, ctx)
            for (i, layer) in stack.enumerated() where i > nearest && !layer.hasSuffix(".Mask") {
                drawLayer(layer, board, color(of: layer, footprint: fp), alpha: layer == nearSilk ? 0.8 : 0.9, ctx)
            }
            drawPadNumbers(board, lineWidth: 1.5 / (s * zoom), ctx)
        }

        // outline at a constant ~1.2 pt, whatever the zoom
        ctx.setStrokeColor(dimOutline ? dimColor.copy(alpha: dimAlpha)! : edgeColor)
        ctx.setLineWidth(1.2 / (s * zoom))
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

    /// White numbers with a dark edge `lineWidth` wide, so they read on copper and over holes.
    private static func drawPadNumbers(_ board: PCBBoard, lineWidth: CGFloat, _ ctx: CGContext) {
        guard !board.padNumbers.isEmpty else { return }
        ctx.setStrokeColor(silkHalo)
        ctx.setLineWidth(lineWidth)
        ctx.setFillColor(hexColor("#ffffff"))
        for sh in board.padNumbers {
            ctx.addPath(sh.path)
            ctx.strokePath()
        }
        for sh in board.padNumbers {
            ctx.addPath(sh.path)
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
