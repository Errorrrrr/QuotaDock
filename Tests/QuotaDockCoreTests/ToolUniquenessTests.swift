import XCTest
@testable import QuotaDockCore

final class ToolUniquenessTests: XCTestCase {
    func testRenamedPresetAndDifferentReaderCannotCreateSecondTool() {
        let existing = ToolDefinition(name: "工作账号", provider: .antigravityCLI, brandID: "antigravity")
        let candidate = ToolDefinition(name: "Antigravity", provider: .antigravityDesktop, brandID: "antigravity")
        let config = AppConfiguration(tools: [existing])
        XCTAssertEqual(config.toolPreventingSave(candidate)?.id, existing.id)
        XCTAssertNil(config.toolPreventingSave(existing))
    }

    func testLegacyPresetWithoutBrandIsStillRecognized() {
        let existing = ToolDefinition(name: "旧名称", provider: .codexCLI)
        let candidate = ToolDefinition(name: "Codex", provider: .manual, brandID: "codex")
        XCTAssertEqual(AppConfiguration(tools: [existing]).toolPreventingSave(candidate)?.id, existing.id)
    }

    func testCustomNamesCannotBypassDuplicateGuard() {
        let existing = ToolDefinition(name: "My Tool")
        let config = AppConfiguration(tools: [existing])
        XCTAssertNotNil(config.toolPreventingSave(.init(name: " my TOOL ")))
        XCTAssertNil(config.toolPreventingSave(.init(name: "Another Tool")))
        XCTAssertFalse(ToolDefinition(name: "").representsSameTool(as: .init(name: " ")))
    }

    func testEditingLegacyDuplicatesRemainsPossibleButNewDuplicatesAreBlocked() {
        let first = ToolDefinition(name: "个人", provider: .codexCLI, brandID: "codex")
        var second = ToolDefinition(name: "工作", provider: .codexCLI, brandID: "codex")
        let config = AppConfiguration(tools: [first, second])
        second.name = "工作已改名"
        XCTAssertNil(config.toolPreventingSave(second))
        XCTAssertNotNil(config.toolPreventingSave(.init(name: "Codex", provider: .codexCLI)))
    }

    func testRenamingCustomToolIntoAnotherToolIsBlocked() {
        let first = ToolDefinition(name: "First")
        var second = ToolDefinition(name: "Second")
        let config = AppConfiguration(tools: [first, second])
        second.name = "First"
        XCTAssertEqual(config.toolPreventingSave(second)?.id, first.id)
    }
}
