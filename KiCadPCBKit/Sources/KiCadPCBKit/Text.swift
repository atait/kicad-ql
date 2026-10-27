import CoreGraphics
import CoreText
import Foundation

/// gr_text / fp_text / property as filled glyph outlines in board mm.
///
/// `t` places the footprint (identity for board text); `keepUpright` turns footprint text that would
/// read upside down by 180°, as KiCad does unless the text is unlocked.
func textShapes(_ e: SExpr, _ text: String, _ t: CGAffineTransform, keepUpright: Bool) -> [Shape] {
    guard let at = e.first("at"), let x = at.number(1), let y = at.number(2) else { return [] }
    let unlocked = at.items.contains { $0.atom == "unlocked" } || e.first("unlocked")?.string(1) == "yes"
    let f = TextFormat(e)
    return textShapes(text, at: CGPoint(x: x, y: y).applying(t), angle: CGFloat(at.number(3) ?? 0),  // absolute, even in a footprint
                      size: f.size, justify: f.justify, keepUpright: keepUpright && !unlocked)
}

/// Size and justification from an item's (effects (font (size h w)) (justify …)).
struct TextFormat {
    var size: CGSize                       // width, height in mm
    var justify: Set<String>

    init(_ e: SExpr?) {
        let effects = e?.name == "effects" ? e : e?.first("effects")
        let size = effects?.first("font")?.first("size")
        let h = CGFloat(size?.number(1) ?? 1.27)                         // (size height width)
        self.size = CGSize(width: CGFloat(size?.number(2) ?? Double(h)), height: h)
        justify = Set((effects?.first("justify")?.items.dropFirst() ?? []).compactMap(\.atom))
    }
}

/// Text as filled glyph outlines, anchored at `at` (mm, y down) and turned by `angle` (degrees,
/// counter-clockwise on screen). `justify` takes KiCad's words: left/right (centred if neither),
/// top/bottom (centred if neither) and mirror. `keepUpright` turns text that would read upside down by
/// 180° about the anchor, keeping the justification.
///
/// KiCad's stroke font isn't available, so the system font stands in, scaled so its cap height is the
/// text height and its width follows width/height.
func textShapes(_ text: String, at: CGPoint, angle: CGFloat, size: CGSize, justify: Set<String>,
                keepUpright: Bool = false) -> [Shape] {
    guard !text.isEmpty else { return [] }
    let h = size.height, w = size.width
    var angle = angle
    if keepUpright {
        while angle > 90 { angle -= 180 }
        while angle <= -90 { angle += 180 }
    }

    // Lay the lines out in text space: mm, y down, origin at the anchor.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let pitch = h * 1.62                                              // KiCad's default line spacing
    let blockHeight = h + pitch * CGFloat(lines.count - 1)
    var baseline = justify.contains("top") ? h
                 : justify.contains("bottom") ? h - blockHeight
                 : h - blockHeight / 2
    let sy = h / TextFont.capHeight, sx = sy * w / h

    let glyphs = CGMutablePath()
    for line in lines {
        defer { baseline += pitch }
        guard !line.isEmpty else { continue }
        let ct = TextFont.line(line)
        let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)) * sx
        let x0 = justify.contains("left") ? 0 : justify.contains("right") ? -width : -width / 2
        for run in CTLineGetGlyphRuns(ct) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &pos)
            // fallback fonts (e.g. for symbols) come back as the run's font
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName]
                .map { $0 as! CTFont } ?? TextFont.font
            for (g, p) in zip(ids, pos) {
                guard let outline = CTFontCreatePathForGlyph(runFont, g, nil) else { continue }
                // glyphs are y-up font units: flip and scale them into text space
                glyphs.addPath(outline, transform: CGAffineTransform(a: sx, b: 0, c: 0, d: -sy,
                                                                     tx: x0 + p.x * sx, ty: baseline))
            }
        }
    }
    guard !glyphs.isEmpty else { return [] }

    var place = placement(at, angle)
    if justify.contains("mirror") { place = CGAffineTransform(scaleX: -1, y: 1).concatenating(place) }
    return glyphs.copy(using: &place).map { [Shape(path: $0, style: .fill)] } ?? []
}

/// The width and height of `text` as `textShapes` lays it out, unrotated.
func textExtent(_ text: String, size: CGSize) -> CGSize {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let sx = size.height / TextFont.capHeight * size.width / size.height
    let width = lines.map { CGFloat(CTLineGetTypographicBounds(TextFont.line(String($0)), nil, nil, nil)) * sx }.max() ?? 0
    return CGSize(width: width, height: size.height + size.height * 1.62 * CGFloat(lines.count - 1))
}

/// Whether KiCad hides this text: a bare `hide`, or `(hide yes)`, on the item or in its effects.
func isHidden(_ e: SExpr) -> Bool {
    func hides(_ x: SExpr?) -> Bool {
        guard let x else { return false }
        return x.items.contains { $0.atom == "hide" } || x.first("hide")?.string(1) == "yes"
    }
    return hides(e) || hides(e.first("effects"))
}

private enum TextFont {
    nonisolated(unsafe) static let font = CTFontCreateUIFontForLanguage(.system, 100, nil)!
    static let capHeight = CTFontGetCapHeight(font)

    static func line(_ s: String) -> CTLine {
        CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: font] as CFDictionary))
    }
}
