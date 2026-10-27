import Cocoa

/// A view whose content can be zoomed (pinch, or a mouse wheel) and panned (two-finger scroll, or
/// click and drag).
/// Subclasses draw as if unzoomed, after concatenating `zoomTransform` onto the context. Content is
/// vector, so it is redrawn at every zoom level and stays sharp.
/// Zoom runs from 1 (the content fitted, as without zoom) to `maxZoom`; panning stops at the edges.
class ZoomPanView: NSView {
    private(set) var zoom: CGFloat = 1
    /// Where the unzoomed origin ends up, in view points.
    private(set) var offset: CGPoint = .zero
    var maxZoom: CGFloat = 40
    private var dragging = false

    /// Maps unzoomed view coordinates to what's on screen.
    var zoomTransform: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: offset.x, ty: offset.y)
    }

    func resetZoom() {
        guard zoom != 1 || offset != .zero else { return }
        zoom = 1
        offset = .zero
        zoomChanged()
    }

    /// Zooms to `newZoom`, keeping the content under `anchor` (view coordinates) where it is.
    func zoom(to newZoom: CGFloat, about anchor: CGPoint) {
        let z = min(max(newZoom, 1), maxZoom)
        let content = CGPoint(x: (anchor.x - offset.x) / zoom, y: (anchor.y - offset.y) / zoom)
        zoom = z
        offset = CGPoint(x: anchor.x - content.x * z, y: anchor.y - content.y * z)
        clampOffset()
        zoomChanged()
    }

    /// Moves the content by `dx`, `dy` view points (y up).
    func pan(dx: CGFloat, dy: CGFloat) {
        offset.x += dx
        offset.y += dy
        clampOffset()
        needsDisplay = true
    }

    private func zoomChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)        // an open hand only while there is somewhere to pan
    }

    override func magnify(with event: NSEvent) {
        zoom(to: zoom * (1 + event.magnification), about: convert(event.locationInWindow, from: nil))
    }

    /// Two-finger double-tap: zoom in 3× on that spot, or back out to fit.
    override func smartMagnify(with event: NSEvent) {
        if zoom > 1 { resetZoom() } else { zoom(to: 3, about: convert(event.locationInWindow, from: nil)) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {          // trackpad: pan with the fingers
            pan(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)   // y up here; deltas are y down
        } else {                                      // mouse wheel: zoom
            zoom(to: zoom * pow(1.1, event.scrollingDeltaY), about: convert(event.locationInWindow, from: nil))
        }
    }

    /// Double-click goes back to fit.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { resetZoom() } else { super.mouseDown(with: event) }
    }

    /// Dragging with the mouse pans, for those without a trackpad.
    override func mouseDragged(with event: NSEvent) {
        guard zoom > 1 else { return super.mouseDragged(with: event) }
        if !dragging {
            dragging = true
            NSCursor.closedHand.push()
        }
        pan(dx: event.deltaX, dy: -event.deltaY)      // deltas are y down
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            NSCursor.pop()
        }
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        if zoom > 1 { addCursorRect(bounds, cursor: .openHand) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampOffset()
    }

    /// Keeps the zoomed content covering the view, so it can't be panned out of sight.
    private func clampOffset() {
        offset.x = min(0, max(bounds.width * (1 - zoom), offset.x))
        offset.y = min(0, max(bounds.height * (1 - zoom), offset.y))
    }
}
