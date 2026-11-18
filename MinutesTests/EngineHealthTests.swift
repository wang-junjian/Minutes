import XCTest
@testable import Minutes

final class EngineHealthTests: XCTestCase {
    private let asrPath = "/tmp/asr.gguf"
    private let llmPath = "/tmp/llm.gguf"

    func testOldPythonHealthIsRejected() {
        let old = ["status": "ok", "worker": "llm", "model_loaded": true] as [String: Any]
        let status = EngineHealth.validateLLM(health: old, props: [:], expectedModelPath: llmPath)
        guard case .incompatible = status else { return XCTFail("旧服务不应通过身份检查") }
    }

    func testLLMReadyRequiresMatchingModel() {
        let health = ["status": "ok"]
        let props = ["build_info": "b123-test", "model_path": llmPath]
        XCTAssertEqual(EngineHealth.validateLLM(health: health, props: props, expectedModelPath: llmPath),
                       .ready(detail: "llama.cpp b123-test"))
        guard case .incompatible = EngineHealth.validateLLM(
            health: health, props: props, expectedModelPath: "/tmp/other.gguf"
        ) else { return XCTFail("模型路径不匹配") }
    }

    func testASRLoadingAndReady() {
        let health = ["status": "ok", "backend": "metal", "version": "dev", "git": "6f71a3b"]
        let model: [String: Any] = [
            "id": "minutes-asr", "family": "qwen3_asr", "configured": true,
            "loaded": false, "path": asrPath,
        ]
        XCTAssertEqual(EngineHealth.validateASR(health: health, models: ["data": [model]], expectedModelPath: asrPath), .starting)
        var loaded = model
        loaded["loaded"] = true
        XCTAssertEqual(EngineHealth.validateASR(health: health, models: ["data": [loaded]], expectedModelPath: asrPath),
                       .ready(detail: "audio.cpp 6f71a3b"))
        XCTAssertEqual(EngineHealth.validateASR(health: health.merging(["git": ""]) { _, new in new }, models: ["data": [loaded]], expectedModelPath: asrPath),
                       .ready(detail: "audio.cpp dev"))
    }
}
