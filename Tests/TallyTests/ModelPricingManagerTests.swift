import XCTest
@testable import Tally

/// 包内的 pricing.json 得盖住 Claude Code / Codex 当前写进日志的模型 id：漏一个，那家整周的费用就少一截、面板挂着「+未定价」。
final class ModelPricingManagerTests: XCTestCase {

    /// 直接读仓库里的 Resources/pricing.json：测试进程的 Bundle.main 是 xctest，包里没有它。
    private func bundledManager() throws -> ModelPricingManager {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pricing.json")
        let data = try JSONDecoder().decode(ModelPricingData.self, from: Data(contentsOf: url))
        return ModelPricingManager(pricingData: data)
    }

    func testBundledTableCoversModelsAgentsCurrentlyLog() throws {
        let manager = try bundledManager()
        // Claude Code 写原生 id（带不带日期都有），Codex 写 turn_context 里的 model
        for id in ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5", "claude-opus-4-8",
                   "claude-haiku-4-5-20251001", "gpt-6-astra", "gpt-6-sol"] {
            XCTAssertNotNil(manager.getPricing(for: id), "\(id) 没定价")
        }
        let opus55 = try XCTUnwrap(manager.getPricing(for: "claude-opus-5-5"))
        XCTAssertEqual(opus55.prompt, 0.000004)
        XCTAssertEqual(opus55.completion, 0.00002)
        XCTAssertEqual(opus55.cacheRead, 0.0000002)
        XCTAssertEqual(opus55.cacheWrite, 0.000005)
        XCTAssertNil(manager.getPricing(for: "claude-zeta-9"), "没有的模型仍要是没定价，不能兜底成别的价")
    }

    func testOneMillionContextSuffixPricesAsTheSameModel() throws {
        let manager = try bundledManager()
        for base in ["claude-opus-5", "claude-fable-5-1", "claude-opus-5-5"] {
            let plain = try XCTUnwrap(manager.getPricing(for: base))
            let long = try XCTUnwrap(manager.getPricing(for: "\(base)[1m]"), "\(base)[1m] 没定价")
            XCTAssertEqual(long.prompt, plain.prompt)
            XCTAssertEqual(long.completion, plain.completion)
            XCTAssertEqual(long.cacheRead, plain.cacheRead)
            XCTAssertEqual(long.cacheWrite, plain.cacheWrite)
        }
        XCTAssertEqual(ModelPricingManager.pricingKeyCandidates(for: "claude-opus-5[1m]").first, "claude-opus-5")
    }
}
