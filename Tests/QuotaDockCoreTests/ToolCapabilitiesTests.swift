import XCTest
@testable import QuotaDockCore

final class ToolCapabilitiesTests: XCTestCase {
    func testUnrelatedToolsCannotSelectCodexOrClaudeReaders() {
        for name in ["DeepSeek", "OpenRouter", "Cursor", "Kimi", "通义千问", "Gemini", "GitHub Copilot", "硅基流动", "智谱 GLM"] {
            // Even a legacy misconfigured provider must not override a recognized brand.
            let tool = ToolDefinition(name: name, provider: .codexCLI)
            XCTAssertFalse(tool.availableProviders.contains(.codexCLI), name)
            XCTAssertFalse(tool.availableProviders.contains(.claudeSnapshot), name)
        }
        XCTAssertEqual(ToolDefinition(name: "自定义").availableProviders, [.manual, .httpJSON])
    }

    func testRenamedAndLegacyToolsKeepTheirReaderIdentity() throws {
        var tool = ToolDefinition(name: "Codex", provider: .codexCLI, brandID: "codex")
        tool.name = "团队工具"
        tool.provider = .manual
        let restored = try JSONDecoder().decode(ToolDefinition.self, from: JSONEncoder().encode(tool))
        XCTAssertEqual(restored.availableProviders.first, .codexCLI)
        XCTAssertEqual(ToolDefinition(name: "Claude Code").availableProviders.first, .claudeOAuth)
        XCTAssertEqual(ToolDefinition(name: "以前的别名", provider: .codexCLI).resolvedBrandID, "codex")
    }

    func testCustomEndpointIsNeverLabeledAsOfficialAPI() {
        var tool = ToolDefinition(name: "我的余额", provider: .httpJSON, http: .init(endpoint: "https://api.deepseek.com/user/balance"), brandID: "deepseek")
        XCTAssertTrue(tool.hasOfficialHTTPPreset)
        XCTAssertEqual(tool.connectionTitle(for: .httpJSON), "DeepSeek 官方 API")
        tool.http.endpoint = "https://example.com/balance"
        XCTAssertFalse(tool.hasOfficialHTTPPreset)
        XCTAssertEqual(tool.connectionTitle(for: .httpJSON), "自定义 JSON 接口")
    }
}
