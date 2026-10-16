import XCTest
@testable import QuotaDockCore

final class AdditionalCLIProviderTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCopilotQuotaUsesServerPercentageAndKeepsUnlimitedSeparate() throws {
        let quota = data(#"{"quotaSnapshots":{"premium_interactions":{"isUnlimitedEntitlement":false,"remainingPercentage":25,"entitlementRequests":300,"usedRequests":400,"overage":100,"resetDate":"2099-01-01T00:00:00Z"},"completions":{"isUnlimitedEntitlement":true}}}"#)
        let result = try CopilotCLIQuotaProvider.parse(quota: quota, identity: data(#"{"login":"octocat","copilotPlan":"individual"}"#))
        XCTAssertEqual(result.accountName, "octocat")
        XCTAssertEqual(result.metrics.count, 2)
        XCTAssertTrue(result.metrics[0].isUnlimited)
        XCTAssertEqual(result.metrics[1].remainingPercent, 25)
        XCTAssertFalse(result.metrics.contains { $0.category == .purchased })
        XCTAssertThrowsError(try CopilotCLIQuotaProvider.parse(quota: data(#"{"quotaSnapshots":{"chat":{"isUnlimitedEntitlement":false,"remainingPercentage":true}}}"#), identity: data("{}")))
    }

    func testCursorVisibleGrantsZeroAndExpiry() throws {
        let result = try CursorCLIQuotaProvider.parse(quota: data(#"{"activeGrants":[{"grantId":"a","showInClient":true,"totalCents":"2000","remainingCents":"1234","campaignName":"Pro","expiresAtMs":"4070908800000"},{"grantId":"b","showInClient":true},{"grantId":"c","showInClient":false,"remainingCents":"999999"},{"grantId":"d","showInClient":true,"expiresAtMs":"1"}]}"#), identity: data(#"{"firstName":"Ada","lastName":"Lovelace","email":"test@example.com"}"#))
        XCTAssertEqual(result.metrics.count, 2)
        XCTAssertEqual(result.metrics[0].remainingBalance, 12.34)
        XCTAssertEqual(result.metrics[1].remainingBalance, 0)
        XCTAssertEqual(result.accountName, "Ada Lovelace")
        let empty = try CursorCLIQuotaProvider.parse(quota: data(#"{"usageLimitPolicyStatus":{}}"#), identity: nil)
        XCTAssertTrue(empty.metrics.isEmpty)
        XCTAssertNotNil(empty.notice)
        XCTAssertThrowsError(try CursorCLIQuotaProvider.parse(quota: data("{}"), identity: nil))
    }

    func testCursorUsesSelectedCredentialAndFixedHost() async throws {
        let dir = try directory()
        let auth = dir.appendingPathComponent("auth.json")
        try data(#"{"accessToken":"selected-token"}"#).write(to: auth)
        let provider = CursorCLIQuotaProvider { request in
            XCTAssertEqual(request.url?.host, "api2.cursor.sh")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer selected-token")
            if request.url?.path.hasSuffix("GetMe") == true { throw CLIQuotaError.upstream }
            return Data(#"{"activeGrants":[]}"#.utf8)
        }
        let result = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias", externalID: auth.path))
        XCTAssertNotNil(result.notice)
    }

    func testOriNeverTreatsUncappedKeyAsUnlimitedBalance() throws {
        let result = try OriCLIQuotaProvider.parse(data(#"{"data":{"limit_remaining":null,"usage":12}}"#))
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertNotNil(result.notice)
        let capped = try OriCLIQuotaProvider.parse(data(#"{"data":{"limit_remaining":5.5,"usage":9}}"#))
        XCTAssertEqual(capped.metrics[0].remainingBalance, 5.5)
        XCTAssertEqual(capped.metrics[0].label, "密钥可用额度")
        XCTAssertThrowsError(try OriCLIQuotaProvider.parse(data(#"{"data":{"usage":0}}"#)))
        XCTAssertThrowsError(try OriCLIQuotaProvider.parse(data(#"{"data":{"limit_remaining":true}}"#)))
    }

    func testOriRespectsSignedOutAndProtectedRecords() throws {
        XCTAssertEqual(try OriCLIQuotaProvider.credential(data(#"{"key":"sk-or-test","createdAt":"2026-01-01","userId":null}"#)), "sk-or-test")
        XCTAssertEqual(try OriCLIQuotaProvider.credential(data(#"{"version":1,"storage":"plaintext","key":"sk-or-test"}"#)), "sk-or-test")
        for storage in ["signed-out", "encrypted", "oidc", "connect"] {
            XCTAssertThrowsError(try OriCLIQuotaProvider.credential(data("{\"version\":2,\"storage\":\"\(storage)\",\"key\":\"sk-or-stale\"}")))
        }
    }

    func testHarnessCredentialsAndBalances() throws {
        XCTAssertEqual(try DeepSeekCLIQuotaProvider.credential(data("OTHER_KEY: secret\nDEEPSEEK_API_KEY: 'sk-test'\n"), separator: ":"), "sk-test")
        XCTAssertEqual(try DeepSeekCLIQuotaProvider.credential(data("export DEEPSEEK_API_KEY=\"sk-test\""), separator: "="), "sk-test")
        XCTAssertThrowsError(try DeepSeekCLIQuotaProvider.credential(data("DEEPSEEK_API_KEY: !include secret"), separator: ":"))
        XCTAssertThrowsError(try DeepSeekCLIQuotaProvider.credential(data("DEEPSEEK_API_KEY: sk-a\nDEEPSEEK_API_KEY: sk-b"), separator: ":"))
        XCTAssertEqual(try DeepSeekCLIQuotaProvider.credential(data("version: 1\nrefs:\n  DEEPSEEK_API_KEY: sk-correct\nrecords:\n  unrelated:\n    env:\n      DEEPSEEK_API_KEY: sk-wrong"), separator: ":"), "sk-correct")
        XCTAssertNil(try DeepSeekCLIQuotaProvider.credential(data("version: 1\nrecords:\n  unrelated:\n    env:\n      DEEPSEEK_API_KEY: sk-wrong"), separator: ":"))
        let balances = try DeepSeekCLIQuotaProvider.parse(data(#"{"balance_infos":[{"currency":"CNY","total_balance":"12.3"},{"currency":"USD","total_balance":"0"}]}"#))
        XCTAssertEqual(balances.metrics.map(\.remainingBalance), [12.3, 0])
        XCTAssertEqual(balances.metrics.map(\.unit), ["CNY", "USD"])
    }

    func testHarnessAcceptsOpaqueKeysWithoutAssumingPrefix() throws {
        XCTAssertEqual(try DeepSeekCLIQuotaProvider.credential(data("version: 1\nrefs:\n  DEEPSEEK_API_KEY: opaque-test_123.456\n"), separator: ":"), "opaque-test_123.456")
        XCTAssertEqual(try DeepSeekCLIQuotaProvider.credential(data("DEEPSEEK_API_KEY=opaque-test"), separator: "="), "opaque-test")
        for value in ["", "!include secret", "*alias", "bad token", "密钥", "{record: id}"] {
            XCTAssertThrowsError(try DeepSeekCLIQuotaProvider.credential(data("DEEPSEEK_API_KEY: " + value), separator: ":")) { error in
                XCTAssertEqual(error as? DeepSeekCLIError, .invalidCredential)
            }
        }
        XCTAssertThrowsError(try DeepSeekCLIQuotaProvider.parse(data("{}"))) { error in
            XCTAssertEqual(error as? DeepSeekCLIError, .invalidBalance)
        }
    }

    func testHarnessFetchUsesSelectedOpaqueKey() async throws {
        let dir = try directory()
        let file = dir.appendingPathComponent(".credentials.yaml")
        try data("version: 1\nrefs:\n  DEEPSEEK_API_KEY: opaque-test\n").write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let provider = DeepSeekCLIQuotaProvider { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-test")
            return Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"12.3"}]}"#.utf8)
        }
        let result = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias", externalID: dir.path))
        XCTAssertEqual(result.metrics.first?.remainingBalance, 12.3)
    }

    func testHarnessOverrideDoesNotReadOrModifyLocalCredentials() async throws {
        let dir = try directory()
        let file = dir.appendingPathComponent(".credentials.yaml")
        let original = data("invalid local credentials")
        try original.write(to: file)
        let provider = DeepSeekCLIQuotaProvider { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer override-test")
            return Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"1"}]}"#.utf8)
        }
        let account = Account(toolID: UUID(), name: "Alias", externalID: dir.path)
        _ = try await provider.fetch(account: account, token: "override-test")
        XCTAssertEqual(try Data(contentsOf: file), original)
        let failing = DeepSeekCLIQuotaProvider { _ in throw CLIQuotaError.upstream }
        do {
            _ = try await failing.fetch(account: account, token: "override-test")
            XCTFail("Must propagate the override failure without reading local credentials")
        } catch { XCTAssertTrue(error is CLIQuotaError) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testQwenHistoryDeduplicatesAndNeverCreatesQuota() throws {
        let now = Date()
        let stamp = now.timeIntervalSince1970 * 1000
        let one = "{\"version\":1,\"sessionId\":\"a\",\"timestamp\":\(stamp),\"models\":{\"qwen\":{\"totalTokens\":100,\"requests\":2}}}"
        let result = try QwenCLIUsageProvider.parse(data: data(one + "\n" + one), modified: now, now: now)
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertTrue(result.usageSummary?.contains("100 tokens") == true)
        XCTAssertFalse(result.usageSummary?.contains("200 tokens") == true)
        let encoded = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(QuotaSnapshot.self, from: encoded), result)
        XCTAssertThrowsError(try QwenCLIUsageProvider.parse(data: data("not json"), modified: now))
    }

    func testAllCLIProvidersStayWithinTheirBrands() {
        for (name, provider) in [("Cursor", ProviderKind.cursorCLI), ("Qwen", .qwenCLI), ("Copilot", .copilotCLI), ("DeepSeek", .deepseekCLI), ("OpenRouter", .oriCLI)] {
            XCTAssertTrue(ToolDefinition(name: name).availableProviders.contains(provider))
            XCTAssertFalse(ToolDefinition(name: "自定义").availableProviders.contains(provider))
        }
    }

    func testCLIFramingHandlesFragmentationAndOptionalIdentityFailure() async throws {
        let dir = try directory()
        let script = dir.appendingPathComponent("server.py")
        try data(#"""
        import sys,json,time
        for expected in ['account.getQuota','auth.getStatus']:
            header=b''
            while not header.endswith(b'\r\n\r\n'):
                x=sys.stdin.buffer.read(1)
                if not x: sys.exit(4)
                header+=x
            n=int(header.split(b':')[1].strip())
            req=json.loads(sys.stdin.buffer.read(n))
            assert req['method']==expected
            reply={'jsonrpc':'2.0','id':req['id']}
            if expected=='account.getQuota': reply['result']={'quotaSnapshots':{}}
            else: reply['error']={'code':-32601,'message':'DO-NOT-LEAK'}
            body=json.dumps(reply).encode()
            frame=b'Content-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body
            for i in range(0,len(frame),3):
                sys.stdout.buffer.write(frame[i:i+3]);sys.stdout.buffer.flush();time.sleep(.001)
        time.sleep(10)
        """#).write(to: script)
        let replies = try await CLIReadSession(executable: CLIProcess.executable(["python3"]), arguments: [script.path], environment: CLIProcess.environment(), methods: ["account.getQuota", "auth.getStatus"], requiredReplies: 1, timeout: 3).run()
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[1], data("{}"))
    }

    func testCLITimeoutAndCancellationAreBoundedAndDoNotLeakErrors() async throws {
        let python = try CLIProcess.executable(["python3"])
        let start = Date()
        do {
            _ = try await CLIReadSession(executable: python, arguments: ["-c", "import time;time.sleep(20)"], environment: CLIProcess.environment(), timeout: 0.1).run()
            XCTFail("expected timeout")
        } catch { XCTAssertTrue(error is CLIProcessError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let task = Task { try await CLIReadSession(executable: python, arguments: ["-c", "import time;time.sleep(20)"], environment: CLIProcess.environment()).run() }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await CLIReadSession(executable: python, arguments: ["-c", "import sys;print('secret');sys.exit(1)"], environment: CLIProcess.environment()).run()
            XCTFail("expected failure")
        } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
    }
}
