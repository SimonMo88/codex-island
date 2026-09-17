import Foundation
import SQLite3

/// Reads Cursor Desktop's existing session and polls the current-period
/// dashboard. Cursor owns token refresh and persistence; this adapter never
/// calls OAuth or writes `state.vscdb` / the keychain.
enum CursorConnection {
    struct Credential {
        let accessToken: String
        let email: String?
        let plan: String?
        let accountID: String?
    }

    private struct StoredCredential: Codable {
        let accessToken: String
        let email: String?
        let plan: String?
        let accountID: String?
    }

    static func fetch() async throws -> ConnectedUsage {
        let first = try await Task.detached(priority: .utility) { try readStoredCredential() }.value
        try Task.checkCancellation()
        do {
            return try await fetch(credentialData: encode(first), send: send)
        } catch let error as ProviderConnectionError {
            switch error {
            case .expired, .http(401):
                let second = try await Task.detached(priority: .utility) { try readStoredCredential() }.value
                try Task.checkCancellation()
                return try await fetch(credentialData: encode(second), send: send)
            default:
                throw error
            }
        }
    }

    static func fetch(credentialData: Data,
                      send: (URLRequest) async throws -> Data,
                      now: Date = Date()) async throws -> ConnectedUsage {
        let credential = try credential(from: credentialData, now: now)
        var usage = try parse(await send(try request(credential: credential)))
        usage.account = usage.account ?? credential.email
        usage.accountID = usage.accountID ?? credential.accountID ?? credential.email
        usage.plan = usage.plan ?? displayPlan(credential.plan)
        usage.updatedAt = Date()
        return usage
    }

    static func credential(from data: Data, now: Date = Date()) throws -> Credential {
        guard data.count <= 1_048_576 else { throw ProviderConnectionError.invalidResponse }
        let stored = try JSONDecoder().decode(StoredCredential.self, from: data)
        let token = stored.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderConnectionError.signIn }
        if let expiry = jwtExpiry(token), expiry <= now { throw ProviderConnectionError.expired }
        return Credential(accessToken: token, email: stored.email, plan: stored.plan,
                          accountID: stored.accountID ?? jwtSubject(token))
    }

    static func parse(_ data: Data) throws -> ConnectedUsage {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderConnectionError.invalidResponse
        }
        if let code = obj["code"] as? String, code.lowercased().contains("unauth") {
            throw ProviderConnectionError.http(401)
        }
        let planUsage = obj["planUsage"] as? [String: Any] ?? [:]
        let spend = obj["spendLimitUsage"] as? [String: Any] ?? [:]
        let reset = unixMillis(obj["billingCycleEnd"]) ?? unixMillis(planUsage["billingCycleEnd"])
        var limits: [ConnectedLimit] = []
        if let fraction = percentFraction(number(planUsage, "apiPercentUsed")) {
            limits.append(ConnectedLimit(id: "agent", label: "Agent", usedFraction: fraction,
                                         resetAt: reset, kind: .session))
        }
        if let fraction = percentFraction(number(planUsage, "autoPercentUsed")) {
            limits.append(ConnectedLimit(id: "auto", label: "Auto", usedFraction: fraction,
                                         resetAt: reset, kind: .session))
        }
        if let cap = number(planUsage, "limit"), cap.isFinite, cap > 0,
           let used = number(planUsage, "includedSpend") ?? number(planUsage, "totalSpend"),
           used.isFinite, used >= 0 {
            limits.append(ConnectedLimit(id: "included", label: "Included",
                                         usedFraction: min(1, used / cap), resetAt: reset, kind: .credits))
        } else if let fraction = percentFraction(number(planUsage, "totalPercentUsed")),
                  !limits.contains(where: { $0.usedFraction != nil }) {
            limits.append(ConnectedLimit(id: "included", label: "Included", usedFraction: fraction,
                                         resetAt: reset, kind: .credits))
        }
        if let cap = number(spend, "individualLimit"), cap.isFinite, cap > 0,
           let used = number(spend, "individualUsed"), used.isFinite, used >= 0 {
            limits.append(ConnectedLimit(id: "ondemand", label: "On-demand",
                                         usedFraction: min(1, used / cap), resetAt: reset, kind: .credits))
        }
        let plan = displayPlan(string(obj, "planName") ?? ((obj["planInfo"] as? [String: Any]).flatMap { string($0, "planName") }))
        if limits.isEmpty {
            limits.append(ConnectedLimit(id: "included", label: "Included", usedFraction: nil,
                                         resetAt: reset, kind: .credits))
        }
        return ConnectedUsage(
            limits: limits,
            plan: plan,
            message: limits.contains(where: { $0.usedFraction != nil })
                ? nil : "Signed in. Cursor did not report plan usage."
        )
    }

    static func jwtExpiry(_ token: String) -> Date? {
        guard let payload = jwtPayload(token) else { return nil }
        if let exp = payload["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = payload["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
        return nil
    }

    static func readDesktopStore(url: URL, now: Date = Date()) throws -> Credential {
        try credential(from: encode(try readDesktopFields(url: url)), now: now)
    }

    private static func readStoredCredential() throws -> Credential {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        if FileManager.default.isReadableFile(atPath: desktop.path) {
            do { return try readDesktopStore(url: desktop) } catch ProviderConnectionError.signIn {}
        }
        if let token = readKeychainToken() {
            return try credential(from: encode(StoredCredential(accessToken: token, email: nil, plan: nil, accountID: nil)))
        }
        throw ProviderConnectionError.signIn
    }

    private static func readDesktopFields(url: URL) throws -> StoredCredential {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let path = url.absoluteString + (url.absoluteString.contains("?") ? "&mode=ro" : "?mode=ro")
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            throw ProviderConnectionError.signIn
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3000)
        func value(_ key: String) -> String? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
                return nil
            }
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let bytes = sqlite3_column_text(statement, 0) else { return nil }
            return unwrapStoredString(String(cString: bytes))
        }
        guard let token = value("cursorAuth/accessToken"), !token.isEmpty else {
            throw ProviderConnectionError.signIn
        }
        return StoredCredential(accessToken: token,
                                email: value("cursorAuth/cachedEmail"),
                                plan: value("cursorAuth/stripeMembershipType"),
                                accountID: jwtSubject(token))
    }

    private static func readKeychainToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "cursor-access-token", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    private static func request(credential: Credential) throws -> URLRequest {
        guard let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage") else {
            throw ProviderConnectionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: NoProviderRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProviderConnectionError.invalidResponse }
        if response.statusCode == 401 { throw ProviderConnectionError.http(401) }
        guard response.statusCode == 200 else { throw ProviderConnectionError.http(response.statusCode) }
        guard data.count <= 2_097_152 else { throw ProviderConnectionError.invalidResponse }
        return data
    }

    private static func encode(_ credential: Credential) throws -> Data {
        try encode(StoredCredential(accessToken: credential.accessToken, email: credential.email,
                                    plan: credential.plan, accountID: credential.accountID))
    }

    private static func encode(_ stored: StoredCredential) throws -> Data {
        try JSONEncoder().encode(stored)
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func jwtSubject(_ token: String) -> String? {
        jwtPayload(token)?["sub"] as? String
    }

    private static func unwrapStoredString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return trimmed
    }

    private static func number(_ obj: [String: Any], _ key: String) -> Double? {
        if let value = obj[key] as? Double { return value }
        if let value = obj[key] as? Int { return Double(value) }
        if let value = obj[key] as? String { return Double(value) }
        return nil
    }

    private static func string(_ obj: [String: Any], _ key: String) -> String? {
        if let value = obj[key] as? String, !value.isEmpty { return value }
        return nil
    }

    private static func unixMillis(_ raw: Any?) -> Date? {
        let millis: Double?
        if let value = raw as? Double { millis = value }
        else if let value = raw as? Int { millis = Double(value) }
        else if let value = raw as? String { millis = Double(value) }
        else { millis = nil }
        guard let millis, millis.isFinite, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    private static func percentFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return ProviderPayload.fraction(min(value, 100) / 100)
    }

    private static func displayPlan(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free": return "Free"
        case "pro": return "Pro"
        case "pro_plus", "proplus", "pro+": return "Pro+"
        case "ultra": return "Ultra"
        case "team", "business": return "Team"
        case "enterprise": return "Enterprise"
        default: return raw
        }
    }
}
