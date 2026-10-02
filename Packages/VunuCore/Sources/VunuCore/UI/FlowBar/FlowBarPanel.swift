import AppKit
import SwiftUI

/// Non-activating floating panel that hosts the Flow Bar. Appears over full-screen apps and on every Space,
/// never takes key focus from the app being dictated into.
public final class FlowBarPanel: NSPanel {
    public var onRightClick: ((NSEvent) -> Void)?
    public var onDragEnded: (() -> Void)?
    private var dragOffset: CGPoint?
    private var dragStartOrigin: CGPoint?
    public var isDragging: Bool { dragOffset != nil }

    public init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 35), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false   // the pill draws its own shadow; the canvas is a fixed transparent window
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    public override func mouseDown(with event: NSEvent) {
        dragOffset = CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        dragStartOrigin = frame.origin
        super.mouseDown(with: event)
    }
    public override func mouseDragged(with event: NSEvent) {
        guard let off = dragOffset else { return }
        let p = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: p.x - off.x, y: p.y - off.y))
    }
    public override func mouseUp(with event: NSEvent) {
        // Only a real move saves a position; a plain click must not.
        if dragOffset != nil { dragOffset = nil; if frame.origin != dragStartOrigin { onDragEnded?() } }
        super.mouseUp(with: event)
    }
}
