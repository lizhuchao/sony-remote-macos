import AppKit
import Combine
import SwiftUI

@MainActor
private final class TVSetupModel: ObservableObject {
    static let locationOptions = ["未设置", "客厅", "卧室", "书房", "自定义"]

    enum Stage {
        case profiles
        case guide
        case scan
        case configure
    }

    @Published var stage: Stage
    @Published var discoveredTVs: [DiscoveredTV] = []
    @Published var selectedTVID: String?
    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var profileName = ""
    @Published var modelName = ""
    @Published var locationChoice = "未设置"
    @Published var customLocation = ""
    @Published var ipAddress = ""
    @Published var psk = ""
    @Published var macAddress = ""
    @Published var errorText = ""
    @Published var isSaving = false

    let firstRun: Bool

    init(firstRun: Bool) {
        self.firstRun = firstRun
        stage = firstRun ? .guide : .profiles
    }

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        errorText = ""
        Task {
            discoveredTVs = await SonyTVDiscovery.discover()
            hasScanned = true
            isScanning = false
        }
    }

    func choose(_ television: DiscoveredTV) {
        selectedTVID = television.id
        profileName = television.name
        modelName = television.model
        ipAddress = television.ipAddress
        stage = .configure
    }

    func configureManually() {
        selectedTVID = nil
        profileName = "Sony BRAVIA"
        modelName = ""
        locationChoice = "未设置"
        customLocation = ""
        ipAddress = ""
        stage = .configure
    }

    var resolvedLocation: String? {
        switch locationChoice {
        case "未设置": return nil
        case "自定义":
            let clean = customLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        default: return locationChoice
        }
    }
}

struct TVSetupView: View {
    @ObservedObject var controller: SonyController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TVSetupModel

    init(controller: SonyController) {
        self.controller = controller
        _model = StateObject(wrappedValue: TVSetupModel(firstRun: controller.profiles.isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 540)
        .frame(minHeight: 430)
        .onAppear {
            if model.firstRun && !model.hasScanned { model.startScan() }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.firstRun ? l10n("设置 Sony BRAVIA") : titleForStage)
                    .font(.title2.bold())
                if model.stage != .profiles {
                    Text(l10n("步骤 %@ / 3", "\(stepNumber)"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                } else {
                    Text("选择当前要控制的电视，或添加新电视")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(l10n(model.firstRun ? "稍后设置" : "关闭")) { close() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .profiles:
            profilesContent
        case .guide:
            guideContent
        case .scan:
            scanContent
        case .configure:
            configureContent
        }
    }

    private var profilesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.profiles.isEmpty {
                ContentUnavailableView(
                    "还没有电视 Profile",
                    systemImage: "tv",
                    description: Text("扫描局域网中的 Sony BRAVIA，或手动输入 IP。")
                )
            } else {
                ForEach(controller.profiles) { profile in
                    Button {
                        controller.selectProfile(profile)
                        close()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tv")
                                .font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.displayTitle).font(.headline)
                                Text(profileSubtitle(profile))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == controller.activeProfileID {
                                Label("当前", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium)).foregroundStyle(.green)
                            } else {
                                Text("切换").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHint(l10n(profile.id == controller.activeProfileID ? "当前电视" : "切换到这台电视"))
                }
            }
        }
    }

    private var guideContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("先在电视上完成一次设置", systemImage: "gearshape.2.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                guideRow(1, "Mac 与电视连接同一个局域网")
                guideRow(2, "开启 Remote Start 和 Simple IP Control")
                guideRow(3, "认证方式选择 Pre-Shared Key，并设置 PSK")
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("正在自动扫描局域网中的 Sony BRAVIA…")
                } else if model.hasScanned {
                    Image(systemName: model.discoveredTVs.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(model.discoveredTVs.isEmpty ? .orange : .green)
                    Text(model.discoveredTVs.isEmpty
                         ? l10n("暂未发现电视，可重试或手动输入 IP")
                         : l10n("已发现 %@ 台 Sony BRAVIA", "\(model.discoveredTVs.count)"))
                }
            }
            .font(.callout)
            .frame(minHeight: 24)
        }
    }

    private var scanContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isScanning {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在扫描 Sony BRAVIA…").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else if model.discoveredTVs.isEmpty {
                ContentUnavailableView(
                    "没有发现电视",
                    systemImage: "wifi.exclamationmark",
                    description: Text("确认电视已开机、位于同一局域网，并关闭访客网络或 AP 隔离。")
                )
            } else {
                Text("选择要添加的电视").font(.headline)
                ForEach(model.discoveredTVs) { television in
                    Button { model.choose(television) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tv.fill").font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(television.name).font(.headline)
                                Text([television.model, television.ipAddress].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var configureContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("验证并保存 Profile").font(.headline)
            Form {
                Section("电视信息") {
                    TextField("名称", text: $model.profileName)
                    TextField("型号", text: $model.modelName)
                    Picker("位置", selection: $model.locationChoice) {
                        ForEach(TVSetupModel.locationOptions, id: \.self) { Text(l10n($0)) }
                    }
                    if model.locationChoice == "自定义" {
                        TextField("自定义位置", text: $model.customLocation)
                    }
                }
                Section("连接") {
                    TextField("电视 IP 地址", text: $model.ipAddress)
                    SecureField("电视端设置的 PSK", text: $model.psk)
                    TextField("MAC 地址（连接成功后自动读取）", text: $model.macAddress)
                }
            }
            .formStyle(.grouped)
            Text("PSK 仅保存在这台 Mac 的 Keychain；更换电脑后需要重新输入。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.errorText.isEmpty {
                Label(model.errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch model.stage {
            case .profiles:
                Button("扫描并添加电视") {
                    model.stage = .guide
                    model.startScan()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("手动添加") { model.configureManually() }
            case .guide:
                Button("手动输入 IP") { model.configureManually() }
                Spacer()
                if !model.isScanning {
                    Button("重新扫描") { model.startScan() }
                }
                Button("查看扫描结果") { model.stage = .scan }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isScanning)
            case .scan:
                Button("返回指引") { model.stage = .guide }
                Spacer()
                Button("手动输入 IP") { model.configureManually() }
                Button("重新扫描") { model.startScan() }
                    .disabled(model.isScanning)
            case .configure:
                Button("返回") { model.stage = model.hasScanned ? .scan : .guide }
                Spacer()
                Button {
                    saveProfile()
                } label: {
                    if model.isSaving { ProgressView().controlSize(.small) } else { Text("验证并保存") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.isSaving
                    || model.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.psk.isEmpty
                )
            }
        }
    }

    private var titleForStage: String {
        switch model.stage {
        case .profiles: return l10n("电视 Profile")
        case .guide: return l10n("添加 Sony BRAVIA")
        case .scan: return l10n("扫描电视")
        case .configure: return l10n("配置电视")
        }
    }

    private var stepNumber: Int {
        switch model.stage {
        case .profiles, .guide: return 1
        case .scan: return 2
        case .configure: return 3
        }
    }

    private func guideRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.accentColor, in: Circle())
            Text(l10n(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func profileSubtitle(_ profile: TVProfile) -> String {
        let alias = profile.name == profile.deviceTitle ? "" : profile.name
        return [alias, profile.ipAddress].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func saveProfile() {
        guard !model.isSaving else { return }
        model.errorText = ""
        model.isSaving = true
        Task {
            model.errorText = await controller.validateAndSave(
                ip: model.ipAddress,
                newPSK: model.psk,
                manualMAC: model.macAddress,
                profileName: model.profileName,
                modelName: model.modelName,
                locationName: model.resolvedLocation ?? "",
                createNew: true
            ) ?? ""
            model.isSaving = false
            if model.errorText.isEmpty { close() }
        }
    }

    private func close() {
        controller.isShowingOnboarding = false
        controller.isShowingProfileManager = false
        dismiss()
    }
}
