import Cocoa
import Quartz
import KiCadPCBKit

/// View-based preview: the board, with a legend of layer buttons in the top-left corner. Clicking a
/// layer brings it to the front (PCBRenderer's focus mode); clicking it again goes back to the overview.
/// Info.plist needs QLIsDataBasedPreview = NO and
/// NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).PreviewViewController.
class PreviewViewController: NSViewController, QLPreviewingController {
    private let boardView = BoardView()
    private let legend = LegendView()

    /// Below this size (e.g. Finder's column-view preview pane) the legend would cover the board.
    private static let minLegendSize = CGSize(width: 300, height: 220)

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let root = NSView()
        for v in [boardView, legend] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            boardView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            boardView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            boardView.topAnchor.constraint(equalTo: root.topAnchor),
            boardView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            legend.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            legend.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
        ])
        legend.isHidden = true
        legend.onSelect = { [weak self] layer in self?.boardView.setFocus(layer) }
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let size = view.bounds.size
        legend.isHidden = legend.layers.isEmpty
            || size.width < Self.minLegendSize.width || size.height < Self.minLegendSize.height
        boardView.avoid = legend.isHidden ? .zero : legend.frame.insetBy(dx: -8, dy: -8)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let board = try await Task.detached { try PCBBoard(url: url) }.value   // parse off the main thread
        boardView.board = board
        legend.layers = PCBRenderer.layers(of: board)
        preferredContentSize = board.fittedSize(in: CGSize(width: 1000, height: 800))
        view.needsLayout = true
    }
}

/// Draws the board, and cross-fades to the new picture when the focus changes.
final class BoardView: NSView {
    var board: PCBBoard? { didSet { needsDisplay = true } }
    /// A rect the board should stay clear of (the legend), in this view's coordinates.
    var avoid: CGRect = .zero { didSet { if avoid != oldValue { needsDisplay = true } } }
    private var focus: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setFocus(_ newFocus: String?) {          // not `layer`: that would hide NSView.layer below
        guard newFocus != focus else { return }
        focus = newFocus
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        layer?.add(fade, forKey: "focus")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let board, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(PCBRenderer.background)       // also behind the legend, beside the fitted board
        ctx.fill(bounds)
        PCBRenderer.draw(board, in: ctx, rect: boardRect(board), focus: focus)
    }

    /// Where to fit the board: the whole view if the board then misses `avoid`; otherwise the part beside
    /// or below `avoid`, whichever lets the board be drawn larger.
    private func boardRect(_ board: PCBBoard) -> CGRect {
        func fitted(_ r: CGRect) -> CGRect {
            let size = board.fittedSize(in: r.size)
            return CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
        }
        guard !avoid.isEmpty, fitted(bounds).intersects(avoid) else { return bounds }
        let (beside, _) = bounds.divided(atDistance: avoid.maxX - bounds.minX, from: .minXEdge)
        let (below, _) = bounds.divided(atDistance: bounds.maxY - avoid.minY, from: .maxYEdge)  // y up: legend is at the top
        let right = CGRect(x: beside.maxX, y: bounds.minY, width: bounds.maxX - beside.maxX, height: bounds.height)
        let under = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: below.minY - bounds.minY)
        return [right, under].max { fitted($0).width < fitted($1).width }!
    }
}

/// A frosted panel with one toggle button per layer, front to back. At most one is on.
final class LegendView: NSVisualEffectView {
    var onSelect: ((String?) -> Void)?
    var layers: [String] = [] { didSet { rebuild() } }
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow                 // adapts to light and dark mode by itself
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for layer in layers {
            let b = NSButton(title: Self.displayName(layer), image: Self.swatch(layer),
                             target: self, action: #selector(clicked))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .recessed
            b.imagePosition = .imageLeading
            b.alignment = .left
            b.identifier = NSUserInterfaceItemIdentifier(layer)
            b.toolTip = "Bring \(Self.displayName(layer)) to the front. Click again to show all layers."
            stack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        for case let b as NSButton in stack.arrangedSubviews where b !== sender { b.state = .off }
        onSelect?(sender.state == .on ? sender.identifier?.rawValue : nil)
    }

    private static func displayName(_ layer: String) -> String {
        switch layer {
        case "F.SilkS": "F.Silkscreen"
        case "B.SilkS": "B.Silkscreen"
        default: layer
        }
    }

    /// A small rounded square in the layer's colour, with a thin edge so the off-white silkscreen shows.
    private static func swatch(_ layer: String) -> NSImage {
        let color = NSColor(cgColor: PCBRenderer.color(of: layer)) ?? .gray
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
