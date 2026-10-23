import Darwin
import Foundation

struct DiscoveredTV: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let model: String
    let ipAddress: String
}

private struct SSDPCandidate: Sendable {
    let ipAddress: String
    let location: String?
    let response: String
}

enum SonyTVDiscovery {
    static func discover(timeout: TimeInterval = 3.2) async -> [DiscoveredTV] {
        let candidates = await Task.detached(priority: .userInitiated) {
            discoverCandidates(timeout: timeout)
        }.value

        var televisions: [DiscoveredTV] = []
        for candidate in candidates {
            if let television = await identify(candidate) {
                televisions.append(television)
            }
        }
        let knownIPs = Set(televisions.map(\.ipAddress))
        let subnetTelevisions = await discoverOnLocalSubnets(excluding: knownIPs)
        for television in subnetTelevisions where !televisions.contains(where: { $0.ipAddress == television.ipAddress }) {
            televisions.append(television)
        }
        return televisions.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func discoverOnLocalSubnets(excluding knownIPs: Set<String>) async -> [DiscoveredTV] {
        let prefixes = await Task.detached(priority: .utility) { localIPv4Prefixes() }.value
        let addresses = prefixes.flatMap { prefix in
            (1...254).map { "\(prefix).\($0)" }
        }.filter { !knownIPs.contains($0) }

        var televisions: [DiscoveredTV] = []
        let batchSize = 64
        for start in stride(from: 0, to: addresses.count, by: batchSize) {
            let end = min(start + batchSize, addresses.count)
            await withTaskGroup(of: DiscoveredTV?.self) { group in
                for ipAddress in addresses[start..<end] {
                    group.addTask { await probeSonyTV(ipAddress) }
                }
                for await television in group {
                    if let television { televisions.append(television) }
                }
            }
        }
        return televisions
    }

    private static func probeSonyTV(_ ipAddress: String) async -> DiscoveredTV? {
        guard let url = URL(string: "http://\(ipAddress)/sony/system") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 0.65
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"method":"getPowerStatus","params":[],"id":1,"version":"1.0"}"#.utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [[String: Any]],
              result.first?["status"] is String else { return nil }
        return DiscoveredTV(id: ipAddress, name: "Sony BRAVIA", model: "", ipAddress: ipAddress)
    }

    nonisolated private static func discoverCandidates(timeout: TimeInterval) -> [SSDPCandidate] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return [] }
        defer { close(socketFD) }

        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)

        let targets = [
            "urn:schemas-sony-com:service:ScalarWebAPI:1",
            "ssdp:all",
        ]
        for target in targets {
            let message = """
            M-SEARCH * HTTP/1.1\r
            HOST: 239.255.255.250:1900\r
            MAN: \"ssdp:discover\"\r
            MX: 2\r
            ST: \(target)\r
            USER-AGENT: macOS SonyBRAVIARemote/1.0\r
            \r
            """
            message.withCString { pointer in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(socketFD, pointer, strlen(pointer), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var candidatesByIP: [String: SSDPCandidate] = [:]
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &source) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(socketFD, &buffer, buffer.count - 1, 0, sockaddrPointer, &sourceLength)
                }
            }
            guard received > 0 else { continue }

            let data = Data(buffer.prefix(received))
            guard let response = String(data: data, encoding: .utf8) else { continue }
            let headers = parseHeaders(response)
            let location = headers["location"]
            let sourceIP = ipv4String(source.sin_addr)
            let locationIP = location.flatMap { URL(string: $0)?.host }
            guard let ipAddress = locationIP ?? sourceIP, !ipAddress.isEmpty else { continue }

            let candidate = SSDPCandidate(ipAddress: ipAddress, location: location, response: response)
            if candidatesByIP[ipAddress] == nil || response.localizedCaseInsensitiveContains("Sony") {
                candidatesByIP[ipAddress] = candidate
            }
        }
        return Array(candidatesByIP.values)
    }

    private static func identify(_ candidate: SSDPCandidate) async -> DiscoveredTV? {
        var description = ""
        if let location = candidate.location, let url = URL(string: location) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                description = String(data: data, encoding: .utf8) ?? ""
            }
        }

        let combined = candidate.response + "\n" + description
        let friendlyName = xmlValue("friendlyName", in: description)
        let modelName = xmlValue("modelName", in: description)
        let manufacturer = xmlValue("manufacturer", in: description)
        let looksLikeSony = manufacturer.localizedCaseInsensitiveContains("Sony")
            || combined.localizedCaseInsensitiveContains("Sony")
        let looksLikeBRAVIA = combined.localizedCaseInsensitiveContains("BRAVIA")
            || modelName.range(of: #"^(KD|KDL|XR|FW|BZ)-"#, options: [.regularExpression, .caseInsensitive]) != nil

        guard looksLikeSony && looksLikeBRAVIA else { return nil }
        let name = friendlyName.isEmpty ? "Sony BRAVIA" : friendlyName
        return DiscoveredTV(
            id: candidate.ipAddress,
            name: name,
            model: modelName,
            ipAddress: candidate.ipAddress
        )
    }

    nonisolated private static func parseHeaders(_ response: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in response.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }

    nonisolated private static func ipv4String(_ address: in_addr) -> String? {
        var mutableAddress = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &mutableAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    nonisolated private static func localIPv4Prefixes() -> [String] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var prefixes = Set<String>()
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var socketAddress = address.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                &socketAddress,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let ipAddress = String(cString: host)
            let parts = ipAddress.split(separator: ".")
            guard parts.count == 4,
                  isPrivateIPv4(parts) else { continue }
            prefixes.insert(parts.prefix(3).joined(separator: "."))
        }
        return Array(prefixes)
    }

    nonisolated private static func isPrivateIPv4(_ parts: [Substring]) -> Bool {
        guard let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }

    private static func xmlValue(_ tag: String, in xml: String) -> String {
        guard !xml.isEmpty,
              let expression = try? NSRegularExpression(
                pattern: "<\\s*(?:[A-Za-z0-9_]+:)?\(tag)\\b[^>]*>(.*?)<\\s*/\\s*(?:[A-Za-z0-9_]+:)?\(tag)\\s*>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
              ) else { return "" }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = expression.firstMatch(in: xml, range: range),
              let valueRange = Range(match.range(at: 1), in: xml) else { return "" }
        return String(xml[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
