import XCTest
import CryptoKit
@testable import VoiceMemo

final class TingwuSignatureTests: XCTestCase {
    func testCanonicalRequestMatchesServerExample() {
        let settings = SettingsStore()
        let service = TingwuService(settings: settings)
        let headers: [String: String] = [
            "content-type": "application/json",
            "host": "tingwu.cn-beijing.aliyuncs.com",
            "x-acs-action": "CreateTask",
            "x-acs-content-sha256": "d2f9dc0dd88d9628af1137b7018eb013020cc2fe9cb2bc62b7c1246655113b05",
            "x-acs-date": "2026-01-20T09:06:00Z",
            "x-acs-signature-method": "ACS3-HMAC-SHA256",
            "x-acs-signature-nonce": "860EF1DA-D1E4-4F16-BCAF-889D92BEB256",
            "x-acs-version": "2023-09-30"
        ]
        
        let canonical = service.buildCanonicalRequest(
            method: "PUT",
            uri: "/openapi/tingwu/v2/tasks",
            query: "type=offline",
            headers: headers,
            contentSha256: "d2f9dc0dd88d9628af1137b7018eb013020cc2fe9cb2bc62b7c1246655113b05"
        )
        
        let expected = """
        PUT
        /openapi/tingwu/v2/tasks
        type=offline
        content-type:application/json
        host:tingwu.cn-beijing.aliyuncs.com
        x-acs-action:CreateTask
        x-acs-content-sha256:d2f9dc0dd88d9628af1137b7018eb013020cc2fe9cb2bc62b7c1246655113b05
        x-acs-date:2026-01-20T09:06:00Z
        x-acs-signature-method:ACS3-HMAC-SHA256
        x-acs-signature-nonce:860EF1DA-D1E4-4F16-BCAF-889D92BEB256
        x-acs-version:2023-09-30
        
        content-type;host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-method;x-acs-signature-nonce;x-acs-version
        d2f9dc0dd88d9628af1137b7018eb013020cc2fe9cb2bc62b7c1246655113b05
        """
        
        XCTAssertEqual(canonical, expected)
    }
    
    func testCanonicalRequestHashMatchesServerStringToSign() {
        let settings = SettingsStore()
        let service = TingwuService(settings: settings)
        let headers: [String: String] = [
            "content-type": "application/json",
            "host": "tingwu.cn-beijing.aliyuncs.com",
            "x-acs-action": "CreateTask",
            "x-acs-content-sha256": "697ca4a31f546a905b6ddb887d2a2bc26512442dba7bcd4ef82ab876871d8a4b",
            "x-acs-date": "2026-01-20T09:20:50Z",
            "x-acs-signature-method": "ACS3-HMAC-SHA256",
            "x-acs-signature-nonce": "466DFF45-7548-4D84-8AB2-BFA6D52628F2",
            "x-acs-version": "2023-09-30"
        ]
        
        let canonical = service.buildCanonicalRequest(
            method: "PUT",
            uri: "/openapi/tingwu/v2/tasks",
            query: "type=offline",
            headers: headers,
            contentSha256: "697ca4a31f546a905b6ddb887d2a2bc26512442dba7bcd4ef82ab876871d8a4b"
        )
        
        let hash = SHA256.hash(data: canonical.data(using: .utf8)!).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "482c53c8258c375d1fe5f39b4a66f19c918f859d4e1aa064669db2185322c5d6")
    }
}
