import XCTest
@testable import Minutes

final class EngineConfigurationTests: XCTestCase {
    func testLegacyDefaultsMigrateToPortableGGUFPaths() {
        let suite = "MinutesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("无法创建测试 defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/Users/junjian/GitHub/wang-junjian/qwenasr-studio/models/Qwen3-ASR-1.7B", forKey: "asrModelPath")
        defaults.set("/Users/junjian/.cache/huggingface/hub/models--mlx-community--Qwen3.5-4B-OptiQ-4bit", forKey: "llmModelPath")

        let configuration = EngineConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.asrModelPath, EngineConfiguration.defaultASRModelPath())
        XCTAssertEqual(configuration.llmModelPath, EngineConfiguration.defaultLLMModelPath())
        XCTAssertTrue(configuration.asrModelPath.hasSuffix(".gguf"))
        XCTAssertFalse(configuration.asrModelPath.contains("qwenasr-studio"))
    }

    func testCustomPathsAndPromptArePreserved() {
        let suite = "MinutesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("无法创建测试 defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/custom/asr.gguf", forKey: "asrModelPath")
        defaults.set("/custom/llm.gguf", forKey: "llmModelPath")
        defaults.set("custom prompt", forKey: "minutesPrompt")

        let configuration = EngineConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.asrModelPath, "/custom/asr.gguf")
        XCTAssertEqual(configuration.llmModelPath, "/custom/llm.gguf")
        XCTAssertEqual(configuration.minutesPrompt, "custom prompt")
    }

    func testEmptyDefaultsDoNotFreezeEnvironmentDrivenModelRoot() {
        let suite = "MinutesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("无法创建测试 defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        unsetenv("MINUTES_MODELS_ROOT")
        let configuration = EngineConfiguration(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "asrModelPath"))
        XCTAssertNil(defaults.string(forKey: "llmModelPath"))

        setenv("MINUTES_MODELS_ROOT", "/Volumes/Models", 1)
        defer { unsetenv("MINUTES_MODELS_ROOT") }
        XCTAssertEqual(configuration.asrModelPath, "/Volumes/Models/Qwen3-ASR-1.7B-GGUF/qwen3-asr-1.7b-q8_0.gguf")
        XCTAssertEqual(configuration.llmModelPath, "/Volumes/Models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
    }

    func testASRServerConfigurationUsesMetalAndOfflineModel() throws {
        let suite = "MinutesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("无法创建测试 defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = NSTemporaryDirectory().appending("MinutesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let configuration = EngineConfiguration(defaults: defaults)
        configuration.engineRoot = root
        configuration.asrModelPath = "/tmp/custom-asr.gguf"
        configuration.setPort(9876, for: .asr)
        let url = try ASRServerConfiguration.write(configuration: configuration)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["backend"] as? String, "metal")
        XCTAssertEqual(object?["port"] as? Int, 9876)
        XCTAssertEqual(object?["lazy_load"] as? Bool, false)
        let model = (object?["models"] as? [[String: Any]])?.first
        XCTAssertEqual(model?["id"] as? String, "minutes-asr")
        XCTAssertEqual(model?["path"] as? String, "/tmp/custom-asr.gguf")
        XCTAssertEqual(model?["mode"] as? String, "offline")
    }
}
