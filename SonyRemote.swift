import AppKit
import Combine
import Darwin
import Security
import SwiftUI

private struct HTTPResult: Sendable {
    let statusCode: Int
    let data: Data
    let error: String?
}

struct TVProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var model: String
    var location: String?
    var ipAddress: String
    var macAddress: String
    let keychainAccount: String

    var deviceTitle: String {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanModel.isEmpty ? name : cleanModel
    }

    var displayTitle: String {
        guard let location,
              !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return deviceTitle }
        let standardLocations = ["客厅", "卧室", "书房"]
        let displayLocation = standardLocations.contains(location) ? l10n(location) : location
        return "\(displayLocation) · \(deviceTitle)"
    }
}

private enum KeychainStore {
    private static let service = "local.lizhuchao.sonyremote"
    static let legacyAccount = "sony-ircc-psk"

    static func load(account: String = legacyAccount) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    @discardableResult
    static func save(_ value: String, account: String = legacyAccount) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor
final class SonyController: ObservableObject {
    private static let defaultIP = "192.168.6.147"
    private static let ipKey = "SonyRemote.targetIP"
    private static let macKey = "SonyRemote.macAddress"
    private static let profilesKey = "SonyRemote.profiles.v1"
    private static let activeProfileKey = "SonyRemote.activeProfileID.v1"
    private static let irccCodes = [
        "Up": "AAAAAQAAAAEAAAB0Aw==",
        "Down": "AAAAAQAAAAEAAAB1Aw==",
        "Left": "AAAAAQAAAAEAAAA0Aw==",
        "Right": "AAAAAQAAAAEAAAAzAw==",
        "Confirm": "AAAAAQAAAAEAAABlAw==",
        "Return": "AAAAAgAAAJcAAAAjAw==",
        "Home": "AAAAAQAAAAEAAABgAw==",
        "VolumeUp": "AAAAAQAAAAEAAAASAw==",
        "VolumeDown": "AAAAAQAAAAEAAAATAw==",
        "Mute": "AAAAAQAAAAEAAAAUAw==",
    ]

    @Published private(set) var targetIP: String
    @Published private(set) var macAddress: String
    @Published private(set) var profiles: [TVProfile]
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var hasPSK: Bool
    @Published private(set) var isConnected = false
    @Published private(set) var isPoweredOn = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = l10n("正在检查电视…")
    @Published private(set) var lastAction = ""
    @Published var isShowingSettings = false
    @Published var isShowingKeyboard = false
    @Published var isShowingOnboarding = false
    @Published var isShowingProfileManager = false

    private var psk: String
    private var monitor: AnyCancellable?

    init() {
        var loadedProfiles = Self.loadProfiles()
        var selectedID = UserDefaults.standard.string(forKey: Self.activeProfileKey).flatMap(UUID.init(uuidString:))
        let legacyPSK = KeychainStore.load()
        if loadedProfiles.isEmpty && !legacyPSK.isEmpty {
            let migrated = TVProfile(
                id: UUID(),
                name: "Sony BRAVIA",
                model: "",
                location: nil,
                ipAddress: UserDefaults.standard.string(forKey: Self.ipKey) ?? Self.defaultIP,
                macAddress: UserDefaults.standard.string(forKey: Self.macKey) ?? "",
                keychainAccount: KeychainStore.legacyAccount
            )
            loadedProfiles = [migrated]
            selectedID = migrated.id
            Self.saveProfiles(loadedProfiles, activeID: selectedID)
        }
        let activeProfile = loadedProfiles.first(where: { $0.id == selectedID }) ?? loadedProfiles.first
        profiles = loadedProfiles
        activeProfileID = activeProfile?.id
        targetIP = activeProfile?.ipAddress ?? Self.defaultIP
        macAddress = activeProfile?.macAddress ?? ""
        let selectedAccount = activeProfile?.keychainAccount ?? KeychainStore.legacyAccount
        if let importedPSK = ProcessInfo.processInfo.environment["SONY_REMOTE_IMPORT_PSK"],
           !importedPSK.isEmpty {
            _ = KeychainStore.save(importedPSK, account: selectedAccount)
            psk = importedPSK
        } else {
            psk = KeychainStore.load(account: selectedAccount)
        }
        hasPSK = !psk.isEmpty
        monitor = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
    }

    func start() {
        if profiles.isEmpty {
            isShowingOnboarding = true
        } else if !hasPSK {
            isShowingSettings = true
        }
        refreshStatus()
    }

    func selectProfile(_ profile: TVProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        activeProfileID = profile.id
        targetIP = profile.ipAddress
        macAddress = profile.macAddress
        psk = KeychainStore.load(account: profile.keychainAccount)
        hasPSK = !psk.isEmpty
        isConnected = false
        isPoweredOn = false
        statusText = l10n("正在连接 %@…", profile.name)
        Self.saveProfiles(profiles, activeID: profile.id)
        refreshStatus()
    }

    var activeProfile: TVProfile? {
        profiles.first(where: { $0.id == activeProfileID })
    }

    func refreshStatus() {
        guard !isBusy else { return }
        Task {
            let result = await restRequest(method: "getPowerStatus", params: [])
            guard result.statusCode == 200,
                  let object = jsonObject(result.data),
                  let status = ((object["result"] as? [[String: Any]])?.first)?["status"] as? String else {
                isConnected = false
                isPoweredOn = false
                statusText = result.statusCode == 403 ? l10n("Sony API 需要认证") : l10n("电视待机或不可达")
                return
            }
            isConnected = true
            isPoweredOn = status == "active"
            statusText = hasPSK
                ? (isPoweredOn ? l10n("BRAVIA 已连接") : l10n("BRAVIA 待机"))
                : l10n("BRAVIA 在线 · 需要 PSK")
            if hasPSK, activeProfile?.model.isEmpty != false {
                await enrichActiveProfileMetadata()
            }
        }
    }

    func send(command: String, label: String) {
        guard !isBusy else { return }
        guard hasPSK, let code = Self.irccCodes[command] else {
            lastAction = l10n("请先配置 Sony IP Control 的 PSK")
            isShowingSettings = true
            return
        }
        isBusy = true
        statusText = l10n("正在发送…")
        Task {
            let result = await irccRequest(code: code)
            isBusy = false
            if result.statusCode == 200 {
                isConnected = true
                statusText = l10n("BRAVIA 已连接")
                lastAction = l10n("已发送：%@", l10n(label))
            } else {
                statusText = l10n("发送失败")
                lastAction = failureMessage(result)
            }
        }
    }

    func togglePower() {
        guard !isBusy else { return }
        guard hasPSK else {
            lastAction = l10n("请先配置 Sony IP Control 的 PSK")
            isShowingSettings = true
            return
        }
        isBusy = true
        if isPoweredOn {
            statusText = l10n("正在关闭电视…")
            Task {
                let result = await restRequest(method: "setPowerStatus", params: [["status": false]], needsPSK: true)
                isBusy = false
                if result.statusCode == 200 && !hasRPCError(result.data) {
                    isPoweredOn = false
                    statusText = l10n("BRAVIA 待机")
                    lastAction = l10n("已发送：关闭电源")
                } else {
                    statusText = l10n("电源控制失败")
                    lastAction = failureMessage(result)
                }
            }
            return
        }

        statusText = l10n("正在唤醒电视…")
        Task {
            if !macAddress.isEmpty {
                let mac = macAddress
                let ip = targetIP
                _ = await Task.detached(priority: .userInitiated) {
                    Self.sendWakeOnLAN(macAddress: mac, targetIP: ip)
                }.value
            }
            var finalResult = HTTPResult(statusCode: 0, data: Data(), error: l10n("电视未响应"))
            for _ in 0..<6 {
                finalResult = await restRequest(method: "setPowerStatus", params: [["status": true]], needsPSK: true)
                if finalResult.statusCode == 200 && !hasRPCError(finalResult.data) { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            isBusy = false
            if finalResult.statusCode == 200 && !hasRPCError(finalResult.data) {
                isConnected = true
                isPoweredOn = true
                statusText = l10n("BRAVIA 已连接")
                lastAction = l10n("已发送：唤醒电视")
            } else {
                statusText = l10n("唤醒失败")
                lastAction = macAddress.isEmpty
                    ? l10n("缺少 MAC 地址；电视在线时重新验证设置")
                    : failureMessage(finalResult)
            }
        }
    }

    func sendText(_ text: String) async -> String? {
        guard !text.isEmpty else { return l10n("请输入要发送的文字") }
        guard hasPSK else {
            isShowingKeyboard = false
            isShowingSettings = true
            return l10n("请先配置 Sony IP Control 的 PSK")
        }

        isBusy = true
        statusText = l10n("正在发送文字…")
        let result = await restRequest(
            endpoint: "appControl",
            method: "setTextForm",
            params: [text],
            needsPSK: true
        )
        isBusy = false

        if result.statusCode == 200 && !hasRPCError(result.data) {
            isConnected = true
            statusText = l10n("BRAVIA 已连接")
            lastAction = l10n("已发送文字到电视")
            return nil
        }

        statusText = l10n("文字发送失败")
        if rpcErrorCode(result.data) == 7 {
            return l10n("电视当前没有激活输入框；先在 TiviMate 中点进需要输入的位置")
        }
        return failureMessage(result)
    }

    func validateAndSave(
        ip: String,
        newPSK: String,
        manualMAC: String,
        profileName: String? = nil,
        modelName: String? = nil,
        locationName: String? = nil,
        createNew: Bool = false
    ) async -> String? {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPSK = newPSK.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingProfile = profiles.first(where: { $0.ipAddress == cleanIP })
        let existingProfile = createNew ? matchingProfile : activeProfile
        let profileID = existingProfile?.id ?? UUID()
        let keychainAccount = existingProfile?.keychainAccount ?? "sony-ircc-psk-\(profileID.uuidString)"
        let savedPSK = existingProfile?.id == activeProfileID
            ? psk
            : KeychainStore.load(account: keychainAccount)
        let effectivePSK = cleanPSK.isEmpty ? savedPSK : cleanPSK
        guard !cleanIP.isEmpty else { return l10n("请输入电视 IP 地址") }
        guard !effectivePSK.isEmpty else { return l10n("请输入电视端配置的 PSK") }

        let result = await restRequest(
            method: "getSystemInformation",
            params: [],
            needsPSK: true,
            ipOverride: cleanIP,
            pskOverride: effectivePSK
        )
        guard result.statusCode == 200,
              let object = jsonObject(result.data),
              object["error"] == nil else {
            return result.statusCode == 403
                ? l10n("PSK 不正确，或电视尚未启用预共享密钥认证")
                : l10n("无法连接 Sony API；检查 IP、Remote Start 和 Simple IP Control")
        }
        if !cleanPSK.isEmpty || savedPSK.isEmpty {
            guard KeychainStore.save(effectivePSK, account: keychainAccount) else {
                return l10n("无法把 PSK 保存到 macOS Keychain")
            }
        }

        psk = effectivePSK
        hasPSK = true
        targetIP = cleanIP
        UserDefaults.standard.set(cleanIP, forKey: Self.ipKey)
        let systemInformation = (object["result"] as? [[String: Any]])?.first ?? [:]
        let systemMAC = systemInformation["macAddr"] as? String ?? ""
        let chosenMAC = systemMAC.isEmpty ? manualMAC.trimmingCharacters(in: .whitespacesAndNewlines) : systemMAC
        macAddress = chosenMAC
        UserDefaults.standard.set(chosenMAC, forKey: Self.macKey)

        let requestedName = profileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reportedModel = systemInformation["model"] as? String ?? ""
        let finalModel = (modelName?.isEmpty == false ? modelName : reportedModel) ?? ""
        let finalName = requestedName.isEmpty
            ? (existingProfile?.name ?? (finalModel.isEmpty ? "Sony BRAVIA" : finalModel))
            : requestedName
        let profile = TVProfile(
            id: profileID,
            name: finalName,
            model: finalModel,
            location: locationName == nil ? existingProfile?.location : normalizedLocation(locationName),
            ipAddress: cleanIP,
            macAddress: chosenMAC,
            keychainAccount: keychainAccount
        )
        if let index = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        activeProfileID = profileID
        Self.saveProfiles(profiles, activeID: profileID)
        lastAction = l10n("Sony API 设置验证成功")
        refreshStatus()
        return nil
    }

    private func enrichActiveProfileMetadata() async {
        guard let profileID = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].model.isEmpty else { return }
        let result = await restRequest(
            method: "getSystemInformation",
            params: [],
            needsPSK: true
        )
        guard result.statusCode == 200,
              let information = (jsonObject(result.data)?["result"] as? [[String: Any]])?.first,
              let reportedModel = information["model"] as? String,
              !reportedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        profiles[index].model = reportedModel
        if profiles[index].name == "Sony BRAVIA" {
            profiles[index].name = reportedModel
        }
        Self.saveProfiles(profiles, activeID: profileID)
    }

    private func normalizedLocation(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
    }

    private static func loadProfiles() -> [TVProfile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([TVProfile].self, from: data) else { return [] }
        return profiles
    }

    private static func saveProfiles(_ profiles: [TVProfile], activeID: UUID?) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        if let activeID {
            UserDefaults.standard.set(activeID.uuidString, forKey: activeProfileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeProfileKey)
        }
    }

    private func irccRequest(code: String) async -> HTTPResult {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>\(code)</IRCCCode></u:X_SendIRCC></s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(targetIP)/sony/ircc") else {
            return HTTPResult(statusCode: 0, data: Data(), error: l10n("电视 IP 地址无效"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"", forHTTPHeaderField: "SOAPACTION")
        request.setValue(psk, forHTTPHeaderField: "X-Auth-PSK")
        return await perform(request)
    }

    private func restRequest(
        endpoint: String = "system",
        method: String,
        params: [Any],
        needsPSK: Bool = false,
        ipOverride: String? = nil,
        pskOverride: String? = nil
    ) async -> HTTPResult {
        let ip = ipOverride ?? targetIP
        guard let url = URL(string: "http://\(ip)/sony/\(endpoint)") else {
            return HTTPResult(statusCode: 0, data: Data(), error: l10n("电视 IP 地址无效"))
        }
        let payload: [String: Any] = ["method": method, "params": params, "id": 1, "version": "1.0"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return HTTPResult(statusCode: 0, data: Data(), error: l10n("无法生成 Sony API 请求"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.httpBody = data
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if needsPSK { request.setValue(pskOverride ?? psk, forHTTPHeaderField: "X-Auth-PSK") }
        return await perform(request)
    }

    private func perform(_ request: URLRequest) async -> HTTPResult {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return HTTPResult(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data, error: nil)
        } catch {
            return HTTPResult(statusCode: 0, data: Data(), error: error.localizedDescription)
        }
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func hasRPCError(_ data: Data) -> Bool { jsonObject(data)?["error"] != nil }

    private func rpcErrorCode(_ data: Data) -> Int? {
        (jsonObject(data)?["error"] as? [Any])?.first as? Int
    }

    private func failureMessage(_ result: HTTPResult) -> String {
        if result.statusCode == 403 { return l10n("认证失败；检查电视端 PSK") }
        if let error = result.error, !error.isEmpty { return error }
        if let object = jsonObject(result.data), let error = object["error"] { return l10n("Sony API 错误：%@", "\(error)") }
        return l10n("Sony API 返回 HTTP %@", "\(result.statusCode)")
    }

    nonisolated private static func sendWakeOnLAN(macAddress: String, targetIP: String) -> Bool {
        let clean = macAddress.replacingOccurrences(of: "[^0-9A-Fa-f]", with: "", options: .regularExpression)
        guard clean.count == 12 else { return false }
        var mac = [UInt8]()
        for index in stride(from: 0, to: 12, by: 2) {
            let start = clean.index(clean.startIndex, offsetBy: index)
            let end = clean.index(start, offsetBy: 2)
            guard let byte = UInt8(clean[start..<end], radix: 16) else { return false }
            mac.append(byte)
        }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        let parts = targetIP.split(separator: ".")
        let subnetBroadcast = parts.count == 4 ? "\(parts[0]).\(parts[1]).\(parts[2]).255" : "255.255.255.255"
        var sent = false

        for host in Set([subnetBroadcast, "255.255.255.255"]) {
            let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard socketFD >= 0 else { continue }
            var enabled: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            inet_pton(AF_INET, host, &address.sin_addr)
            for _ in 0..<3 {
                let count = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socketFD, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sent = sent || count == packet.count
                usleep(150_000)
            }
            close(socketFD)
        }
        return sent
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
                Image(systemName: systemImage).font(.system(size: 21, weight: .semibold))
                if !title.isEmpty { Text(l10n(title)).font(.caption2.weight(.medium)) }
            }
            .foregroundStyle(tint).frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: Circle())
        .overlay(Circle().strokeBorder(.separator.opacity(0.35), lineWidth: 1))
        .accessibilityLabel(title.isEmpty ? systemImage : l10n(title))
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    static let locationOptions = ["未设置", "客厅", "卧室", "书房", "自定义"]

    @Published var profileName: String
    @Published var modelName: String
    @Published var locationChoice: String
    @Published var customLocation: String
    @Published var ip: String
    @Published var psk = ""
    @Published var mac: String
    @Published var errorText = ""
    @Published var isSaving = false

    init(profile: TVProfile?, ip: String, mac: String) {
        profileName = profile?.name ?? "Sony BRAVIA"
        modelName = profile?.model ?? ""
        let savedLocation = profile?.location ?? ""
        if ["客厅", "卧室", "书房"].contains(savedLocation) {
            locationChoice = savedLocation
            customLocation = ""
        } else if savedLocation.isEmpty {
            locationChoice = "未设置"
            customLocation = ""
        } else {
            locationChoice = "自定义"
            customLocation = savedLocation
        }
        self.ip = ip
        self.mac = mac
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

private struct SettingsView: View {
    @ObservedObject var controller: SonyController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SettingsModel

    init(controller: SonyController) {
        self.controller = controller
        _model = StateObject(wrappedValue: SettingsModel(
            profile: controller.activeProfile,
            ip: controller.targetIP,
            mac: controller.macAddress
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("电视设置").font(.title2.bold())
                    Text("Profile 与 Sony IP Control").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Form {
                Section("电视信息") {
                    TextField("名称", text: $model.profileName)
                    TextField("型号", text: $model.modelName)
                    Picker("位置", selection: $model.locationChoice) {
                        ForEach(SettingsModel.locationOptions, id: \.self) { Text(l10n($0)) }
                    }
                    if model.locationChoice == "自定义" {
                        TextField("自定义位置", text: $model.customLocation)
                    }
                }
                Section("连接") {
                TextField("电视 IP 地址", text: $model.ip)
                SecureField(l10n(controller.hasPSK ? "新 PSK（留空则保留）" : "PSK"), text: $model.psk)
                TextField("MAC 地址（连接成功后自动读取）", text: $model.mac)
                }
            }
            .formStyle(.grouped)
            Text("电视端需启用 Remote Start、Simple IP Control，并把认证方式设为 Pre-Shared Key。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.errorText.isEmpty {
                Label(model.errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(l10n("设置错误：%@", model.errorText))
            }
            HStack {
                Spacer()
                Button {
                    model.isSaving = true
                    model.errorText = ""
                    Task {
                        if let error = await controller.validateAndSave(
                            ip: model.ip,
                            newPSK: model.psk,
                            manualMAC: model.mac,
                            profileName: model.profileName,
                            modelName: model.modelName,
                            locationName: model.resolvedLocation ?? ""
                        ) {
                            model.errorText = error
                            model.isSaving = false
                        } else { dismiss() }
                    }
                } label: {
                    if model.isSaving { ProgressView().controlSize(.small) } else { Text("验证并保存") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSaving || model.ip.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 480)
    }
}

@MainActor
private final class TVKeyboardModel: ObservableObject {
    @Published var text = ""
    @Published var errorText = ""
    @Published var isSending = false
}

private struct TVKeyboardView: View {
    @ObservedObject var controller: SonyController
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFieldFocused: Bool
    @StateObject private var model = TVKeyboardModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("电视键盘").font(.title2.bold())
                    Text("支持 Mac 输入法和 ⌘V 粘贴").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            TextField("输入网址、账号或搜索文字", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit { submit(model.text) }

            Text("先在电视上的 TiviMate 中进入输入框，再从这里发送；Sony API 会把完整文本写入当前输入框。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !model.errorText.isEmpty {
                Label(model.errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("粘贴") {
                    model.text = NSPasteboard.general.string(forType: .string) ?? ""
                    isTextFieldFocused = true
                }
                Button("粘贴并发送") {
                    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
                    model.text = pasted
                    submit(pasted)
                }
                Spacer()
                Button {
                    submit(model.text)
                } label: {
                    if model.isSending { ProgressView().controlSize(.small) } else { Text("发送到电视") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSending || model.text.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 470)
        .onAppear { isTextFieldFocused = true }
    }

    private func submit(_ value: String) {
        guard !model.isSending else { return }
        model.errorText = ""
        model.isSending = true
        Task {
            model.errorText = await controller.sendText(value) ?? ""
            model.isSending = false
            if model.errorText.isEmpty { isTextFieldFocused = true }
        }
    }
}

@MainActor
private final class RemoteKeyboardMonitor: ObservableObject {
    @Published private(set) var isShowingShortcutGuide = false
    private var monitor: Any?
    private var commandHoldTask: Task<Void, Never>?
    private var commandIsDown = false

    func start(controller: SonyController) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let canUseRemoteShortcuts = !controller.isShowingSettings
                && !controller.isShowingKeyboard
                && !controller.isShowingOnboarding
                && !controller.isShowingProfileManager
                && !(NSApp.keyWindow?.firstResponder is NSTextView)

            if event.type == .flagsChanged {
                self.updateCommandHold(event, enabled: canUseRemoteShortcuts)
                return event
            }

            self.cancelShortcutGuide()
            guard canUseRemoteShortcuts,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }

            if event.type == .keyDown {
                switch event.keyCode {
                case 115: // Home
                    controller.send(command: "Home", label: "主页")
                    return nil
                default:
                    if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                       event.charactersIgnoringModifiers?.lowercased() == "m" {
                        controller.send(command: "Mute", label: "静音")
                        return nil
                    }
                }
            }

            // macOS media-key events encode the key type in the high 16 bits.
            if event.type == .systemDefined, event.subtype.rawValue == 8 {
                let mediaKey = (event.data1 & 0xFFFF0000) >> 16
                let keyState = (event.data1 & 0x0000FF00) >> 8
                guard keyState == 0xA else { return event }
                if event.modifierFlags.contains(.command) {
                    switch mediaKey {
                    case 0: // NX_KEYTYPE_SOUND_UP
                        controller.send(command: "VolumeUp", label: "音量加")
                    case 1: // NX_KEYTYPE_SOUND_DOWN
                        controller.send(command: "VolumeDown", label: "音量减")
                    case 7: // NX_KEYTYPE_MUTE
                        controller.send(command: "Mute", label: "静音")
                    default:
                        return event
                    }
                    return nil
                }
                if mediaKey == 7 { // Plain hardware mute keeps the existing TV-mute behavior.
                    controller.send(command: "Mute", label: "静音")
                    return nil
                }
            }
            return event
        }
    }

    func stop() {
        cancelShortcutGuide()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func updateCommandHold(_ event: NSEvent, enabled: Bool) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers == .command
        if enabled && commandOnly && !commandIsDown {
            commandIsDown = true
            commandHoldTask?.cancel()
            commandHoldTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let self, self.commandIsDown else { return }
                self.isShowingShortcutGuide = true
            }
        } else if !commandOnly {
            commandIsDown = false
            cancelShortcutGuide()
        }
    }

    private func cancelShortcutGuide() {
        commandHoldTask?.cancel()
        commandHoldTask = nil
        isShowingShortcutGuide = false
    }
}

private struct ShortcutGuideOverlay: View {
    private let shortcuts: [(String, String)] = [
        ("↑ ↓ ← →", "方向"),
        ("Return", "OK"),
        ("Esc", "返回"),
        ("Home / H", "主页"),
        ("M / 静音键", "静音"),
        ("⌘ + 音量键", "电视音量"),
        ("⌘K", "电视键盘"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("快捷键", systemImage: "command")
                    .font(.headline)
                Spacer()
                Text("松开 ⌘ 关闭").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(shortcuts, id: \.0) { shortcut in
                HStack(spacing: 16) {
                    Text(l10n(shortcut.0))
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .frame(width: 118, alignment: .leading)
                    Text(l10n(shortcut.1)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 292)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("遥控器快捷键说明")
        .allowsHitTesting(false)
    }
}

struct RemoteView: View {
    @StateObject private var controller = SonyController()
    @StateObject private var keyboardMonitor = RemoteKeyboardMonitor()

    var body: some View {
        VStack(spacing: 22) {
            header
            profileSelector
            topControls
            directionalPad
            navigationControls
            keyboardControl
            volumeControls
            footer
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(width: 350, height: 734)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if keyboardMonitor.isShowingShortcutGuide {
                ShortcutGuideOverlay()
            }
        }
        .onAppear {
            controller.start()
            keyboardMonitor.start(controller: controller)
        }
        .onDisappear { keyboardMonitor.stop() }
        .sheet(isPresented: $controller.isShowingSettings) { SettingsView(controller: controller) }
        .sheet(isPresented: $controller.isShowingKeyboard) { TVKeyboardView(controller: controller) }
        .sheet(isPresented: $controller.isShowingOnboarding) { TVSetupView(controller: controller) }
        .sheet(isPresented: $controller.isShowingProfileManager) { TVSetupView(controller: controller) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(controller.isConnected ? Color.green : Color.red).frame(width: 9, height: 9).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sony BRAVIA Remote").font(.title2.bold())
                Text(controller.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.refreshStatus() } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 32) }
                .buttonStyle(.borderless).disabled(controller.isBusy).help("刷新电视状态").accessibilityLabel("刷新电视状态")
            Button { controller.isShowingSettings = true } label: { Image(systemName: "gearshape").frame(width: 32, height: 32) }
                .buttonStyle(.borderless).help("Sony IP Control 设置").accessibilityLabel("Sony IP Control 设置")
        }
    }

    private var topControls: some View {
        HStack {
            RemoteButton(title: "电源", systemImage: "power", tint: .red) { controller.togglePower() }
            Spacer()
            RemoteButton(title: "静音", systemImage: "speaker.slash.fill") { controller.send(command: "Mute", label: "静音") }
        }.padding(.horizontal, 24)
    }

    private var profileSelector: some View {
        Menu {
            ForEach(controller.profiles) { profile in
                Button {
                    controller.selectProfile(profile)
                } label: {
                    if profile.id == controller.activeProfileID {
                        Label(profile.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(profile.displayTitle)
                    }
                }
            }
            if !controller.profiles.isEmpty { Divider() }
            Button {
                controller.isShowingProfileManager = true
            } label: {
                Label(l10n(controller.profiles.isEmpty ? "添加电视" : "管理电视…"), systemImage: "tv.and.mediabox")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tv")
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.activeProfile?.displayTitle ?? l10n("添加 Sony BRAVIA"))
                        .font(.callout.weight(.semibold))
                    if let profile = controller.activeProfile {
                        Text(profile.ipAddress).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 42)
        }
        .menuStyle(.borderlessButton)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(l10n("当前电视：%@", controller.activeProfile?.displayTitle ?? l10n("未设置")))
    }

    private var directionalPad: some View {
        ZStack {
            Circle().fill(.quaternary).frame(width: 218, height: 218)
                .overlay(Circle().strokeBorder(.separator.opacity(0.35), lineWidth: 1))
            Button { controller.send(command: "Up", label: "上") } label: { Image(systemName: "chevron.up").frame(width: 64, height: 58) }
                .buttonStyle(.plain).offset(y: -73).keyboardShortcut(.upArrow, modifiers: []).accessibilityLabel("上")
            Button { controller.send(command: "Down", label: "下") } label: { Image(systemName: "chevron.down").frame(width: 64, height: 58) }
                .buttonStyle(.plain).offset(y: 73).keyboardShortcut(.downArrow, modifiers: []).accessibilityLabel("下")
            Button { controller.send(command: "Left", label: "左") } label: { Image(systemName: "chevron.left").frame(width: 58, height: 64) }
                .buttonStyle(.plain).offset(x: -73).keyboardShortcut(.leftArrow, modifiers: []).accessibilityLabel("左")
            Button { controller.send(command: "Right", label: "右") } label: { Image(systemName: "chevron.right").frame(width: 58, height: 64) }
                .buttonStyle(.plain).offset(x: 73).keyboardShortcut(.rightArrow, modifiers: []).accessibilityLabel("右")
            Button { controller.send(command: "Confirm", label: "OK") } label: {
                Text("OK").font(.headline).frame(width: 82, height: 82).background(Color.accentColor, in: Circle()).foregroundStyle(.white)
            }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: []).accessibilityLabel("确认")
        }.disabled(controller.isBusy)
    }

    private var navigationControls: some View {
        HStack(spacing: 42) {
            RemoteButton(title: "返回", systemImage: "chevron.backward") { controller.send(command: "Return", label: "返回") }
                .keyboardShortcut(.escape, modifiers: []).help("返回（Esc）")
            RemoteButton(title: "主页", systemImage: "house.fill") { controller.send(command: "Home", label: "主页") }
                .keyboardShortcut("h", modifiers: []).help("主页（H / Home）")
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 18) {
            Button { controller.send(command: "VolumeDown", label: "音量减") } label: {
                Label("音量减", systemImage: "speaker.minus.fill").frame(maxWidth: .infinity, minHeight: 46)
            }
            Button { controller.send(command: "VolumeUp", label: "音量加") } label: {
                Label("音量加", systemImage: "speaker.plus.fill").frame(maxWidth: .infinity, minHeight: 46)
            }
        }.buttonStyle(.bordered).controlSize(.large).disabled(controller.isBusy)
    }

    private var keyboardControl: some View {
        Button {
            controller.isShowingKeyboard = true
        } label: {
            Label("电视键盘", systemImage: "keyboard")
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("k", modifiers: [.command])
        .help("输入或粘贴文字到电视（⌘K）")
        .disabled(controller.isBusy)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(controller.lastAction.isEmpty ? l10n("Sony IP · %@", controller.targetIP) : controller.lastAction)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            Text("IRCC-IP · REST API · Wake-on-LAN").font(.caption2).foregroundStyle(.tertiary)
            Text("v\(appVersion) · © 2026 Zhuchao Li · zhuchao.li@gmail.com")
                .font(.caption2).foregroundStyle(.tertiary)
        }.frame(minHeight: 48)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

@main
struct SonyRemoteApp: App {
    var body: some Scene {
        WindowGroup { RemoteView() }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) { } }
    }
}
