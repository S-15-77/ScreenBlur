import AppKit
import IOKit.hid
import CoreMotion
import SwiftUI

// Blurs every screen after `idleSeconds` without keyboard/mouse input; any input fades it back out.
// Also tracks the lid hinge: closing blurs the built-in screen bottom→up, opening clears it top→down.
// AirPods head tracking: turn left → right half blurs, turn right → left half blurs.
// All knobs live in the settings window (UserDefaults, domain local.macscreenblur).
final class App: NSObject, NSApplicationDelegate, CMHeadphoneMotionManagerDelegate {
    var windows: [NSWindow] = []
    var blurred = false
    var statusItem: NSStatusItem!
    let lid = LidSensor()
    let live = Live()
    var settingsWindow: NSWindow?
    var lidWindow: NSWindow?
    var displayLink: CADisplayLink?
    // Sensors give coarse steps (1° lid, jittery head yaw); springs turn them into fluid motion.
    var lidSpring = Spring(stiffness: 120), lidApplied = -1.0
    var lidHoldUntil = Date.distantPast
    var headSpring = Spring(stiffness: 60), headApplied = 0.0, headMaskSide = 0
    let head = CMHeadphoneMotionManager()
    var headRef: Double?
    var headWindow: NSWindow?

    let defaults = UserDefaults.standard
    func num(_ key: String) -> Double { defaults.double(forKey: key) }

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: [
            "idleEnabled": true, "idleSeconds": 60.0,
            "lidEnabled": true, "lidBlurStart": 95.0, "lidBlurEnd": 50.0,
            "headEnabled": true, "headTurn": 25.0, "headInvert": false,
        ])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Screen Blur")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open ScreenBlur", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Blur Now", action: #selector(blurNow), keyEquivalent: "b").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit ScreenBlur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let mainMenu = NSMenu()
        mainMenu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu
        NSApp.mainMenu = mainMenu
        openSettings()

        // ponytail: 0.25s polling of the idle counter; no Accessibility permission needed, unlike event taps.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        lid.onAngle = { [weak self] in self?.lidAngleChanged($0) }
        lid.start()
        // vsync-aligned frames, in .common mode so it keeps animating while the menu is open
        displayLink = (builtinScreen ?? NSScreen.main)?.displayLink(target: self, selector: #selector(frame(_:)))
        displayLink?.add(to: .main, forMode: .common)

        // Screen goes dark with the lid shut: park the blur fully up, then play a slow top→down reveal on wake.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let screen = self.builtinScreen else { return }
            self.lidSpring.value = 1; self.lidSpring.velocity = 0; self.lidApplied = 1
            self.applyLid(1, on: screen)
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lidHoldUntil = Date().addingTimeInterval(0.4) // let the panel light up first
            self?.lidSpring.stiffness = 18 // softer spring ≈ 1s reveal
        }

        head.delegate = self
        if head.isDeviceMotionAvailable {
            switch CMHeadphoneMotionManager.authorizationStatus() {
            case .denied, .restricted: live.head = "Permission denied — allow in System Settings › Privacy & Security › Motion & Fitness"
            case .notDetermined: live.head = "Waiting for permission / AirPods in ears"
            default: live.head = "Waiting for AirPods (put them in your ears)"
            }
            head.startDeviceMotionUpdates(to: .main) { [weak self] m, err in
                if let m { self?.headMoved(m.attitude.yaw) }
                else if let err { self?.live.head = "Error: \(err.localizedDescription)" }
            }
        } else { live.head = "Unsupported" }
    }

    @objc func recenterHead() { headRef = nil }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(live: live, app: self)))
            w.title = "ScreenBlur"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Dock icon click brings the window back after it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { headRef = nil }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        live.head = "Not connected"
        headSpring.target = 0
    }

    func headMoved(_ yaw: Double) {
        if headRef == nil { headRef = yaw } // whatever direction you face first counts as "at the screen"
        var deg = (yaw - headRef!) * 180 / .pi
        deg = (deg + 540).truncatingRemainder(dividingBy: 360) - 180
        if UserDefaults.standard.bool(forKey: "headInvert") { deg = -deg }
        live.head = "\(Int(deg))°"
        // Blur strength ramps from 40% of the trigger angle up to the full trigger angle, so it follows your head.
        let turn = num("headTurn"), start = turn * 0.4
        let q = min(max((abs(deg) - start) / (turn - start), 0), 1)
        // yaw grows turning left → positive → blur the right side
        headSpring.target = defaults.bool(forKey: "headEnabled") ? (deg > 0 ? q : -q) : 0
    }

    // Signed v: >0 blurs the right side, <0 the left. A fixed-size band slides in from the outer edge;
    // its inner edge fades across 30% of the screen, so there's no hard split line.
    func applyHead(_ v: Double, on screen: NSScreen) {
        let W = screen.frame.width, F = W * 0.3, bandW = W / 2 + F
        if headWindow?.frame != screen.frame {
            headWindow?.orderOut(nil)
            let w = makeWindow(frame: screen.frame)
            w.alphaValue = 1
            let band = w.contentView!.subviews[0]
            band.autoresizingMask = []
            band.frame.size = NSSize(width: bandW, height: screen.frame.height)
            headWindow = w
            headMaskSide = 0
        }
        let band = headWindow!.contentView!.subviews[0] as! NSVisualEffectView
        let side = v > 0 ? 1 : -1
        if side != headMaskSide {
            band.maskImage = featherMask(F, fadeToward: side > 0 ? .minX : .maxX)
            headMaskSide = side
        }
        let shown = CGFloat(abs(v)) * bandW
        band.setFrameOrigin(NSPoint(x: side > 0 ? W - shown : shown - bandW, y: 0))
    }

    @objc func blurNow() { show() }

    func tick() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if !blurred && defaults.bool(forKey: "idleEnabled") && idle >= num("idleSeconds") { show() }
        // 1s grace so the menu click that triggered "Blur Now" doesn't instantly undo it
        else if blurred && idle < 0.5 && Date().timeIntervalSince(shownAt) > 1 { hide() }
    }

    var builtinScreen: NSScreen? { NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } }

    func lidAngleChanged(_ angle: Double?) {
        guard let angle else { live.lid = "Sensor unavailable"; return }
        live.lid = "\(Int(angle))°"
        let start = num("lidBlurStart"), end = num("lidBlurEnd")
        lidSpring.target = defaults.bool(forKey: "lidEnabled") ? min(max((start - angle) / (start - end), 0), 1) : 0
    }

    @objc func frame(_ link: CADisplayLink) {
        let dt = min(link.targetTimestamp - link.timestamp, 1.0 / 30)
        if Date() >= lidHoldUntil {
            lidSpring.step(dt)
            if lidSpring.settled { lidSpring.stiffness = 120 }
            if lidSpring.value != lidApplied, let screen = builtinScreen {
                lidApplied = lidSpring.value
                applyLid(lidApplied, on: screen)
            }
        }
        headSpring.step(dt)
        if headSpring.value != headApplied, let screen = builtinScreen ?? NSScreen.main {
            headApplied = headSpring.value
            applyHead(headApplied, on: screen)
        }
    }

    // The whole screen blurs as the lid closes: overall strength follows the angle, and a screen-tall
    // gradient band slides up so the bottom leads — rising bottom→up on close, clearing top→down on open.
    func applyLid(_ p: Double, on screen: NSScreen) {
        let H = screen.frame.height
        if lidWindow?.frame != screen.frame {
            lidWindow?.orderOut(nil)
            let w = makeWindow(frame: screen.frame)
            let band = w.contentView!.subviews[0] as! NSVisualEffectView
            band.autoresizingMask = []
            band.frame.size = NSSize(width: screen.frame.width, height: 2 * H) // opaque bottom half, fade top half
            band.maskImage = featherMask(H, fadeToward: .maxY)
            lidWindow = w
        }
        lidWindow!.alphaValue = CGFloat(p)
        lidWindow!.contentView!.subviews[0].setFrameOrigin(NSPoint(x: 0, y: H * CGFloat(p - 1)))
    }

    // Stretchable mask: opaque, fading to clear over `f` points toward `edge`. capInsets keep the fade
    // fixed-size while the 2pt opaque part stretches to fill the rest of the view.
    func featherMask(_ f: CGFloat, fadeToward edge: NSRectEdge) -> NSImage {
        let vertical = edge == .maxY
        let img = NSImage(size: vertical ? NSSize(width: 1, height: f + 2) : NSSize(width: f + 2, height: 1), flipped: false) { _ in
            NSColor.black.setFill()
            switch edge {
            case .maxY:
                NSRect(x: 0, y: 0, width: 1, height: 2).fill()
                NSGradient(starting: .black, ending: .clear)!.draw(in: NSRect(x: 0, y: 2, width: 1, height: f), angle: 90)
            case .minX:
                NSRect(x: f, y: 0, width: 2, height: 1).fill()
                NSGradient(starting: .clear, ending: .black)!.draw(in: NSRect(x: 0, y: 0, width: f, height: 1), angle: 0)
            default: // .maxX
                NSRect(x: 0, y: 0, width: 2, height: 1).fill()
                NSGradient(starting: .black, ending: .clear)!.draw(in: NSRect(x: 2, y: 0, width: f, height: 1), angle: 0)
            }
            return true
        }
        img.capInsets = switch edge {
        case .maxY: NSEdgeInsets(top: f, left: 0, bottom: 0, right: 0)
        case .minX: NSEdgeInsets(top: 0, left: f, bottom: 0, right: 0)
        default: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: f)
        }
        img.resizingMode = .stretch
        return img
    }

    var shownAt = Date.distantPast

    func show() {
        guard !blurred else { return }
        blurred = true
        shownAt = Date()
        windows = NSScreen.screens.map { makeWindow(frame: $0.frame) } // rebuilt each time so display changes are picked up
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.8
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    func hide() {
        blurred = false
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { closing.forEach { $0.orderOut(nil) } })
    }

    func makeWindow(frame: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.alphaValue = 0
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let blur = NSVisualEffectView(frame: container.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        container.addSubview(blur)
        w.contentView = container
        w.setFrame(frame, display: true)
        w.orderFrontRegardless()
        return w
    }
}

// Critically damped spring: glides to `target` as fast as possible without overshooting.
struct Spring {
    var target = 0.0, value = 0.0, velocity = 0.0
    var stiffness: Double
    var settled: Bool { value == target && velocity == 0 }
    mutating func step(_ dt: Double) {
        velocity += (stiffness * (target - value) - 2 * stiffness.squareRoot() * velocity) * dt
        value += velocity * dt
        if abs(target - value) < 0.0005 && abs(velocity) < 0.0005 { value = target; velocity = 0 }
    }
}

final class Live: ObservableObject {
    @Published var lid = "–"
    @Published var head = "Starting…"
}

struct SettingsView: View {
    @ObservedObject var live: Live
    let app: App
    @AppStorage("idleEnabled") var idleEnabled = true
    @AppStorage("idleSeconds") var idleSeconds = 60.0
    @AppStorage("lidEnabled") var lidEnabled = true
    @AppStorage("lidBlurStart") var lidStart = 95.0
    @AppStorage("lidBlurEnd") var lidEnd = 50.0
    @AppStorage("headEnabled") var headEnabled = true
    @AppStorage("headTurn") var headTurn = 25.0
    @AppStorage("headInvert") var headInvert = false

    var body: some View {
        Form {
            Section("Idle") {
                Toggle("Blur when idle", isOn: $idleEnabled)
                Slider(value: $idleSeconds, in: 5...600, step: 5) { Text("After \(Int(idleSeconds))s") }
                Button("Blur Now") { app.blurNow() }
            }
            Section("Lid") {
                Toggle("Blur as the lid closes", isOn: $lidEnabled)
                LabeledContent("Lid angle", value: live.lid)
                Slider(value: $lidStart, in: 60...130, step: 1) { Text("Starts at \(Int(lidStart))°") }
                Slider(value: $lidEnd, in: 10...55, step: 1) { Text("Full at \(Int(lidEnd))°") }
            }
            Section("AirPods") {
                Toggle("Blur the side I look away from", isOn: $headEnabled)
                LabeledContent("Head turn", value: live.head)
                Slider(value: $headTurn, in: 10...60, step: 1) { Text("Trigger at \(Int(headTurn))°") }
                Toggle("Swap sides", isOn: $headInvert)
                Button("Recenter (look at screen first)") { app.recenterHead() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// Apple's lid angle sensor (HID 05AC:8104, on recent MacBooks). Feature report 1 holds the angle in degrees.
final class LidSensor {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    var device: IOHIDDevice?
    var onAngle: ((Double?) -> Void)?
    private let queue = DispatchQueue(label: "lid-sensor")
    private var timer: DispatchSourceTimer?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 60)
        var last: Double?? = .none
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let a = self.angle
            guard last != .some(a) else { return }
            last = .some(a)
            DispatchQueue.main.async { self.onAngle?(a) }
        }
        t.resume()
        timer = t
    }

    init() {
        let match: NSDictionary = ["VendorID": 0x05AC, "ProductID": 0x8104, "PrimaryUsagePage": 0x20, "PrimaryUsage": 0x8A]
        IOHIDManagerSetDeviceMatching(manager, match)
        IOHIDManagerOpen(manager, 0)
        device = ((IOHIDManagerCopyDevices(manager) as NSSet?)?.allObjects as? [IOHIDDevice])?.first
        if let d = device { IOHIDDeviceOpen(d, 0) }
    }

    var angle: Double? {
        guard let d = device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len = buf.count
        guard IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess, len >= 3 else { return nil }
        return Double(UInt16(buf[1]) | UInt16(buf[2]) << 8)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular) // Dock icon + window
app.run()
