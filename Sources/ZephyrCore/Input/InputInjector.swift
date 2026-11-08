import Foundation

/// Injects multi-touch and hardware-button events into Android.
///
/// Virtualization.framework only offers a USB "digitizer" that Android ignores, so Zephyr
/// registers its own virtual devices through Android's built-in `uinput` tool, driven over ADB:
/// a direct-touch multi-touch screen (id 1) and a button pad (id 2). Events are JSON lines
/// streamed to `uinput -`'s stdin.
public final class InputInjector {
    public enum Button: Int, CaseIterable {
        case back = 158        // KEY_BACK
        case home = 172        // KEY_HOMEPAGE
        case appSwitch = 580   // KEY_APPSELECT
        case power = 116       // KEY_POWER
        case volumeUp = 115    // KEY_VOLUMEUP
        case volumeDown = 114  // KEY_VOLUMEDOWN
        case menu = 139        // KEY_MENU
    }

    /// A finger: normalised position in 0...1 (origin top-left of the portrait screen).
    public struct Contact: Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    private enum Event {
        case touch([Int: Contact])
        case button(Button, Bool)
    }

    private let stream: ADBStream
    private let width: Int
    private let height: Int
    private let queue = DispatchQueue(label: "zephyr.input", qos: .userInteractive)
    private let pending = Mutex<[Event]>([])
    private var scheduled = false
    private var sent: [Int: Contact] = [:]   // only touched on `queue`
    private var trackingID = 1

    public private(set) var isReady = false

    public init(client: ADBClient, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        stream = try client.open("exec:uinput -")
        stream.onData = { _ in } // discard tool output
        try stream.write(Data(Self.registration(width: width, height: height).utf8))
        // Android's input stack needs a moment to pick the devices up; events sent before are dropped.
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.isReady = true }
    }

    deinit {
        stream.close()
    }

    public var isClosed: Bool { stream.isClosed }

    /// Sets the complete set of fingers currently on the screen, keyed by slot (0...9).
    public func setContacts(_ contacts: [Int: Contact]) {
        enqueue(.touch(contacts))
    }

    public func press(_ button: Button) {
        enqueue(.button(button, true))
        enqueue(.button(button, false))
    }

    public func setButton(_ button: Button, down: Bool) {
        enqueue(.button(button, down))
    }

    public func close() {
        stream.close()
    }

    // MARK: - Batching

    private func enqueue(_ event: Event) {
        let needsFlush: Bool = pending.withLock { events in
            // Collapse consecutive pure moves (same fingers) so a backlog never builds up.
            if case let .touch(new) = event, case let .touch(old)? = events.last, Set(new.keys) == Set(old.keys) {
                events[events.count - 1] = event
            } else {
                events.append(event)
            }
            if scheduled { return false }
            scheduled = true
            return true
        }
        if needsFlush {
            queue.async { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        guard isReady else {
            // Devices not registered yet: retry shortly (`scheduled` stays set meanwhile).
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flush() }
            return
        }
        let events: [Event] = pending.withLock { events in
            let drained = events
            events.removeAll()
            scheduled = false
            return drained
        }
        var lines = ""
        for event in events {
            switch event {
            case let .touch(contacts):
                if let line = touchLine(contacts) { lines += line }
            case let .button(button, down):
                lines += "{\"id\":2,\"command\":\"inject\",\"events\":[1,\(button.rawValue),\(down ? 1 : 0),0,0,0]}\n"
            }
        }
        if !lines.isEmpty {
            try? stream.write(Data(lines.utf8))
        }
    }

    private func touchLine(_ contacts: [Int: Contact]) -> String? {
        var ev: [Int] = []
        for slot in sent.keys.sorted() where contacts[slot] == nil {
            ev += [3, 0x2F, slot, 3, 0x39, -1] // ABS_MT_SLOT, ABS_MT_TRACKING_ID = -1
        }
        for slot in contacts.keys.sorted() {
            let c = contacts[slot]!
            let x = Int((min(max(c.x, 0), 1) * Double(width - 1)).rounded())
            let y = Int((min(max(c.y, 0), 1) * Double(height - 1)).rounded())
            if let old = sent[slot] {
                if old == c { continue }
                ev += [3, 0x2F, slot]
            } else {
                trackingID = trackingID % 60000 + 1
                ev += [3, 0x2F, slot, 3, 0x39, trackingID, 3, 0x3A, 128]
            }
            ev += [3, 0x35, x, 3, 0x36, y] // ABS_MT_POSITION_X / Y
        }
        if sent.isEmpty != contacts.isEmpty {
            ev += [1, 0x14A, contacts.isEmpty ? 0 : 1] // BTN_TOUCH
        }
        sent = contacts
        guard !ev.isEmpty else { return nil }
        ev += [0, 0, 0] // SYN_REPORT
        return "{\"id\":1,\"command\":\"inject\",\"events\":[\(ev.map(String.init).joined(separator: ","))]}\n"
    }

    static func registration(width: Int, height: Int) -> String {
        let keys = Button.allCases.map { String($0.rawValue) }.joined(separator: ",")
        return """
        {"id":1,"command":"register","name":"Zephyr Touchscreen","vid":0x18d1,"pid":0x7a01,"bus":"usb",\
        "configuration":[{"type":"UI_SET_EVBIT","data":["EV_KEY","EV_ABS"]},{"type":"UI_SET_KEYBIT","data":["BTN_TOUCH"]},\
        {"type":"UI_SET_ABSBIT","data":["ABS_MT_SLOT","ABS_MT_TRACKING_ID","ABS_MT_POSITION_X","ABS_MT_POSITION_Y","ABS_MT_PRESSURE"]},\
        {"type":"UI_SET_PROPBIT","data":["INPUT_PROP_DIRECT"]}],\
        "abs_info":[{"code":"ABS_MT_SLOT","info":{"value":0,"minimum":0,"maximum":9,"fuzz":0,"flat":0,"resolution":0}},\
        {"code":"ABS_MT_TRACKING_ID","info":{"value":0,"minimum":0,"maximum":65535,"fuzz":0,"flat":0,"resolution":0}},\
        {"code":"ABS_MT_POSITION_X","info":{"value":0,"minimum":0,"maximum":\(width - 1),"fuzz":0,"flat":0,"resolution":0}},\
        {"code":"ABS_MT_POSITION_Y","info":{"value":0,"minimum":0,"maximum":\(height - 1),"fuzz":0,"flat":0,"resolution":0}},\
        {"code":"ABS_MT_PRESSURE","info":{"value":0,"minimum":0,"maximum":255,"fuzz":0,"flat":0,"resolution":0}}]}
        {"id":2,"command":"register","name":"Zephyr Buttons","vid":0x18d1,"pid":0x7a02,"bus":"usb",\
        "configuration":[{"type":"UI_SET_EVBIT","data":["EV_KEY"]},{"type":"UI_SET_KEYBIT","data":[\(keys)]}],"abs_info":[]}

        """
    }
}
