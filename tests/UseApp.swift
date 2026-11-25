import AppKit
import Foundation
import ImageIO
import SwiftUI

final class TestPower: @unchecked Sendable {
    private let lock = NSLock()
    private var value = HoldStatus.idle
    private var configured = false
    private var outcome = AuthorizationResult.accepted
    private var history: [(String, Bool)] = []

    func read() -> HoldStatus { lock.withLock { value } }
    func ready() -> Bool { lock.withLock { configured } }
    func setUp(_ enable: Bool) -> AuthorizationResult {
        lock.withLock { configured = enable }
        return .accepted
    }
    func setState(_ state: HoldStatus) { lock.withLock { value = state } }
    func setOutcome(_ result: AuthorizationResult) { lock.withLock { outcome = result } }
    var commands: [String] {
        lock.withLock { history.map { "\($0.0):\($0.1)" } }
    }
    func change(_ command: String, prepared: Bool) -> AuthorizationResult {
        Thread.sleep(forTimeInterval: 0.12)
        return lock.withLock {
            history.append((command, prepared))
            guard outcome == .accepted else { return outcome }
            if command == "stop" {
                value = HoldStatus(phase: .finished, detail: "已手动结束。系统睡眠权限已恢复。")
            } else {
                let time = Int(command)! * 60
                value = HoldStatus(phase: .waiting, detail: "请合盖。", duration: time, seconds: time, canEnd: true)
            }
            return .accepted
        }
    }

    var backend: HoldBackend {
        HoldBackend(read: { self.read() }, change: { self.change($0, prepared: $1) },
                    preauthorized: { self.ready() }, configure: { self.setUp($0) })
    }
}

@MainActor
final class Screen: ObservableObject {
    let model: HoldModel
    @Published var minutes = 30
    @Published var showingAuthorization = false

    init(_ model: HoldModel) { self.model = model }
}

struct TestScreen: View {
    @ObservedObject var screen: Screen
    @ObservedObject var model: HoldModel

    var body: some View {
        HoldView(status: model.status, minutes: $screen.minutes, activate: { duration in
            Task { await model.activate(minutes: duration) }
        }, openAuthorization: { screen.showingAuthorization = true })
        .sheet(isPresented: $screen.showingAuthorization) { AuthorizationView(model: model) }
    }
}

@main
struct UseApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task {
            do { try await verify(); exit(0) }
            catch { print(error); exit(1) }
        }
        application.run()
    }

    @MainActor
    static func verify() async throws {
        let files = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let probe = HoldBackend.local(bundle: files).read()
        print("Local app status read: \(probe.title).")

        let fixture = TestPower()
        let model = HoldModel(backend: fixture.backend)
        let screen = Screen(model)
        await model.refresh()
        let window = NSWindow(contentRect: NSRect(x: -15_000, y: -15_000, width: 424, height: 474),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TestScreen(screen: screen, model: model))
        window.orderBack(nil)
        window.displayIfNeeded()
        defer { window.close() }
        try await settle()

        click(window, x: 181, y: 278)
        try await settle()
        if let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText("47", replacementRange: editor.selectedRange())
        } else {
            fatalError("The user-editable duration field did not accept focus.")
        }
        try await settle()
        precondition(screen.minutes == 47, "Custom duration must apply immediately.")

        fixture.setOutcome(.cancelled)
        click(window, x: 212, y: 73)
        try await settle()
        precondition(model.status.phase == .idle && model.status.detail.contains("已取消"))
        precondition(fixture.commands == ["47:false"])

        click(window, x: 382, y: 417)
        try await settle()
        precondition(screen.showingAuthorization, "The authorization control should open settings.")
        screen.showingAuthorization = false
        try await settle()

        await model.setPreauthorization(true)
        precondition(model.authorization == .ready && fixture.ready())
        fixture.setOutcome(.accepted)
        click(window, x: 212, y: 73)
        try await settle()
        precondition(model.status.phase == .waiting && model.status.duration == 2_820)
        click(window, x: 212, y: 73)
        try await settle()
        precondition(model.status.phase == .finished && fixture.commands == ["47:false", "47:true", "stop:true"])

        await model.setPreauthorization(false)
        precondition(model.authorization == .manual && !fixture.ready())
        fixture.setState(HoldStatus(phase: .blocked, detail: "电量在 20% 或以下。充电后会恢复开启。"))
        await model.refresh()
        click(window, x: 212, y: 73)
        try await settle()
        precondition(model.status.phase == .blocked && fixture.commands.count == 3)
        fixture.setState(.idle)
        await model.refresh()
        precondition(model.status.phase == .idle)

        let source = CGImageSourceCreateWithURL(files.url(forResource: "HeaderIcon", withExtension: "png")! as CFURL, nil)!
        let icon = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let now = Date(timeIntervalSince1970: 2_000)
        let held = HoldBackend.status(record: "已合盖，开始 47 分钟保活。", flag: "系统睡眠当前被关闭。",
                                      pending: true, modified: now.addingTimeInterval(-56), now: now)
        precondition(held.time == "46:04")
        for (name, status, mode) in [
            ("01-settings", HoldStatus.idle, ColorScheme.light),
            ("02-awaiting-lid", HoldStatus(phase: .waiting, detail: "请在开启后 3 分钟内合盖。", duration: 2_820, seconds: 2_820, canEnd: true), .light),
            ("03-counting", held, .dark),
            ("04-blocked", HoldStatus(phase: .blocked, detail: "电量在 20% 或以下。充电后会恢复开启。"), .light)
        ] {
            let rendered = NSHostingView(rootView: HoldView(status: status, minutes: .constant(47), activate: { _ in },
                                                             openAuthorization: {}, icon: icon).environment(\.colorScheme, mode))
            window.contentView = rendered
            window.displayIfNeeded()
            try await settle()
            rendered.layoutSubtreeIfNeeded()
            let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 848, pixelsHigh: 948, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            pixels.size = NSSize(width: 424, height: 474)
            rendered.cacheDisplay(in: rendered.bounds, to: pixels)
            let png = pixels.representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
        print("PASS: native text entry, start, cancelled prompt, authorization settings, preauthorized start/stop, revocation, automatic readiness.")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(320)) }

    @MainActor
    static func click(_ window: NSWindow, x: CGFloat, y: CGFloat) {
        let whereInWindow = CGPoint(x: x, y: y)
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: eventType, location: whereInWindow, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }
}
