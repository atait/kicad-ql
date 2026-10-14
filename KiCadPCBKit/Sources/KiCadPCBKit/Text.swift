import CoreGraphics
import CoreText
import Foundation

/// gr_text / fp_text / property as filled glyph outlines in board mm.
/// KiCad's own stroke font isn't available, so the system font stands in, scaled so its cap height is
/// the text's (size h w) height and its width follows w/h. TrueType faces and knockout are ignored.
///
/// `t` places the footprint (identity for board text); `keepUpright` turns footprint text that would
/// read upside down by 180°, as KiCad does unless the text is unlocked.
func textShapes(_ e: SExpr, _ text: String, _ t: CGAffineTransform, keepUpright: Bool) -> [Shape] {
    guard !text.isEmpty, let at = e.first("at"), let x = at.number(1), let y = at.number(2) else { return [] }
    let effects = e.first("effects")
    let font = effects?.first("font")
    let h = CGFloat(font?.first("size")?.number(1) ?? 1)            // (size height width)
    let w = CGFloat(font?.first("size")?.number(2) ?? Double(h))
    let justify = Set((effects?.first("justify")?.items.dropFirst() ?? []).compactMap(\.atom))

    var angle = CGFloat(at.number(3) ?? 0)                            // absolute, even inside a footprint
    let unlocked = at.items.contains { $0.atom == "unlocked" } || e.first("unlocked")?.string(1) == "yes"
    if keepUpright && !unlocked {
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
        let ct = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: TextFont.font] as CFDictionary))
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

    var place = placement(CGPoint(x: x, y: y).applying(t), angle)
    if justify.contains("mirror") { place = CGAffineTransform(scaleX: -1, y: 1).concatenating(place) }
    return glyphs.copy(using: &place).map { [Shape(path: $0, style: .fill)] } ?? []
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
}
