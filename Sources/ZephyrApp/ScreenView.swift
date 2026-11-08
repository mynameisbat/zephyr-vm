import AppKit
import CoreImage
import SwiftUI
import Virtualization
import ZephyrCore

/// The phone screen: Virtualization's framebuffer view with a transparent touch layer on top.
/// Keyboard typing goes to the VM's USB keyboard (the VZ view stays first responder); mouse and
/// trackpad gestures are turned into multi-touch through `InputInjector`.
struct ScreenView: NSViewRepresentable {
    @ObservedObject var session: DeviceSession

    func makeNSView(context: Context) -> ScreenContainerView {
        ScreenContainerView()
    }

    func updateNSView(_ view: ScreenContainerView, context: Context) {
        view.attach(virtualMachine: session.virtualMachine, input: { [weak session] in session?.input })
    }
}

final class ScreenContainerView: NSView {
    private let vmView = VZVirtualMachineView()
    private let touchView = TouchOverlayView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        vmView.capturesSystemKeys = false
        if #available(macOS 14.0, *) {
            vmView.automaticallyReconfiguresDisplay = false
        }
        // With SwiftShader the guest scans out RGBA buffers as XRGB, so red and blue arrive
        // swapped (a known issue of the LineageOS virtio image). Swap them back on the GPU.
        vmView.wantsLayer = true
        vmView.layerUsesCoreImageFilters = true
        if let swap = CIFilter(name: "CIColorMatrix") {
            swap.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputRVector")
            swap.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
            swap.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputBVector")
            vmView.contentFilters = [swap]
        }
        for view in [vmView, touchView] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(virtualMachine: VZVirtualMachine?, input: @escaping () -> InputInjector?) {
        if vmView.virtualMachine !== virtualMachine {
            vmView.virtualMachine = virtualMachine
            focusKeyboard()
        }
        touchView.input = input
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusKeyboard()
    }

    private func focusKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.vmView)
        }
    }
}

/// Converts mouse/trackpad input into touches.
/// - click/drag: one finger · ⌥-drag: pinch around the centre · trackpad pinch: two fingers
/// - scroll (wheel or two-finger trackpad): a swipe · right click: Back · middle click: Home
final class TouchOverlayView: NSView {
    var input: () -> InputInjector? = { nil }

    private var pinchCenter: InputInjector.Contact?
    private var pinchDistance = 0.0
    private var scrollFinger: InputInjector.Contact?
    private var scrollRelease: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // VZVirtualMachineView hides the host cursor over itself (it expects the guest to draw one,
    // which Android doesn't). Track the mouse ourselves and keep a visible arrow.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
                                       owner: self))
    }

    private func showCursor() {
        NSCursor.setHiddenUntilMouseMoves(false)
        NSCursor.unhide()
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) { showCursor() }
    override func mouseEntered(with event: NSEvent) { showCursor() }
    override func mouseMoved(with event: NSEvent) { showCursor() }

    private func point(_ event: NSEvent) -> InputInjector.Contact {
        let p = convert(event.locationInWindow, from: nil)
        return .init(x: Double(p.x / max(bounds.width, 1)), y: Double(1 - p.y / max(bounds.height, 1)))
    }

    private func fingers(for event: NSEvent) -> [Int: InputInjector.Contact] {
        let p = point(event)
        if event.modifierFlags.contains(.option) {
            // Mirror a second finger through the centre of the screen (like the Android Emulator).
            return [0: p, 1: .init(x: 1 - p.x, y: 1 - p.y)]
        }
        return [0: p]
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(superview?.subviews.first)
        input()?.setContacts(fingers(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        showCursor()
        input()?.setContacts(fingers(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        input()?.setContacts([:])
    }

    override func rightMouseDown(with event: NSEvent) {
        input()?.press(.back)
    }

    override func otherMouseDown(with event: NSEvent) {
        input()?.press(.home)
    }

    override func magnify(with event: NSEvent) {
        guard let input = input() else { return }
        switch event.phase {
        case .began:
            pinchCenter = point(event)
            pinchDistance = 0.2
        case .ended, .cancelled:
            pinchCenter = nil
            input.setContacts([:])
            return
        default:
            break
        }
        guard let c = pinchCenter else { return }
        pinchDistance = min(max(pinchDistance * (1 + Double(event.magnification)), 0.04), 0.9)
        let half = pinchDistance / 2
        input.setContacts([0: .init(x: c.x - half, y: c.y), 1: .init(x: c.x + half, y: c.y)])
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input = input() else { return }
        // Let Android do its own fling from the release velocity; ignore macOS momentum events.
        if !event.momentumPhase.isEmpty { return }
        if event.phase == .ended || event.phase == .cancelled {
            liftScrollFinger()
            return
        }
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 18.0
        var finger = scrollFinger ?? point(event)
        if scrollFinger == nil { input.setContacts([0: finger]) }
        finger.x += Double(event.scrollingDeltaX) * scale / Double(max(bounds.width, 1))
        finger.y += Double(event.scrollingDeltaY) * scale / Double(max(bounds.height, 1))
        if finger.x < 0.01 || finger.x > 0.99 || finger.y < 0.01 || finger.y > 0.99 {
            liftScrollFinger()
            return
        }
        scrollFinger = finger
        input.setContacts([0: finger])

        // Mouse wheels have no end phase: lift shortly after the last tick.
        scrollRelease?.cancel()
        let release = DispatchWorkItem { [weak self] in self?.liftScrollFinger() }
        scrollRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + (event.phase.isEmpty ? 0.12 : 0.5), execute: release)
    }

    private func liftScrollFinger() {
        scrollRelease?.cancel()
        scrollRelease = nil
        guard scrollFinger != nil else { return }
        scrollFinger = nil
        input()?.setContacts([:])
    }
}
