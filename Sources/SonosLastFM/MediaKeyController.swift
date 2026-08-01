import AppKit
import ApplicationServices

/// Intercepts only the system Play/Pause media key while enabled by the user.
final class MediaKeyController {
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onPlayPause: (() -> Void)?

    deinit { stop() }

    @discardableResult
    func start(onPlayPause: @escaping () -> Void) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }

        self.onPlayPause = onPlayPause
        let mask = CGEventMask(1) << 14 // kCGEventSystemDefined
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: MediaKeyController.callback, userInfo: context)
        guard let eventTap else { stop(); return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        source = nil; eventTap = nil; onPlayPause = nil
    }

    private func handle(_ event: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: event), event.subtype.rawValue == 8 else { return false }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let keyState = (event.data1 & 0xFF00) >> 8
        guard keyCode == 16, keyState == 0xA else { return false } // NX_KEYTYPE_PLAY, key down
        onPlayPause?()
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard type.rawValue == 14, let context else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<MediaKeyController>.fromOpaque(context).takeUnretainedValue()
        return controller.handle(event) ? nil : Unmanaged.passUnretained(event)
    }
}
