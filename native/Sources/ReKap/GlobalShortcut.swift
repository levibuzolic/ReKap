import AppKit
import Carbon
import ReKapCore
import SwiftUI

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(enabled: Bool, keyCode: UInt32, modifiers: UInt32) throws {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard enabled else { return }
        let identifier = EventHotKeyID(signature: 0x524B4150, id: 1)
        let result = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: [NSLocalizedDescriptionKey: "The recording shortcut is unavailable. Choose another shortcut in Settings."])
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let settings: AppSettings
    let onChange: () -> Void
    func makeNSView(context: Context) -> ShortcutField {
        let field = ShortcutField()
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = true
        field.alignment = .center
        field.focusRingType = .exterior
        field.settings = settings
        field.onChange = onChange
        field.stringValue = settings.shortcutLabel
        field.setAccessibilityLabel("Recording keyboard shortcut")
        return field
    }
    func updateNSView(_ field: ShortcutField, context: Context) { field.stringValue = settings.shortcutLabel }
}

@MainActor final class ShortcutField: NSTextField {
    var settings: AppSettings?
    var onChange: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "Press shortcut…"
    }
    override func keyDown(with event: NSEvent) { record(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }
    private func record(_ event: NSEvent) {
        guard let settings else { return }
        if event.keyCode == 53 {
            stringValue = settings.shortcutLabel
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control),
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            NSSound.beep()
            return
        }
        var carbonModifiers = 0
        var label = ""
        if flags.contains(.control) { carbonModifiers |= controlKey; label += "⌃" }
        if flags.contains(.option) { carbonModifiers |= optionKey; label += "⌥" }
        if flags.contains(.shift) { carbonModifiers |= shiftKey; label += "⇧" }
        if flags.contains(.command) { carbonModifiers |= cmdKey; label += "⌘" }
        settings.shortcutKeyCode = Int(event.keyCode)
        settings.shortcutModifiers = carbonModifiers
        settings.shortcutLabel = label + characters.uppercased()
        stringValue = settings.shortcutLabel
        onChange?()
        window?.makeFirstResponder(nil)
    }
}
