import AppKit

class ClickThroughWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

class DropZoneView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: (([URL]) -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil to ensure that all standard clicks and mouse movements pass through
        // to underlying menu items or desktop icons.
        return nil
    }
    
    // NSDraggingDestination protocols
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            return false
        }
        onPerformDrop?(urls)
        return true
    }
}

class NotchDropZoneController: NSObject {
    var window: ClickThroughWindow!
    var dropZoneView: DropZoneView!
    
    init(onDragEntered: @escaping () -> Void, onDragExited: @escaping () -> Void, onPerformDrop: @escaping ([URL]) -> Void) {
        super.init()
        
        let width: CGFloat = 260
        let height: CGFloat = 38 // Standard physical camera notch point depth on MacBook screens
        
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let y = screenFrame.origin.y + screenFrame.height - height
        
        let contentRect = NSRect(x: x, y: y, width: width, height: height)
        
        window = ClickThroughWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false // False is required so drag events are processed by this window
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        
        dropZoneView = DropZoneView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        dropZoneView.onDragEntered = onDragEntered
        dropZoneView.onDragExited = onDragExited
        dropZoneView.onPerformDrop = onPerformDrop
        
        window.contentView = dropZoneView
        window.orderFrontRegardless()
    }
}
