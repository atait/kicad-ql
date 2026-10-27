import CoreGraphics

/// Draws a Schematic page fitted (aspect preserved, centred) into `rect` of a y-up CGContext, in
/// KiCad's default colours.
public enum SchematicRenderer {
    /// KiCad's paper colour. Views around the page should use it too.
    public static let background = hexColor("#f5f4ef")

    static func color(of kind: Schematic.Kind) -> CGColor {
        switch kind {
        case .bodyFill: hexColor("#ffffc2")
        case .sheetFill: hexColor("#ffffff", alpha: 0)
        case .frame, .frameText, .body, .pin, .sheet, .globalLabel: hexColor("#840000")
        case .wire, .busEntry, .junction: hexColor("#009600")
        case .bus, .busJunction, .noConnect: hexColor("#000084")
        case .reference, .value, .pinName, .sheetPin, .sheetName: hexColor("#006464")
        case .pinNumber: hexColor("#a90000")
        case .field: hexColor("#840084")
        case .label: hexColor("#0f0f0f")
        case .hierLabel, .sheetFile: hexColor("#725600")
        case .graphic, .note: hexColor("#0000c2")
        }
    }

    /// Maps sheet millimetres (y down) to `rect` (y up), with the page fitted and centred.
    /// Inverting it tells which part of the sheet a point in `rect` is over.
    public static func pageTransform(_ sch: Schematic, in rect: CGRect) -> CGAffineTransform? {
        let b = sch.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let s = min(rect.width / b.width, rect.height / b.height)
        // KiCad's y points down: put the page's top edge at the top of the rect.
        return CGAffineTransform(translationX: -b.minX, y: -b.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: -s))
            .concatenating(CGAffineTransform(translationX: rect.midX - b.width * s / 2, y: rect.midY + b.height * s / 2))
    }

    /// `zoom` is how much the caller has already scaled `ctx` up by; lines are kept at least a
    /// hairline wide on screen whatever the zoom.
    public static func draw(_ sch: Schematic, in ctx: CGContext, rect: CGRect, zoom: CGFloat = 1) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(background)
        ctx.fill(rect)

        guard let t = pageTransform(sch, in: rect) else { return }
        ctx.concatenate(t)
        let s = t.a
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let hairline = 0.5 / (s * zoom)

        // Only what's on screen: with the page zoomed in, most of it isn't.
        let visible = ctx.boundingBoxOfClipPath.insetBy(dx: -2, dy: -2)
        let byKind = Dictionary(grouping: sch.items, by: \.kind)
        for kind in Schematic.Kind.allCases {
            let base = color(of: kind)
            for item in byKind[kind] ?? [] {
                let path = item.shape.path
                guard path.boundingBoxOfPath.insetBy(dx: -1, dy: -1).intersects(visible) else { continue }
                let c = item.color ?? base
                ctx.addPath(path)
                switch item.shape.style {
                case .fill:
                    ctx.setFillColor(c)
                    ctx.fillPath()
                case .stroke(let w):
                    ctx.setStrokeColor(c)
                    ctx.setLineWidth(max(w, hairline))
                    ctx.strokePath()
                }
            }
        }
    }
}
