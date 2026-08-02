import AppKit
import ApplicationServices

/// Intercepts the system Previous, Play/Pause, and Next media keys while enabled by the user.
final class MediaKeyController {
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onPrevious: (() -> Void)?
    private var onPlayPause: (() -> Void)?
    private var onNext: (() -> Void)?

    deinit { stop() }

    @discardableResult
    func start(
        onPrevious: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }

        self.onPrevious = onPrevious
        self.onPlayPause = onPlayPause
        self.onNext = onNext
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
        source = nil
        eventTap = nil
        onPrevious = nil
        onPlayPause = nil
        onNext = nil
    }

    private func handle(_ event: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: event), event.subtype.rawValue == 8 else { return false }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let keyState = (event.data1 & 0xFF00) >> 8
        guard (16...18).contains(keyCode) else { return false }
        if keyState == 0xA { // key down
            switch keyCode {
            case 16: onPlayPause?() // NX_KEYTYPE_PLAY
            case 17: onNext?()      // NX_KEYTYPE_NEXT
            case 18: onPrevious?()  // NX_KEYTYPE_PREVIOUS
            default: break
            }
        }
        // Consume both press and release so macOS does not also forward this key to another player.
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard type.rawValue == 14, let context else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<MediaKeyController>.fromOpaque(context).takeUnretainedValue()
        return controller.handle(event) ? nil : Unmanaged.passUnretained(event)
    }
}
