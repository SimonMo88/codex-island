import Foundation
import SQLite3

@main
struct CursorConnectionTests {
    static var failures = 0
    static func expect(_ value: Bool, _ label: String) {
        if value { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
    }

    @MainActor
    static func main() async throws {
        let usage = try CursorConnection.parse(Data(#"""
        {"billingCycleEnd":"1771077734000","planName":"ultra","planUsage":{
          "autoPercentUsed":0,"apiPercentUsed":46.444,"totalPercentUsed":15.48,
          "includedSpend":23222,"limit":40000}}
        """#.utf8))
        expect(usage.limits.map(\.id) == ["agent", "auto", "included"], "Agent, Auto, and included spend are all parsed")
        expect(usage.limits[0].kind == .session && abs((usage.limits[0].usedFraction ?? -1) - 0.46444) < 0.0001,
               "named-model Agent usage is the peek window")
        expect(usage.limits[1].usedFraction == 0, "zero Auto usage is a real reading")
        expect(usage.plan == "Ultra", "plan name is display-cased")
        expect(usage.limits[0].resetAt == Date(timeIntervalSince1970: 1_771_077_734),
               "billingCycleEnd is unix milliseconds")

        let defaults = ProviderQuotaPreferences.resolve(usage, selection: QuotaSelection())
        expect(defaults.map(\.id) == ["agent", "auto"], "defaults show Agent then Auto")
        expect(ProviderQuotaPreferences.primary(defaults, selection: QuotaSelection())?.id == "agent",
               "peek and alerts use Agent unless customized")

        let missing = try CursorConnection.parse(Data(#"{"planUsage":{}}"#.utf8))
        expect(missing.primary == nil && missing.message != nil, "empty planUsage does not invent zero")

        do {
            _ = try CursorConnection.parse(Data(#"{"code":"unauthenticated"}"#.utf8))
            expect(false, "unauthenticated connect payload is a 401")
        } catch ProviderConnectionError.http(401) {
            expect(true, "unauthenticated connect payload is a 401")
        }

        let live = jwt(exp: 4_000_000_000)
        let credential = try JSONEncoder().encode(["accessToken": live, "email": "dev@example.test", "plan": "pro"])
        var requested: [URLRequest] = []
        let fetched = try await CursorConnection.fetch(credentialData: credential) { request in
            requested.append(request)
            return Data(#"{"planUsage":{"apiPercentUsed":12}}"#.utf8)
        }
        expect(requested.count == 1 && requested[0].httpMethod == "POST", "usage is a single POST")
        expect(requested[0].url?.host == "api2.cursor.sh", "dashboard host is api2.cursor.sh")
        expect(requested[0].url?.path.hasSuffix("GetCurrentPeriodUsage") == true, "current-period usage only")
        expect(requested[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(live)", "Bearer token is the desktop session")
        expect(requested[0].value(forHTTPHeaderField: "Connect-Protocol-Version") == "1", "Connect RPC version is required")
        expect(fetched.account == "dev@example.test" && fetched.plan == "Pro", "identity comes from the local store")
        expect(!String(data: requested[0].url?.absoluteString.data(using: .utf8) ?? Data(), encoding: .utf8)!
            .contains("oauth"), "OAuth refresh is never requested")

        do {
            _ = try await CursorConnection.fetch(credentialData: try JSONEncoder().encode(["accessToken": jwt(exp: 1)])) { _ in
                fatalError("Expired JWT must not call the dashboard")
            }
            expect(false, "expired JWT is rejected before the network")
        } catch ProviderConnectionError.expired {
            expect(true, "expired JWT is rejected before the network")
        }

        let db = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: db) }
        try writeDesktopStore(url: db, token: "\"\(live)\"", email: "quoted@example.test", plan: "pro")
        let desktop = try CursorConnection.readDesktopStore(url: db)
        expect(desktop.accessToken == live && desktop.email == "quoted@example.test",
               "desktop ItemTable strings unwrap JSON quotes")

        if failures > 0 { exit(1) }
        print("PASS Cursor dashboard adapter is read-only")
    }

    private static func jwt(exp: Int) -> String {
        let header = "eyJhbGciOiJub25lIn0"
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp, "sub": "user_1"])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "\(header).\(encoded).sig"
    }

    private static func writeDesktopStore(url: URL, token: String, email: String, plan: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw ProviderConnectionError.invalidResponse
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT, value BLOB)", nil, nil, nil)
        func insert(_ key: String, _ value: String) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(database, "INSERT INTO ItemTable(key, value) VALUES (?, ?)", -1, &statement, nil)
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        insert("cursorAuth/accessToken", token)
        insert("cursorAuth/cachedEmail", email)
        insert("cursorAuth/stripeMembershipType", plan)
    }
}
