import Foundation
import CoreGraphics

public enum SchematicError: Error { case notASchematic }

/// One sheet of a .kicad_sch, flattened into shapes in sheet millimetres (y pointing down), each tagged
/// with what it is, so the renderer can colour it as KiCad's default theme does. Covers placed symbols
/// (body, pins, visible fields), wires, buses, bus entries, junctions, no-connects, labels, sheets and
/// their pins, notes and graphics, and the page frame with its title block.
///
/// Sub-sheets live in other files. They are drawn as boxes here; `sheets` says where they are, so a
/// viewer that is allowed to read the other file can open it as a `Schematic` of its own.
public final class Schematic: @unchecked Sendable {      // never mutated after init
    /// What an item is, in drawing order: fills first, text last.
    enum Kind: Int, CaseIterable {
        case bodyFill, sheetFill, frame, frameText, wire, bus, busEntry, body, pin, sheet, noConnect,
             junction, busJunction, graphic, reference, value, field, pinName, pinNumber, label,
             globalLabel, hierLabel, sheetPin, sheetName, sheetFile, note
    }
    struct Item {
        let shape: Shape
        let kind: Kind
        var color: CGColor? = nil                        // an explicit colour from the file
    }

    public struct Sheet: Sendable {
        public let name: String
        public let file: String
        public let rect: CGRect
        /// The sheet's UUID, which extends the instance path of symbols inside it.
        public let uuid: String
    }

    private(set) var items: [Item] = []
    public private(set) var sheets: [Sheet] = []
    /// The page.
    public private(set) var bounds: CGRect = .zero
    public private(set) var uuid = ""

    private var library: [String: SExpr] = [:]
    private var instancePath = ""
    private var busSegments: [(CGPoint, CGPoint)] = []

    static let lineWidth: CGFloat = 0.1524, busWidth: CGFloat = 0.3048

    /// `instancePath` picks which references to show when a sheet is used more than once, e.g.
    /// "/<root uuid>/<sheet uuid>". Leave it nil for a root sheet. `sheetPath` and the file name only
    /// go in the title block.
    public convenience init(url: URL, instancePath: String? = nil, sheetPath: String = "/") throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), instancePath: instancePath,
                      fileName: url.lastPathComponent, sheetPath: sheetPath)
    }

    public init(data: Data, instancePath: String? = nil, fileName: String = "", sheetPath: String = "/") throws {
        let root = try SExprParser.parse(data)
        guard root.name == "kicad_sch" else { throw SchematicError.notASchematic }
        uuid = root.first("uuid")?.string(1) ?? ""
        self.instancePath = instancePath ?? "/" + uuid
        for s in root.first("lib_symbols")?.all("symbol") ?? [] {
            if let id = s.string(1) { library[id] = s }
        }

        for e in root.items.dropFirst() where e.name == "bus" {      // junctions on a bus take its colour
            let pts = polyPoints(e.first("pts") ?? .list([]))
            for (a, b) in zip(pts, pts.dropFirst()) { busSegments.append((a, b)) }
        }
        for e in root.items.dropFirst() {
            switch e.name {
            case "symbol": symbol(e)
            case "wire": line(e, .wire, Self.lineWidth)
            case "bus": line(e, .bus, Self.busWidth)
            case "bus_entry": busEntry(e)
            case "junction": junction(e)
            case "no_connect": noConnect(e)
            case "label": label(e)
            case "global_label": flagLabel(e, global: true)
            case "hierarchical_label": flagLabel(e, global: false)
            case "sheet": sheet(e)
            case "text": note(e)
            case "text_box": textBox(e)
            case "polyline", "rectangle", "circle", "arc", "bezier": graphic(e)
            default: break
            }
        }
        frame(root, fileName: fileName, sheetPath: sheetPath)
    }

    /// The largest size with the page's aspect ratio that fits in `box`.
    public func fittedSize(in box: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return box }
        let s = min(box.width / bounds.width, box.height / bounds.height)
        return CGSize(width: max(1, (bounds.width * s).rounded()), height: max(1, (bounds.height * s).rounded()))
    }

    // MARK: - helpers

    private func add(_ shapes: [Shape], _ kind: Kind, _ color: CGColor? = nil) {
        for s in shapes { items.append(Item(shape: s, kind: kind, color: color)) }
    }

    private func stroke(_ path: CGPath, _ width: CGFloat, _ kind: Kind, _ color: CGColor? = nil) {
        add([Shape(path: path, style: .stroke(width))], kind, color)
    }

    private func text(_ s: String, at p: CGPoint, angle: CGFloat = 0, _ f: TextFormat, _ kind: Kind,
                      _ color: CGColor? = nil) {
        add(textShapes(s, at: p, angle: angle, size: f.size, justify: f.justify, keepUpright: true), kind, color)
    }

    /// (stroke (width w) (color r g b a)): the width, or `fallback` for 0; the colour unless it is 0 0 0 0.
    private func strokeOf(_ e: SExpr, fallback: CGFloat) -> (CGFloat, CGColor?) {
        let s = e.first("stroke")
        let w = CGFloat(s?.first("width")?.number(1) ?? e.first("width")?.number(1) ?? 0)
        return (w > 0 ? w : fallback, color(s?.first("color")))
    }

    /// (color r g b a) with 0–255 channels; nil when all zero, which means "use the theme".
    private func color(_ c: SExpr?) -> CGColor? {
        guard let c, let r = c.number(1), let g = c.number(2), let b = c.number(3) else { return nil }
        let a = c.number(4) ?? 1
        if r == 0 && g == 0 && b == 0 && a == 0 { return nil }
        return CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    /// The unit vector for a KiCad angle on the sheet (y down): 0 → right, 90 → up.
    private static func direction(_ degrees: CGFloat) -> CGVector {
        let a = degrees * .pi / 180
        return CGVector(dx: cos(a).rounded(toPlaces: 9), dy: -sin(a).rounded(toPlaces: 9))
    }

    /// The angle text along `d` is drawn at, read left to right or bottom to top, and how it is
    /// justified so that it runs away from its anchor.
    private static func textRun(_ d: CGVector) -> (angle: CGFloat, justify: String) {
        abs(d.dx) >= abs(d.dy) ? (0, d.dx > 0 ? "left" : "right") : (90, d.dy < 0 ? "left" : "right")
    }

    // MARK: - wires, buses, junctions

    private func line(_ e: SExpr, _ kind: Kind, _ width: CGFloat) {
        guard let pts = e.first("pts") else { return }
        let (w, c) = strokeOf(e, fallback: width)
        stroke(polyline(polyPoints(pts)), w, kind, c)
    }

    private func busEntry(_ e: SExpr) {
        guard let a = e.point("at"), let s = e.first("size"), let dx = s.number(1), let dy = s.number(2) else { return }
        let (w, c) = strokeOf(e, fallback: Self.lineWidth)
        stroke(polyline([a, CGPoint(x: a.x + dx, y: a.y + dy)]), w, .busEntry, c)
    }

    private func junction(_ e: SExpr) {
        guard let p = e.point("at") else { return }
        let d = CGFloat(e.first("diameter")?.number(1) ?? 0)
        let r = (d > 0 ? d : 0.9144) / 2
        let onBus = busSegments.contains { a, b in
            abs((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) < 1e-6
                && p.x >= min(a.x, b.x) - 1e-6 && p.x <= max(a.x, b.x) + 1e-6
                && p.y >= min(a.y, b.y) - 1e-6 && p.y <= max(a.y, b.y) + 1e-6
        }
        let dot = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
        add([Shape(path: dot, style: .fill)], onBus ? .busJunction : .junction, color(e.first("color")))
    }

    private func noConnect(_ e: SExpr) {
        guard let p = e.point("at") else { return }
        let r: CGFloat = 0.6096
        let x = CGMutablePath()
        x.move(to: CGPoint(x: p.x - r, y: p.y - r)); x.addLine(to: CGPoint(x: p.x + r, y: p.y + r))
        x.move(to: CGPoint(x: p.x - r, y: p.y + r)); x.addLine(to: CGPoint(x: p.x + r, y: p.y - r))
        stroke(x, Self.lineWidth, .noConnect)
    }

    // MARK: - labels

    /// Local label: text sitting just above the wire, at its anchor.
    private func label(_ e: SExpr) {
        guard let s = e.string(1), let at = e.first("at"), let x = at.number(1), let y = at.number(2) else { return }
        placeText(s, CGPoint(x: x, y: y), CGFloat(at.number(3) ?? 0), TextFormat(e), lift: 0.35, .label)
    }

    /// Free text (a note), lifted a little off its anchor as KiCad does.
    private func note(_ e: SExpr) {
        guard let s = e.string(1), let at = e.first("at"), let x = at.number(1), let y = at.number(2) else { return }
        placeText(s, CGPoint(x: x, y: y), CGFloat(at.number(3) ?? 0), TextFormat(e), lift: 0.25, .note)
    }

    /// Text at a KiCad angle, turned to read upright with the file's justification, and moved `lift`
    /// towards the text's top.
    private func placeText(_ s: String, _ p: CGPoint, _ angle: CGFloat, _ f: TextFormat, lift: CGFloat, _ kind: Kind) {
        let a = angle.truncatingRemainder(dividingBy: 180)              // 180 → 0, 270 → 90
        let up = Self.direction(a + 90)
        text(clean(s), at: CGPoint(x: p.x + up.dx * lift, y: p.y + up.dy * lift), angle: a, f, kind)
    }

    /// Global and hierarchical labels: an outline by `shape` at the anchor, the text running away from it.
    private func flagLabel(_ e: SExpr, global: Bool) {
        guard let s = e.string(1), let at = e.first("at"), let x = at.number(1), let y = at.number(2) else { return }
        let shape = e.first("shape")?.string(1) ?? "passive"
        let f = TextFormat(e)
        let p = CGPoint(x: x, y: y), d = Self.direction(CGFloat(at.number(3) ?? 0))
        if global { globalOutline(clean(s), p, d, shape, f) } else { hierOutline(clean(s), p, d, shape, f, .hierLabel) }
    }

    /// Points given as (along, across) the label's direction `d`, from the anchor `p`.
    private static func outline(_ p: CGPoint, _ d: CGVector, _ pts: [(CGFloat, CGFloat)]) -> CGPath {
        polyline(pts.map { a, c in CGPoint(x: p.x + a * d.dx - c * d.dy, y: p.y + a * d.dy + c * d.dx) }, closed: true)
    }

    private func globalOutline(_ s: String, _ p: CGPoint, _ d: CGVector, _ shape: String, _ f: TextFormat) {
        let h = f.size.height, margin = 0.3125 * h, hs = h / 2 + margin
        let x = textExtent(s, size: f.size).width + 2 * margin, y = hs
        let pts: [(CGFloat, CGFloat)]
        switch shape {
        case "input": pts = [(0, 0), (hs, -y), (x + hs, -y), (x + hs, y), (hs, y)]
        case "output": pts = [(0, -y), (x, -y), (x + hs, 0), (x, y), (0, y)]
        case "bidirectional", "tri_state": pts = [(0, 0), (hs, -y), (x + hs, -y), (x + 2 * hs, 0), (x + hs, y), (hs, y)]
        default: pts = [(0, -y), (x, -y), (x, y), (0, y)]
        }
        stroke(Self.outline(p, d, pts), Self.lineWidth, .globalLabel)
        let start = (shape == "input" || shape == "bidirectional" || shape == "tri_state" ? hs : 0) + margin
        runText(s, p, d, start, f, .globalLabel)
    }

    /// Hierarchical labels and sheet pins: a small arrow (or box, or diamond) one text height long.
    private func hierOutline(_ s: String, _ p: CGPoint, _ d: CGVector, _ shape: String, _ f: TextFormat, _ kind: Kind) {
        let u = f.size.height / 2
        let pts: [(CGFloat, CGFloat)]
        switch shape {
        case "input": pts = [(0, 0), (u, -u), (2 * u, -u), (2 * u, u), (u, u)]
        case "output": pts = [(2 * u, 0), (u, -u), (0, -u), (0, u), (u, u)]
        case "bidirectional", "tri_state": pts = [(0, 0), (u, -u), (2 * u, 0), (u, u)]
        default: pts = [(0, -u), (2 * u, -u), (2 * u, u), (0, u)]
        }
        stroke(Self.outline(p, d, pts), Self.lineWidth, kind)
        runText(s, p, d, 2 * u + 0.15 * f.size.height, f, kind)
    }

    /// Text starting `start` from `p` along `d`, centred across it.
    private func runText(_ s: String, _ p: CGPoint, _ d: CGVector, _ start: CGFloat, _ f: TextFormat, _ kind: Kind) {
        let (angle, justify) = Self.textRun(d)
        var f = f
        f.justify = [justify]
        text(s, at: CGPoint(x: p.x + d.dx * start, y: p.y + d.dy * start), angle: angle, f, kind)
    }

    /// Drops ${…} fields such as ${INTERSHEET_REFS}, which need the whole project to fill in.
    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\$\{[^}]*\}"#, with: "", options: .regularExpression)
    }

    // MARK: - sheets

    private func sheet(_ e: SExpr) {
        guard let at = e.point("at"), let size = e.first("size"), let w = size.number(1), let h = size.number(2) else { return }
        let rect = CGRect(x: at.x, y: at.y, width: w, height: h)
        let (lw, c) = strokeOf(e, fallback: Self.lineWidth)
        if let fill = color(e.first("fill")?.first("color")) {
            add([Shape(path: CGPath(rect: rect, transform: nil), style: .fill)], .sheetFill, fill)
        }
        stroke(CGPath(rect: rect, transform: nil), lw, .sheet, c)

        var name = "", file = ""
        for p in e.all("property") {
            guard let key = p.string(1), let value = p.string(2) else { continue }
            if key == "Sheetname" || key == "Sheet name" { name = value }
            if key == "Sheetfile" || key == "Sheet file" { file = value }
            guard !isHidden(p), !value.isEmpty, let pa = p.first("at"), let x = pa.number(1), let y = pa.number(2) else { continue }
            let shown = key == "Sheetfile" || key == "Sheet file" ? "File: \(value)"
                      : p.first("show_name")?.string(1) == "yes" ? "\(key): \(value)" : value
            let kind: Kind = key.hasPrefix("Sheetfile") || key == "Sheet file" ? .sheetFile
                           : key == "Sheetname" || key == "Sheet name" ? .sheetName : .field
            text(shown, at: CGPoint(x: x, y: y), angle: CGFloat(pa.number(3) ?? 0), TextFormat(p), kind)
        }
        sheets.append(Sheet(name: name, file: file, rect: rect, uuid: e.first("uuid")?.string(1) ?? ""))

        // (pin "DI" input (at x y side)): the side angle points out of the sheet; shape and text go inwards.
        for pin in e.all("pin") {
            guard let s = pin.string(1), let pa = pin.first("at"), let x = pa.number(1), let y = pa.number(2) else { continue }
            let out = Self.direction(CGFloat(pa.number(3) ?? 0))
            // drawn from inside the sheet, so an input arrow points in and an output arrow points out
            let shape = switch pin.string(2) { case "input": "output"; case "output": "input"; case let other?: other; default: "passive" }
            hierOutline(clean(s), CGPoint(x: x, y: y), CGVector(dx: -out.dx, dy: -out.dy), shape, TextFormat(pin), .sheetPin)
        }
    }

    // MARK: - notes and graphics

    private func graphic(_ e: SExpr) {
        let (w, c) = strokeOf(e, fallback: Self.lineWidth)
        let fill = e.first("fill")
        let fillColor = fill?.first("type")?.string(1) == "color" ? color(fill?.first("color")) : nil
        guard let path = Self.graphicPath(e, .identity) else { return }
        if let fillColor { add([Shape(path: path, style: .fill)], .graphic, fillColor) }
        stroke(path, w, .graphic, c)
    }

    private func textBox(_ e: SExpr) {
        guard let s = e.string(1), let at = e.first("at"), let x = at.number(1), let y = at.number(2),
              let size = e.first("size"), let w = size.number(1), let h = size.number(2) else { return }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let (lw, c) = strokeOf(e, fallback: Self.lineWidth)
        if e.first("stroke")?.first("type")?.string(1) != "none" { stroke(CGPath(rect: rect, transform: nil), lw, .graphic, c) }
        var f = TextFormat(e)
        f.justify = ["left", "top"]
        let m = f.size.height * 0.5
        text(clean(s), at: CGPoint(x: rect.minX + m, y: rect.minY + m), f, .note)
    }

    /// polyline, rectangle, circle, arc and bezier, as found both on sheets and in library symbols.
    static func graphicPath(_ e: SExpr, _ t: CGAffineTransform) -> CGPath? {
        switch e.name {
        case "polyline":
            guard let pts = e.first("pts") else { return nil }
            return polyline(polyPoints(pts).map { $0.applying(t) })
        case "rectangle":
            guard let a = e.point("start"), let b = e.point("end") else { return nil }
            return polyline([a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y)].map { $0.applying(t) }, closed: true)
        case "circle":
            guard let c = e.point("center"), let r = e.first("radius")?.number(1) else { return nil }
            var tt = t
            return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: &tt)
        case "arc":
            guard let a = e.point("start"), let m = e.point("mid"), let b = e.point("end") else { return nil }
            return polyline(arcPoints(a, m, b).map { $0.applying(t) })
        case "bezier":
            guard let pts = e.first("pts").map(polyPoints), pts.count == 4 else { return nil }
            let p = CGMutablePath()
            p.move(to: pts[0].applying(t))
            p.addCurve(to: pts[3].applying(t), control1: pts[1].applying(t), control2: pts[2].applying(t))
            return p
        default:
            return nil
        }
    }

    // MARK: - symbols

    /// A placed symbol: its library graphics and pins for the placed unit, and its visible fields.
    private func symbol(_ e: SExpr) {
        guard let at = e.first("at"), let x = at.number(1), let y = at.number(2),
              let id = e.first("lib_name")?.string(1) ?? e.first("lib_id")?.string(1) else { return }
        let rotation = CGFloat(at.number(3) ?? 0)
        let mirror = e.first("mirror")?.string(1)
        // On the sheet: rotate (counter-clockwise on screen), then mirror, about the symbol's origin.
        var orient = placement(.zero, rotation)
        if mirror == "x" { orient = orient.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
        if mirror == "y" { orient = orient.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        // Library coordinates point y up.
        let t = CGAffineTransform(scaleX: 1, y: -1).concatenating(orient)
            .concatenating(CGAffineTransform(translationX: x, y: y))

        let instance = instance(of: e)
        let unit = instance.unit ?? Int(e.first("unit")?.number(1) ?? 1)
        let bodyStyle = Int(e.first("body_style")?.number(1) ?? e.first("convert")?.number(1) ?? 1)
        var unitCount = 1
        if let lib = library[id] { unitCount = drawLibrary(lib, unit: unit, bodyStyle: bodyStyle, t) }

        for p in e.all("property") {
            guard var value = p.string(2), let key = p.string(1), !isHidden(p) else { continue }
            if key == "Reference" {
                value = instance.reference ?? value
                if unitCount > 1, !value.hasSuffix("?") { value += Self.unitLetter(unit) }
            }
            value = clean(value)
            guard !value.isEmpty else { continue }
            if p.first("show_name")?.string(1) == "yes" { value = "\(key): \(value)" }
            let kind: Kind = key == "Reference" ? .reference : key == "Value" ? .value : .field
            field(value, p, orient, kind)
        }
    }

    /// 1 → "A", 2 → "B", … 27 → "AA".
    private static func unitLetter(_ unit: Int) -> String {
        var n = unit, s = ""
        while n > 0 {
            s = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// The reference and unit this sheet instance uses, from (instances (project … (path "/…" (reference …) (unit …)))).
    private func instance(of e: SExpr) -> (reference: String?, unit: Int?) {
        let paths = (e.first("instances")?.all("project") ?? []).flatMap { $0.all("path") }
        guard let p = paths.first(where: { $0.string(1) == instancePath }) ?? paths.first else { return (nil, nil) }
        return (p.first("reference")?.string(1), p.first("unit")?.number(1).map { Int($0) })
    }

    /// A placed symbol's field. Fields are stored unrotated: KiCad lays the text box out at the field's
    /// own angle and justification, turns that box about the field's position as the symbol is turned,
    /// and draws the text centred in it, horizontal or vertical.
    private func field(_ s: String, _ p: SExpr, _ orient: CGAffineTransform, _ kind: Kind) {
        guard let pa = p.first("at"), let x = pa.number(1), let y = pa.number(2) else { return }
        let f = TextFormat(p)
        let fieldAngle = CGFloat(pa.number(3) ?? 0)
        let size = textExtent(s, size: f.size)
        let x0: CGFloat = f.justify.contains("left") ? 0 : f.justify.contains("right") ? -size.width : -size.width / 2
        let y0: CGFloat = f.justify.contains("top") ? 0 : f.justify.contains("bottom") ? -size.height : -size.height / 2
        let box = CGRect(x: x0, y: y0, width: size.width, height: size.height)
            .applying(placement(.zero, fieldAngle).concatenating(orient))
        let turned = abs(orient.b) > 0.5                                     // symbol at 90° or 270°
        let vertical = (Int(fieldAngle.rounded()) / 90 % 2 == 1) != turned
        var centred = f
        centred.justify = []
        text(s, at: CGPoint(x: x + box.midX, y: y + box.midY), angle: vertical ? 90 : 0, centred, kind)
    }

    /// Draws the library symbol's shared items and the given unit's, and returns how many units it has.
    private func drawLibrary(_ lib: SExpr, unit: Int, bodyStyle: Int, _ t: CGAffineTransform) -> Int {
        let pinNames = lib.first("pin_names")
        let nameOffset = CGFloat(pinNames?.first("offset")?.number(1) ?? 0.508)
        let namesHidden = pinNames.map(isHidden) ?? false
        let numbersHidden = lib.first("pin_numbers").map(isHidden) ?? false
        let libName = (lib.string(1) ?? "").split(separator: ":").last.map(String.init) ?? ""

        var units = 1
        for sub in lib.all("symbol") {
            // "Name_U_S": unit U (0 = all units), body style S (0 = both)
            let parts = (sub.string(1) ?? "").split(separator: "_")
            guard parts.count >= 2, let u = Int(parts[parts.count - 2]), let s = Int(parts[parts.count - 1]) else { continue }
            units = max(units, u)
            guard sub.string(1)?.hasPrefix(libName) ?? true, u == 0 || u == unit, s == 0 || s == bodyStyle else { continue }
            for item in sub.items.dropFirst() {
                switch item.name {
                case "pin":
                    pin(item, t, nameOffset: nameOffset, namesHidden: namesHidden, numbersHidden: numbersHidden)
                case "text":
                    libText(item, t)
                default:
                    guard let path = Self.graphicPath(item, t) else { continue }
                    let (w, c) = strokeOf(item, fallback: Self.lineWidth)
                    let fill = item.first("fill")?.first("type")?.string(1) ?? item.first("fill")?.string(1)
                    switch fill {
                    case "outline": add([Shape(path: path, style: .fill)], .body, c)
                    case "background": add([Shape(path: path, style: .fill)], .bodyFill)
                    case "color": add([Shape(path: path, style: .fill)], .bodyFill, color(item.first("fill")?.first("color")))
                    default: break
                    }
                    stroke(path, w, .body, c)
                }
            }
        }
        return units
    }

    private func libText(_ e: SExpr, _ t: CGAffineTransform) {
        guard let s = e.string(1), let at = e.first("at"), let x = at.number(1), let y = at.number(2), !isHidden(e) else { return }
        var angle = CGFloat(at.number(3) ?? 0)
        if angle > 360 { angle /= 10 }                                     // some versions store tenths
        let d = CGVector(dx: cos(angle * .pi / 180), dy: sin(angle * .pi / 180))   // in library space, y up
        let p = CGPoint(x: x, y: y).applying(t), q = CGPoint(x: x + d.dx, y: y + d.dy).applying(t)
        let vertical = abs(q.y - p.y) > abs(q.x - p.x)
        text(clean(s), at: p, angle: vertical ? 90 : 0, TextFormat(e), .body)
    }

    /// (pin type style (at x y angle) (length l) (name "…") (number "…")): the pin's line from its
    /// connection point towards the body, its name inside the body (or above the line when the
    /// symbol's name offset is 0) and its number above the line.
    private func pin(_ e: SExpr, _ t: CGAffineTransform, nameOffset: CGFloat, namesHidden: Bool, numbersHidden: Bool) {
        guard !isHidden(e), let at = e.first("at"), let x = at.number(1), let y = at.number(2) else { return }
        let length = CGFloat(e.first("length")?.number(1) ?? 2.54)
        let a = CGFloat(at.number(3) ?? 0) * .pi / 180
        let start = CGPoint(x: x, y: y)
        let tip = CGPoint(x: start.x + length * cos(a).rounded(toPlaces: 9), y: start.y + length * sin(a).rounded(toPlaces: 9))
        let p0 = start.applying(t), p1 = tip.applying(t)
        guard length > 0 else { return }
        let d = CGVector(dx: (p1.x - p0.x) / length, dy: (p1.y - p0.y) / length)     // towards the body

        let r: CGFloat = 0.635
        let style = e.string(2) ?? "line"
        let inverted = style.hasPrefix("inverted")
        let lineEnd = inverted ? CGPoint(x: p1.x - d.dx * 2 * r, y: p1.y - d.dy * 2 * r) : p1
        stroke(polyline([p0, lineEnd]), Self.lineWidth, .pin)
        if inverted {
            let c = CGPoint(x: p1.x - d.dx * r, y: p1.y - d.dy * r)
            stroke(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil),
                   Self.lineWidth, .pin)
        }
        if style.hasSuffix("clock") {
            stroke(polyline([CGPoint(x: p1.x - d.dy * r, y: p1.y + d.dx * r), CGPoint(x: p1.x + d.dx * r, y: p1.y + d.dy * r),
                             CGPoint(x: p1.x + d.dy * r, y: p1.y - d.dx * r)]), Self.lineWidth, .body)
        }

        let name = e.first("name").flatMap { $0.string(1) } ?? ""
        let number = e.first("number").flatMap { $0.string(1) } ?? ""
        let showName = !namesHidden && !name.isEmpty && name != "~"
        let showNumber = !numbersHidden && !number.isEmpty
        let (angle, _) = Self.textRun(d)
        let horizontal = angle == 0
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let gap: CGFloat = 0.25
        // beside the line: "above" is up for a horizontal pin and to the left for a vertical one
        func beside(_ s: String, _ f: TextFormat, above: Bool, _ kind: Kind) {
            var f = f
            f.justify = [above ? "bottom" : "top"]
            let off = above ? -gap : gap
            text(s, at: horizontal ? CGPoint(x: mid.x, y: mid.y + off) : CGPoint(x: mid.x + off, y: mid.y),
                 angle: angle, f, kind)
        }
        if showName {
            let f = TextFormat(e.first("name")?.first("effects"))
            if nameOffset > 0 {
                runText(name, p1, d, nameOffset, f, .pinName)
            } else {
                beside(name, f, above: true, .pinName)
            }
        }
        if showNumber {
            beside(number, TextFormat(e.first("number")?.first("effects")), above: !(showName && nameOffset == 0), .pinNumber)
        }
    }

    // MARK: - page

    static let paperSizes: [String: CGSize] = [
        "A5": CGSize(width: 210, height: 148), "A4": CGSize(width: 297, height: 210),
        "A3": CGSize(width: 420, height: 297), "A2": CGSize(width: 594, height: 420),
        "A1": CGSize(width: 841, height: 594), "A0": CGSize(width: 1189, height: 841),
        "A": CGSize(width: 279.4, height: 215.9), "B": CGSize(width: 431.8, height: 279.4),
        "C": CGSize(width: 558.8, height: 431.8), "D": CGSize(width: 863.6, height: 558.8),
        "E": CGSize(width: 1117.6, height: 863.6), "USLetter": CGSize(width: 279.4, height: 215.9),
        "USLegal": CGSize(width: 355.6, height: 215.9), "USLedger": CGSize(width: 431.8, height: 279.4),
    ]

    /// (paper "A4" [portrait]) or (paper "User" w h)
    static func pageSize(_ paper: SExpr?) -> CGSize {
        guard let paper, let name = paper.string(1) else { return paperSizes["A4"]! }
        var size = name == "User" ? CGSize(width: paper.number(2) ?? 297, height: paper.number(3) ?? 210)
                                  : paperSizes[name] ?? paperSizes["A4"]!
        if paper.items.contains(where: { $0.atom == "portrait" }) { size = CGSize(width: size.height, height: size.width) }
        return size
    }

    /// KiCad's default drawing sheet: a double border with zone numbers and letters, and the title block
    /// in the bottom right corner.
    private func frame(_ root: SExpr, fileName: String, sheetPath: String) {
        let paper = root.first("paper")
        let size = Self.pageSize(paper)
        bounds = CGRect(origin: .zero, size: size)
        let outer = bounds.insetBy(dx: 10, dy: 10), inner = bounds.insetBy(dx: 12, dy: 12)
        let w = Self.lineWidth
        stroke(CGPath(rect: outer, transform: nil), w, .frame)
        stroke(CGPath(rect: inner, transform: nil), w, .frame)

        // zones every 50 mm: numbers along the top and bottom, letters down the sides
        let small = TextFormat.plain(1.3)
        let ticks = CGMutablePath()
        var i = 0
        while outer.minX + CGFloat(i) * 50 < outer.maxX {
            let x0 = outer.minX + CGFloat(i) * 50, x1 = min(x0 + 50, outer.maxX)
            if i > 0 {
                for (a, b) in [(outer.minY, inner.minY), (inner.maxY, outer.maxY)] {
                    ticks.move(to: CGPoint(x: x0, y: a)); ticks.addLine(to: CGPoint(x: x0, y: b))
                }
            }
            for y in [outer.minY + 1, outer.maxY - 1] { text("\(i + 1)", at: CGPoint(x: (x0 + x1) / 2, y: y), small, .frameText) }
            i += 1
        }
        i = 0
        while outer.minY + CGFloat(i) * 50 < outer.maxY {
            let y0 = outer.minY + CGFloat(i) * 50, y1 = min(y0 + 50, outer.maxY)
            if i > 0 {
                for (a, b) in [(outer.minX, inner.minX), (inner.maxX, outer.maxX)] {
                    ticks.move(to: CGPoint(x: a, y: y0)); ticks.addLine(to: CGPoint(x: b, y: y0))
                }
            }
            for x in [outer.minX + 1, outer.maxX - 1] {
                text(Self.unitLetter(i + 1), at: CGPoint(x: x, y: (y0 + y1) / 2), small, .frameText)
            }
            i += 1
        }
        stroke(ticks, w, .frame)

        // title block, 108 × 32 mm in the inner corner
        let r = inner.maxX, b = inner.maxY
        stroke(CGPath(rect: CGRect(x: r - 108, y: b - 32, width: 108, height: 32), transform: nil), w, .frame)
        let rules = CGMutablePath()
        for dy in [3.5, 6.5, 10.5, 16.5] as [CGFloat] {
            rules.move(to: CGPoint(x: r - 108, y: b - dy)); rules.addLine(to: CGPoint(x: r, y: b - dy))
        }
        rules.move(to: CGPoint(x: r - 88, y: b - 6.5)); rules.addLine(to: CGPoint(x: r - 88, y: b - 3.5))
        rules.move(to: CGPoint(x: r - 24, y: b - 6.5)); rules.addLine(to: CGPoint(x: r - 24, y: b))
        stroke(rules, w, .frame)

        let tb = root.first("title_block")
        func field(_ key: String) -> String { tb?.first(key)?.string(1) ?? "" }
        func comment(_ n: Int) -> String {
            tb?.all("comment").first { $0.number(1) == Double(n) }?.string(2) ?? ""
        }
        let f = TextFormat.plain(1.5, justify: ["left", "bottom"])
        let paperName = paper?.string(1) ?? "A4"
        let lines: [(String, CGFloat, CGFloat, TextFormat)] = [
            ("Sheet: \(sheetPath)", r - 107, b - 14.25, f),
            ("File: \(fileName)", r - 107, b - 11.55, f),
            ("Title: \(field("title"))", r - 107, b - 7.7, .plain(2, justify: ["left", "bottom"])),
            ("Size: \(paperName)", r - 107, b - 4.15, f),
            ("Date: \(field("date"))", r - 85, b - 4.15, f),
            ("Rev: \(field("rev"))", r - 22, b - 4.15, f),
            ("KiCad E.D.A.", r - 107, b - 1.35, .plain(1.25, justify: ["left", "bottom"])),
            (field("company"), r - 107, b - 17.25, f),
            (comment(1), r - 107, b - 20.25, f), (comment(2), r - 107, b - 23.25, f),
            (comment(3), r - 107, b - 26.25, f), (comment(4), r - 107, b - 29.25, f),
        ]
        for (s, x, y, f) in lines where !s.isEmpty { text(s, at: CGPoint(x: x, y: y), f, .frameText) }
    }
}

extension TextFormat {
    static func plain(_ h: CGFloat, justify: Set<String> = []) -> TextFormat {
        var f = TextFormat(nil)
        f.size = CGSize(width: h, height: h)
        f.justify = justify
        return f
    }
}

private extension CGFloat {
    /// Rounds away floating-point dust, so cos(90°) is exactly 0.
    func rounded(toPlaces n: Int) -> CGFloat {
        let m = pow(10, CGFloat(n))
        return (self * m).rounded() / m
    }
}
