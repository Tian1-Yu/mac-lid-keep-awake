import Foundation
import IOKit
import IOKit.ps
import SwiftUI

enum HoldPhase: Equatable {
    case checking, idle, starting, authorizing, waiting, holding, ending, finished, failed, blocked, recovery
}

struct HoldStatus: Equatable {
    static let standardDuration = 30 * 60
    var phase: HoldPhase
    var detail: String
    var duration = standardDuration
    var seconds = standardDuration
    var canEnd = false

    static let checking = HoldStatus(phase: .checking, detail: "正在读取 Mac 的睡眠状态。")
    static let idle = HoldStatus(phase: .idle, detail: "开启后合盖，计时结束时 Mac 会收到睡眠请求。")

    var busy: Bool {
        phase == .checking || phase == .starting || phase == .authorizing || phase == .ending
    }

    var canStart: Bool { phase == .idle || phase == .finished || phase == .failed }

    var ratio: Double {
        guard phase == .holding || phase == .waiting || phase == .ending, duration > 0 else {
            return 0
        }
        return min(1, max(0, Double(seconds) / Double(duration)))
    }

    var time: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

    var title: String {
        switch phase {
        case .checking: return "检查状态"
        case .idle: return "保活已关闭"
        case .starting: return "正在开启"
        case .authorizing: return "等待授权"
        case .waiting: return "等待合盖"
        case .holding: return "正在保活"
        case .ending: return "正在结束"
        case .finished: return "保活已结束"
        case .failed: return "保活未完成"
        case .blocked: return "暂时无法开启"
        case .recovery: return "正在恢复睡眠"
        }
    }

    var actionTitle: String {
        switch phase {
        case .checking: return "正在检查"
        case .starting: return "正在开启"
        case .authorizing: return "等待系统确认"
        case .ending: return "正在结束"
        case .blocked, .recovery: return canEnd ? "结束保活" : "等待状态恢复"
        case .waiting, .holding: return "结束保活"
        case .idle, .finished: return "开启保活"
        case .failed: return "再试一次"
        }
    }

    var actionSymbol: String {
        if canEnd { return "stop.circle" }
        if phase == .blocked || phase == .recovery { return "arrow.clockwise" }
        return "power"
    }

    var glyph: String {
        switch phase {
        case .checking, .starting: return "laptopcomputer"
        case .idle: return "laptopcomputer"
        case .authorizing: return "lock.shield"
        case .waiting: return "arrow.down.to.line"
        case .holding: return "timer"
        case .ending: return "hourglass"
        case .finished: return "checkmark"
        case .blocked, .failed: return "exclamationmark"
        case .recovery: return "arrow.counterclockwise"
        }
    }
}

struct HoldBackend {
    let read: @Sendable () -> HoldStatus
    let change: @Sendable (String, Bool) -> AuthorizationResult
    var preauthorized: @Sendable () -> Bool = { false }
    var configure: @Sendable (Bool) -> AuthorizationResult = { _ in .failed }
}

enum AuthorizationResult: Equatable {
    case accepted, cancelled, failed, needsAuthorization
}

extension HoldBackend {
    static func local(bundle: Bundle = .main) -> HoldBackend {
        let directory = URL(fileURLWithPath: "/private/var/run/local.mac-lid-keep-awake", isDirectory: true)
        let script = bundle.url(forResource: "lid-hold", withExtension: "command")
        let authorizer = bundle.url(forResource: "authorize", withExtension: "scpt")
        let installer = bundle.url(forResource: "authorization", withExtension: "sh")
        let uid = String(getuid())
        let helper = "/Library/PrivilegedHelperTools/local.mac-lid-keep-awake-\(uid)"
        let rule = "/private/etc/sudoers.d/mac_lid_keep_awake_\(uid)"
        return HoldBackend(
            read: {
                guard let script,
                      let result = run("/bin/bash", [script.path, "status"]),
                      result.code == 0 else {
                    return HoldStatus(phase: .blocked, detail: "没有读到睡眠状态。请重新检查。")
                }
                let lines = result.text.split(whereSeparator: \.isNewline)
                let record = lines.first.map(String.init) ?? ""
                let flag = lines.last.map(String.init) ?? ""
                let pending = FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending").path)
                let attributes = try? directory.appendingPathComponent("status").resourceValues(forKeys: [.contentModificationDateKey])
                let current = status(
                    record: record,
                    flag: flag,
                    pending: pending,
                    modified: attributes?.contentModificationDate,
                    now: Date()
                )
                if current.canStart, let reason = readinessProblem() {
                    return HoldStatus(phase: .blocked, detail: reason)
                }
                return current
            },
            change: { action, prepared in
                if prepared {
                    guard let result = run("/usr/bin/sudo", ["-n", "--", helper, action]) else { return .failed }
                    if result.code == 0 { return .accepted }
                    if result.text.contains("sudo:") { return .needsAuthorization }
                    return .failed
                }
                guard let script, let authorizer else { return .failed }
                return authorize(authorizer, script, action, uid, script)
            },
            preauthorized: {
                FileManager.default.isExecutableFile(atPath: helper) && FileManager.default.fileExists(atPath: rule)
            },
            configure: { enable in
                guard let script, let authorizer, let installer else { return .failed }
                return authorize(authorizer, installer, enable ? "prepare" : "revoke", uid, script)
            }
        )
    }

    private static func authorize(_ authorizer: URL, _ entry: URL, _ action: String, _ uid: String, _ tool: URL) -> AuthorizationResult {
        guard let result = run("/usr/bin/osascript", [authorizer.path, entry.path, action, uid, tool.path]) else { return .failed }
        if result.code == 0 { return .accepted }
        return result.text.contains("(-128)") ? .cancelled : .failed
    }

    private static func readinessProblem() -> String? {
        let powerDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard powerDomain != 0 else { return "暂时没有读到机盖状态。状态恢复后可以开启。" }
        defer { IOObjectRelease(powerDomain) }
        guard let lidClosed = IORegistryEntryCreateCFProperty(powerDomain, "AppleClamshellState" as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool else {
            return "暂时没有读到机盖状态。状态恢复后可以开启。"
        }
        if lidClosed { return "机盖已合上。开盖后会恢复开启。" }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "Mac 温度较高。冷却后会恢复开启。"
        case .nominal, .fair: break
        @unknown default: return "暂时无法确认温度。状态恢复后可以开启。"
        }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return "暂时没有读到电池状态。状态恢复后可以开启。"
        }
        for source in sources {
            guard let battery = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  battery[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let charge = battery[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            if charge * 100 <= maximum * 20 { return "电量在 20% 或以下。充电后会恢复开启。" }
            return nil
        }
        return "暂时没有读到内置电池。状态恢复后可以开启。"
    }

    static func status(record: String, flag: String, pending: Bool, modified: Date?, now: Date) -> HoldStatus {
        let off = flag == "系统睡眠已允许。"
        let on = flag == "系统睡眠当前被关闭。"
        let recent = modified.map { now.timeIntervalSince($0) < 90 } ?? false
        if pending {
            if record.hasPrefix("恢复睡眠失败"), !off {
                return HoldStatus(phase: .recovery, detail: "正在重试恢复睡眠。请保持开盖，直到状态恢复。", canEnd: true)
            }
            if off {
                if recent && !record.hasPrefix("保活已就绪") && !record.hasPrefix("已合盖，开始") {
                    return HoldStatus(phase: .ending, detail: "睡眠权限已恢复，正在完成本次操作。", seconds: 0)
                }
                return HoldStatus(phase: .recovery, detail: "睡眠权限已恢复，但本次保活仍待清理。", canEnd: true)
            }
            guard on else {
                return HoldStatus(phase: .recovery, detail: "暂时读不到系统睡眠状态。可以尝试结束保活。", canEnd: true)
            }
            if record.hasPrefix("已合盖，开始") {
                let duration = durationIn(record)
                let elapsed = modified.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
                return HoldStatus(
                    phase: .holding, detail: "提前开盖会结束保活。到点会请求 Mac 睡眠。",
                    duration: duration, seconds: max(0, duration - elapsed), canEnd: true
                )
            }
            if record.hasPrefix("保活已就绪") {
                let duration = durationIn(record)
                return HoldStatus(
                    phase: .waiting, detail: "请在 3 分钟内合盖。关闭窗口仍会继续等待。",
                    duration: duration, seconds: duration, canEnd: true
                )
            }
            return HoldStatus(phase: .recovery, detail: "正在核对本次保活。可以手动结束。", canEnd: true)
        }
        if on {
            return HoldStatus(phase: .blocked, detail: "另有设置关闭了系统睡眠。恢复后可以再开启保活。")
        }
        guard off else {
            return HoldStatus(phase: .blocked, detail: "没有读到睡眠状态。请重新检查。")
        }
        guard recent else { return .idle }

        if record.contains("立即睡眠请求失败") {
            return HoldStatus(phase: .failed, detail: "睡眠权限已恢复。macOS 未接受立即睡眠请求。", seconds: 0)
        }
        if record.hasPrefix("定时已结束") {
            let detail = record.contains("已请求立即睡眠")
                ? "计时结束，已向 Mac 发出睡眠请求。"
                : "计时结束，系统睡眠权限已恢复。"
            return HoldStatus(phase: .finished, detail: detail, seconds: 0)
        }
        if record.hasPrefix("已手动结束") {
            return HoldStatus(phase: .finished, detail: "已手动结束。系统睡眠权限已恢复。")
        }
        if record.hasPrefix("已开盖") {
            return HoldStatus(phase: .finished, detail: "机盖已打开，Mac 可以照常使用。")
        }
        if record.hasPrefix("等待合盖超时") {
            return HoldStatus(phase: .finished, detail: "3 分钟内未合盖，保活已自动结束。")
        }
        if record.contains("20%") {
            return HoldStatus(phase: .failed, detail: "电量在 20% 或以下。请充电后再开启。")
        }
        if record.contains("热压力") {
            return HoldStatus(phase: .failed, detail: "Mac 温度较高。请等它冷却后再开启。")
        }
        if record.hasPrefix("无法读取") || record.hasPrefix("系统未确认") || record.hasPrefix("启动失败")
            || record.hasPrefix("请开盖后") || record.hasPrefix("保活程序曾异常退出") || record.hasPrefix("无法记录") {
            return HoldStatus(phase: .failed, detail: record.components(separatedBy: "。").first.map { $0 + "。" } ?? record)
        }
        return .idle
    }

    private static func durationIn(_ record: String) -> Int {
        let pieces = record.components(separatedBy: " 分钟")
        for piece in pieces.reversed() {
            if let match = piece.range(of: #"(?:^| )[0-9]+$"#, options: .regularExpression),
               let minutes = Int(piece[match].trimmingCharacters(in: .whitespaces)),
                  (1...120).contains(minutes) {
                return minutes * 60
            }
        }
        return HoldStatus.standardDuration
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (code: Int32, text: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

@MainActor
final class HoldModel: ObservableObject {
    @Published private(set) var status: HoldStatus = .checking
    @Published private(set) var authorization: Preauthorization = .manual
    @Published private(set) var configuring = false
    @Published private(set) var authorizationFeedback = ""
    private let backend: HoldBackend
    private var changing = false
    private var version = 0
    private var feedback: (HoldStatus, HoldStatus)?
    private var reloadInFlight = false
    private var rejectedPreparedAuthorization = false

    init(backend: HoldBackend) { self.backend = backend }

    func observe() async {
        while !Task.isCancelled {
            if !changing { await refresh() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func refresh() async {
        guard !reloadInFlight else { return }
        reloadInFlight = true
        defer { reloadInFlight = false }
        let attempt = version
        let read = backend.read
        let preauthorized = backend.preauthorized
        let (updated, installed) = await Task.detached(priority: .utility) { (read(), preauthorized()) }.value
        guard !changing, attempt == version else { return }
        if !configuring { applyAuthorization(installed: installed) }
        if let (initial, message) = feedback, updated.phase == initial.phase, updated.detail == initial.detail {
            present(message)
        } else {
            feedback = nil
            present(updated)
        }
    }

    func activate(minutes: Int) async {
        guard !changing, !configuring, !status.busy, status.canEnd || status.canStart,
              status.canEnd || (1...120).contains(minutes) else { return }
        feedback = nil
        let initial = status
        let ending = initial.canEnd
        let prepared = authorization == .ready
        version += 1
        changing = true
        var pending = initial
        pending.phase = ending ? .ending : (prepared ? .starting : .authorizing)
        pending.detail = prepared
            ? (ending ? "正在恢复 Mac 的睡眠权限。" : "正在开启保活。")
            : "请在 macOS 授权窗口确认。也可以取消。"
        present(pending)

        let change = backend.change
        let read = backend.read
        let command = ending ? "stop" : String(minutes)
        let response = await Task.detached(priority: .userInitiated) {
            if !ending && !read().canStart { return AuthorizationResult.failed }
            return change(command, prepared)
        }.value
        let observed = await Task.detached(priority: .utility) { read() }.value
        changing = false
        if response == .needsAuthorization {
            rejectedPreparedAuthorization = true
            authorization = .stale
        }
        let expected = ending ? !observed.canEnd : observed.canEnd
        guard !expected || response == .cancelled || response == .needsAuthorization else {
            present(observed)
            return
        }
        var next = observed
        if response == .cancelled {
            next.detail = ending ? "已取消授权，保活继续。" : "已取消授权，保活仍为关闭。"
        } else if response == .needsAuthorization {
            next.detail = "提前授权已失效。下次操作会请求单次授权，也可以在设置里更新。"
        } else if observed.phase != .finished && observed.phase != .failed && observed.phase != .blocked {
            next.detail = ending ? "未确认保活已经结束。可以再试一次。" : "macOS 未确认开启保活。可以再试一次。"
            if !observed.canEnd && !observed.busy { next.phase = .failed }
        }
        if next != observed { feedback = (observed, next) }
        present(next)
    }

    func setPreauthorization(_ enabled: Bool) async {
        guard !changing, !configuring else { return }
        configuring = true
        authorizationFeedback = ""
        let configure = backend.configure
        let preauthorized = backend.preauthorized
        let (result, installed) = await Task.detached(priority: .userInitiated) {
            (configure(enabled), preauthorized())
        }.value
        configuring = false
        if result == .accepted { rejectedPreparedAuthorization = false }
        applyAuthorization(installed: installed)
        if result == .cancelled {
            authorizationFeedback = "已取消，授权状态保持原样。"
        } else if result != .accepted || installed != enabled {
            authorizationFeedback = "macOS 未确认这次更改，可以稍后再试。"
        } else {
            authorizationFeedback = enabled ? "已提前授权。现在可以直接开启和结束保活。" : "提前授权已撤销。"
        }
    }

    private func applyAuthorization(installed: Bool) {
        let updated: Preauthorization = installed ? (rejectedPreparedAuthorization ? .stale : .ready) : .manual
        if authorization != updated { authorization = updated }
    }

    private func present(_ update: HoldStatus) {
        if status != update { status = update }
    }
}

enum Preauthorization: Equatable {
    case manual, ready, stale
}
