import AppKit
import Combine
import SwiftUI

private struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

@MainActor
final class ADBController: ObservableObject {
    static let target = "192.168.6.147:5555"

    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "正在检查电视…"
    @Published private(set) var lastAction = ""

    private let adbPath: String
    private var monitor: AnyCancellable?

    init() {
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        adbPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "adb"
        monitor = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
    }

    func start() {
        connect(force: false)
    }

    func reconnect() {
        connect(force: true)
    }

    func refreshStatus() {
        guard !isBusy else { return }
        runInBackground(["-s", Self.target, "get-state"]) { [weak self] result in
            guard let self else { return }
            let online = result.exitCode == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
            self.isConnected = online
            self.statusText = online ? "BRAVIA 已连接" : "电视已断开"
        }
    }

    func send(_ keyCode: Int, label: String) {
        guard !isBusy else { return }
        isBusy = true
        statusText = isConnected ? "正在发送…" : "正在重连…"

        Task {
            var state = await execute(["-s", Self.target, "get-state"])
            if state.exitCode != 0 || state.output.trimmingCharacters(in: .whitespacesAndNewlines) != "device" {
                _ = await execute(["connect", Self.target])
                state = await execute(["-s", Self.target, "get-state"])
            }

            guard state.exitCode == 0,
                  state.output.trimmingCharacters(in: .whitespacesAndNewlines) == "device" else {
                isConnected = false
                isBusy = false
                statusText = "连接失败"
                lastAction = "请确认电视开机且 ADB 调试仍已授权"
                return
            }

            let result = await execute(["-s", Self.target, "shell", "input", "keyevent", String(keyCode)])
            isBusy = false
            isConnected = result.exitCode == 0
            statusText = result.exitCode == 0 ? "BRAVIA 已连接" : "发送失败"
            lastAction = result.exitCode == 0 ? "已发送：\(label)" : result.output
        }
    }

    private func connect(force: Bool) {
        guard !isBusy else { return }
        isBusy = true
        statusText = force ? "正在重新连接…" : "正在连接…"

        Task {
            if force { _ = await execute(["disconnect", Self.target]) }
            let connectResult = await execute(["connect", Self.target])
            let state = await execute(["-s", Self.target, "get-state"])
            let online = state.exitCode == 0 && state.output.trimmingCharacters(in: .whitespacesAndNewlines) == "device"

            isBusy = false
            isConnected = online
            statusText = online ? "BRAVIA 已连接" : "连接失败"
            lastAction = online ? "电视：Sony KD-55X9000H" : connectResult.output
        }
    }

    private func execute(_ arguments: [String]) async -> CommandResult {
        let path = adbPath
        return await Task.detached(priority: .userInitiated) {
            Self.run(path: path, arguments: arguments)
        }.value
    }

    private func runInBackground(_ arguments: [String], completion: @escaping @MainActor (CommandResult) -> Void) {
        Task {
            let result = await execute(arguments)
            completion(result)
        }
    }

    nonisolated private static func run(path: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CommandResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }
    }
}

private struct RemoteButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    var size: CGFloat = 62
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                if !title.isEmpty {
                    Text(title).font(.caption2.weight(.medium))
                }
            }
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: Circle())
        .overlay(Circle().strokeBorder(.separator.opacity(0.35), lineWidth: 1))
        .accessibilityLabel(title.isEmpty ? systemImage : title)
    }
}

struct RemoteView: View {
    @StateObject private var controller = ADBController()

    var body: some View {
        VStack(spacing: 22) {
            header
            topControls
            directionalPad
            navigationControls
            volumeControls
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 350, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { controller.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.isConnected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sony Remote").font(.title2.bold())
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.reconnect()
            } label: {
                Image(systemName: controller.isBusy ? "hourglass" : "arrow.clockwise")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .disabled(controller.isBusy)
            .help("重新连接电视")
            .accessibilityLabel("重新连接电视")
        }
    }

    private var topControls: some View {
        HStack {
            RemoteButton(title: "电源", systemImage: "power", tint: .red) {
                controller.send(26, label: "电源")
            }
            Spacer()
            RemoteButton(title: "静音", systemImage: "speaker.slash.fill") {
                controller.send(164, label: "静音")
            }
        }
        .padding(.horizontal, 24)
    }

    private var directionalPad: some View {
        ZStack {
            Circle()
                .fill(.quaternary)
                .frame(width: 218, height: 218)
                .overlay(Circle().strokeBorder(.separator.opacity(0.35), lineWidth: 1))

            Button { controller.send(19, label: "上") } label: {
                Image(systemName: "chevron.up").frame(width: 64, height: 58)
            }
            .buttonStyle(.plain).offset(y: -73).keyboardShortcut(.upArrow, modifiers: [])
            .accessibilityLabel("上")

            Button { controller.send(20, label: "下") } label: {
                Image(systemName: "chevron.down").frame(width: 64, height: 58)
            }
            .buttonStyle(.plain).offset(y: 73).keyboardShortcut(.downArrow, modifiers: [])
            .accessibilityLabel("下")

            Button { controller.send(21, label: "左") } label: {
                Image(systemName: "chevron.left").frame(width: 58, height: 64)
            }
            .buttonStyle(.plain).offset(x: -73).keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel("左")

            Button { controller.send(22, label: "右") } label: {
                Image(systemName: "chevron.right").frame(width: 58, height: 64)
            }
            .buttonStyle(.plain).offset(x: 73).keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityLabel("右")

            Button { controller.send(23, label: "OK") } label: {
                Text("OK").font(.headline)
                    .frame(width: 82, height: 82)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel("确认")
        }
        .disabled(controller.isBusy)
    }

    private var navigationControls: some View {
        HStack(spacing: 42) {
            RemoteButton(title: "返回", systemImage: "chevron.backward") {
                controller.send(4, label: "返回")
            }
            .keyboardShortcut(.escape, modifiers: [])
            RemoteButton(title: "主页", systemImage: "house.fill") {
                controller.send(3, label: "主页")
            }
            .keyboardShortcut("h", modifiers: [])
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 18) {
            Button { controller.send(25, label: "音量减") } label: {
                Label("音量减", systemImage: "speaker.minus.fill").frame(maxWidth: .infinity, minHeight: 46)
            }
            Button { controller.send(24, label: "音量加") } label: {
                Label("音量加", systemImage: "speaker.plus.fill").frame(maxWidth: .infinity, minHeight: 46)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(controller.isBusy)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(controller.lastAction.isEmpty ? "192.168.6.147:5555" : controller.lastAction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("方向键和 Return 也可直接操作")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 34)
    }
}

@main
struct SonyRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RemoteView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
