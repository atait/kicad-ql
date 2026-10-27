import Cocoa
import KiCadPCBKit

/// Draws a schematic sheet, zoomable and pannable. Double-clicking a sub-sheet's box opens it, if the
/// sandbox lets the extension read that file (QuickLook usually grants only the file being previewed);
/// `onNavigate` then reports the path, so a bar can offer the way back.
final class SchematicView: ZoomPanView {
    /// One open sheet: the root first, then each sub-sheet gone into.
    private struct Level {
        let schematic: Schematic
        let url: URL
        let instancePath: String          // "/<root uuid>/<sheet uuid>…", picks the references shown
        let sheetPath: String             // "/ssen1/", for the title block and the bar
    }
    private var levels: [Level] = []

    /// Called with the sheet path ("/ssen1/") when a sub-sheet opens, nil when back at the root, and
    /// with an explanation when a sub-sheet couldn't be read.
    var onNavigate: ((_ sheetPath: String?, _ failure: String?) -> Void)?

    var schematic: Schematic? { levels.last?.schematic }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ root: Schematic, url: URL) {
        levels = [Level(schematic: root, url: url, instancePath: "/" + root.uuid, sheetPath: "/")]
        needsDisplay = true
    }

    /// Back to the sheet that contains this one.
    func goUp() {
        guard levels.count > 1 else { return }
        levels.removeLast()
        changedSheet()
        onNavigate?(levels.count > 1 ? levels.last?.sheetPath : nil, nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let schematic, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(SchematicRenderer.background)
        ctx.fill(bounds)
        ctx.concatenate(zoomTransform)
        SchematicRenderer.draw(schematic, in: ctx, rect: bounds, zoom: zoom)
    }

    /// Double-click on a sub-sheet opens it; anywhere else, back to fit.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let level = levels.last,
              let toView = SchematicRenderer.pageTransform(level.schematic, in: bounds) else {
            return super.mouseDown(with: event)
        }
        let p = convert(event.locationInWindow, from: nil)
            .applying(zoomTransform.inverted()).applying(toView.inverted())
        guard let sheet = level.schematic.sheets.first(where: { $0.rect.contains(p) }) else {
            return super.mouseDown(with: event)
        }
        let url = level.url.deletingLastPathComponent().appendingPathComponent(sheet.file)
        let path = level.sheetPath + sheet.name + "/"
        do {
            let sub = try Schematic(url: url, instancePath: level.instancePath + "/" + sheet.uuid, sheetPath: path)
            levels.append(Level(schematic: sub, url: url, instancePath: level.instancePath + "/" + sheet.uuid,
                                sheetPath: path))
            changedSheet()
            onNavigate?(path, nil)
        } catch {
            onNavigate?(levels.count > 1 ? level.sheetPath : nil,
                        "QuickLook can only read the file being previewed, so \(sheet.file) can't be opened here.")
        }
    }

    private func changedSheet() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.12
        layer?.add(fade, forKey: "fade")
        resetZoom()
        needsDisplay = true
    }
}

/// A frosted bar in the top-left corner: a back button while inside a sub-sheet, or a short message.
final class SheetBar: NSVisualEffectView {
    var onBack: (() -> Void)?
    private let back = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var hideMessage: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow                 // adapts to light and dark mode by itself
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        back.bezelStyle = .recessed
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        back.imagePosition = .imageLeading
        back.target = self
        back.action = #selector(backClicked)
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = 260
        let stack = NSStackView(views: [back, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(sheetPath: nil, failure: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the back button while `sheetPath` is set, and `failure` for a few seconds.
    func update(sheetPath: String?, failure: String?) {
        back.title = "Sheet \(sheetPath ?? "/")"
        back.toolTip = "Back to the sheet above."
        back.isHidden = sheetPath == nil
        message.stringValue = failure ?? ""
        message.isHidden = failure == nil
        hideMessage?.cancel()
        if failure != nil {
            let work = DispatchWorkItem { [weak self] in self?.update(sheetPath: sheetPath, failure: nil) }
            hideMessage = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
        isHidden = back.isHidden && message.isHidden
    }

    @objc private func backClicked() { onBack?() }
}
