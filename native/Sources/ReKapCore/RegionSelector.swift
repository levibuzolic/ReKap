import AppKit
import ScreenCaptureKit

@MainActor public enum RegionSelector {
    /// Returns points relative to the display's top-left corner, matching SCStreamConfiguration.sourceRect.
    public static func select(on display: SCDisplay) async -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else { return nil }
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Select Recording Region"
        panel.setAccessibilityTitle("Select Recording Region")
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RegionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        return await withCheckedContinuation { continuation in
            view.completion = { rect in
                panel.orderOut(nil)
                continuation.resume(returning: rect)
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
        }
    }
}

@MainActor private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor private final class RegionView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var completion: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect = .zero
    private let widthField = NSTextField(string: "640")
    private let heightField = NSTextField(string: "360")
    private let aspect = NSPopUpButton()
    private let dimensions = NSTextField(labelWithString: "Drag to select a recording region")
    private var finished = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let controls = NSStackView()
        controls.orientation = .horizontal; controls.spacing = 8
        controls.wantsLayer = true; controls.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        controls.layer?.cornerRadius = 10
        controls.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for field in [widthField, heightField] { field.widthAnchor.constraint(equalToConstant: 66).isActive = true }
        aspect.addItems(withTitles: ["Free", "16:9", "4:3", "1:1"])
        aspect.target = self; aspect.action = #selector(applyDimensions)
        widthField.target = self; widthField.action = #selector(applyDimensions)
        heightField.target = self; heightField.action = #selector(applyDimensions)
        let apply = NSButton(title: "Set size", target: self, action: #selector(applyDimensions))
        let record = NSButton(title: "Use region ↩", target: self, action: #selector(confirm))
        record.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel (Esc)", target: self, action: #selector(cancel))
        for item in [NSTextField(labelWithString: "Width"), widthField, NSTextField(labelWithString: "Height"), heightField, aspect, apply, record, cancel] { controls.addArrangedSubview(item) }
        addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controls.centerXAnchor.constraint(equalTo: centerXAnchor), controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30)])
        dimensions.textColor = .white; dimensions.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        dimensions.frame = CGRect(x: 24, y: 24, width: frame.width - 48, height: 30)
        addSubview(dimensions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill(); bounds.fill()
        if !selection.isEmpty {
            NSColor.white.withAlphaComponent(0.12).setFill(); selection.fill()
            NSColor.systemYellow.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 2; border.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { anchor = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let rawPoint = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: min(bounds.maxX, max(0, rawPoint.x)), y: min(bounds.maxY, max(0, rawPoint.y)))
        var rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        if let ratio {
            rect.size.width = min(rect.width, (bounds.maxY - rect.minY) * ratio)
            rect.size.height = rect.width / ratio
        }
        update(rect.intersection(bounds))
    }
    override func mouseUp(with event: NSEvent) { anchor = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel() } else if event.keyCode == 36 { confirm() } else { super.keyDown(with: event) }
    }
    private var ratio: CGFloat? {
        switch aspect.indexOfSelectedItem { case 1: 16.0 / 9; case 2: 4.0 / 3; case 3: 1; default: nil }
    }
    @objc private func applyDimensions() {
        let width = min(bounds.width, ratio.map { bounds.height * $0 } ?? bounds.width, max(2, CGFloat(widthField.doubleValue)))
        let height = min(bounds.height, max(2, ratio.map { width / $0 } ?? CGFloat(heightField.doubleValue)))
        let origin = selection.isEmpty ? CGPoint(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2) : selection.origin
        update(CGRect(x: min(origin.x, bounds.width - width), y: min(origin.y, bounds.height - height), width: width, height: height))
    }
    private func update(_ rect: CGRect) {
        selection = rect.integral.intersection(bounds)
        widthField.stringValue = String(Int(selection.width)); heightField.stringValue = String(Int(selection.height))
        dimensions.stringValue = "\(Int(selection.width)) × \(Int(selection.height)) points · Drag to adjust, Return to accept, Esc to cancel"
        needsDisplay = true
    }
    @objc private func confirm() {
        guard CaptureGeometry.isValid(selection, within: bounds) else { NSSound.beep(); return }
        finish(selection)
    }
    @objc private func cancel() { finish(nil) }
    private func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        completion?(rect); completion = nil
    }
}
