import CoreGraphics

/// Rotation by a KiCad angle (degrees, counter-clockwise on screen, y down), then translation to `origin`.
func placement(_ origin: CGPoint, _ degrees: CGFloat) -> CGAffineTransform {
    let a = degrees * .pi / 180, c = cos(a), s = sin(a)
    return CGAffineTransform(a: c, b: -s, c: s, d: c, tx: origin.x, ty: origin.y)
}

func polyline(_ pts: [CGPoint], closed: Bool = false) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts)
    if closed { p.closeSubpath() }
    return p
}

/// Points along the circular arc from `a` through `m` to `b`.
func arcPoints(_ a: CGPoint, _ m: CGPoint, _ b: CGPoint) -> [CGPoint] {
    let d = 2 * (a.x * (m.y - b.y) + m.x * (b.y - a.y) + b.x * (a.y - m.y))
    if abs(d) < 1e-12 { return [a, b] }                              // collinear
    let a2 = a.x * a.x + a.y * a.y, m2 = m.x * m.x + m.y * m.y, b2 = b.x * b.x + b.y * b.y
    let cx = (a2 * (m.y - b.y) + m2 * (b.y - a.y) + b2 * (a.y - m.y)) / d
    let cy = (a2 * (b.x - m.x) + m2 * (a.x - b.x) + b2 * (m.x - a.x)) / d
    let r = hypot(a.x - cx, a.y - cy)
    let t0 = atan2(a.y - cy, a.x - cx), tm = atan2(m.y - cy, m.x - cx), t1 = atan2(b.y - cy, b.x - cx)
    func positive(_ x: CGFloat) -> CGFloat {
        let v = x.truncatingRemainder(dividingBy: 2 * .pi)
        return v < 0 ? v + 2 * .pi : v
    }
    let toMid = positive(tm - t0), toEnd = positive(t1 - t0)
    let sweep = toMid <= toEnd ? toEnd : toEnd - 2 * .pi              // the way that passes through m
    let steps = max(4, Int(abs(sweep) / (.pi / 32)))
    return (0...steps).map { k in
        let t = t0 + sweep * CGFloat(k) / CGFloat(steps)
        return CGPoint(x: cx + r * cos(t), y: cy + r * sin(t))
    }
}

/// (pts (xy x y) … (arc (start …)(mid …)(end …)) …)
func polyPoints(_ pts: SExpr) -> [CGPoint] {
    var out: [CGPoint] = []
    for it in pts.items.dropFirst() {
        switch it.name {
        case "xy":
            if let x = it.number(1), let y = it.number(2) { out.append(CGPoint(x: x, y: y)) }
        case "arc":
            if let s = it.point("start"), let m = it.point("mid"), let e = it.point("end") { out += arcPoints(s, m, e) }
        default:
            break
        }
    }
    return out
}

/// A pad-shaped outline centred on the origin of `t`. Trapezoids and chamfers are approximated.
func padOutline(_ shape: String, _ w: CGFloat, _ h: CGFloat, rratio: CGFloat, _ t: CGAffineTransform) -> CGPath {
    var t = t
    let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    let half = min(w, h) / 2
    switch shape {
    case "circle":
        return CGPath(ellipseIn: CGRect(x: -w / 2, y: -w / 2, width: w, height: w), transform: &t)
    case "oval":
        return half > 0 ? CGPath(roundedRect: r, cornerWidth: half, cornerHeight: half, transform: &t)
                        : CGPath(rect: r, transform: &t)
    case "roundrect":
        let c = min(rratio * min(w, h), half)
        return c > 0 ? CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: &t)
                     : CGPath(rect: r, transform: &t)
    default:
        return CGPath(rect: r, transform: &t)
    }
}

/// gr_/fp_ line, arc, circle, rect and poly (and pad primitives), mapped through `t`.
func graphicShapes(_ e: SExpr, _ t: CGAffineTransform, defaultFilled: Bool = false) -> [Shape] {
    guard let raw = e.name else { return [] }
    let kind = raw.hasPrefix("gr_") || raw.hasPrefix("fp_") ? String(raw.dropFirst(3)) : raw
    // KiCad 6+: (stroke (width w) …); pad primitives and older files: (width w)
    let width = CGFloat(e.first("stroke")?.first("width")?.number(1) ?? e.first("width")?.number(1) ?? 0)
    // KiCad 9+: (fill yes|no); KiCad 7–8: (fill solid|none); KiCad 5 has no fill token, and its polygons
    // are always filled
    let filled = e.first("fill")?.string(1).map { $0 == "yes" || $0 == "solid" } ?? (defaultFilled || kind == "poly")

    func out(_ path: CGPath, closed: Bool) -> [Shape] {
        var s: [Shape] = []
        if closed && filled { s.append(Shape(path: path, style: .fill)) }
        if width > 0 || s.isEmpty { s.append(Shape(path: path, style: .stroke(width))) }
        return s
    }
    switch kind {
    case "line":
        guard let a = e.point("start"), let b = e.point("end") else { return [] }
        return out(polyline([a, b].map { $0.applying(t) }), closed: false)
    case "arc":
        guard let a = e.point("start"), let m = e.point("mid"), let b = e.point("end") else { return [] }
        return out(polyline(arcPoints(a, m, b).map { $0.applying(t) }), closed: false)
    case "circle":
        guard let c = e.point("center"), let p = e.point("end") else { return [] }
        let r = hypot(p.x - c.x, p.y - c.y)
        var tt = t
        return out(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: &tt),
                   closed: true)
    case "rect":
        guard let a = e.point("start"), let b = e.point("end") else { return [] }
        let corners = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y)].map { $0.applying(t) }
        return out(polyline(corners, closed: true), closed: true)
    case "poly":
        guard let pts = e.first("pts") else { return [] }
        return out(polyline(polyPoints(pts).map { $0.applying(t) }, closed: true), closed: true)
    default:
        return []
    }
}
