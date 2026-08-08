import XCTest
@testable import ChoroConvert

/// 材料の取得と、変換物のそばへの写し。
///
/// **取ってくる方は検査しない**（網に触るため）。ここで見るのは、
/// 手元のものを指したときの筋と、写しの正しさである。
final class HubFetchTests: XCTestCase {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-hub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 直に指したものが勝つこと。
    func test_直に指したものを使う() throws {
        let root = try sandbox()
        let weights = root.appendingPathComponent("別の名前.safetensors")
        let config = root.appendingPathComponent("別の設定.json")
        try Data("x".utf8).write(to: weights)
        try Data("{}".utf8).write(to: config)

        let materials = HubFetch.local(weights: weights, config: config)
        XCTAssertEqual(materials.weights, weights, "指したものが使われていない")
        XCTAssertEqual(materials.config, config)
    }

    /// そばにあるものを拾って写すこと。
    func test_そばのものを写す() throws {
        let root = try sandbox()
        try Data("x".utf8).write(to: root.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("1_Pooling"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("1_Pooling/config.json"))

        let output = try sandbox()
        try HubFetch.place(HubFetch.local(weights: root.appendingPathComponent("model.safetensors"),
                                          config: root.appendingPathComponent("config.json")),
                           beside: output)
        for name in ["config.json", "tokenizer.json", "1_Pooling/config.json"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: output.appendingPathComponent(name).path), "\(name) が写っていない")
        }
        // 重みは写さない（変換物の中に入っている）
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("model.safetensors").path),
            "重みまで写している（260 MB が二重になる）")
    }

    /// **符号の連なりは解いて写す。** Hugging Face の置き場所は実体を
    /// blobs/ に置いて snapshots/ から指す作りで、そのまま写すと壊れた繋がりが残る。
    func test_符号の連なりを解いて写す() throws {
        let root = try sandbox()
        let real = root.appendingPathComponent("実体.json")
        try Data("{\"a\":1}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("config.json"), withDestinationURL: real)
        try Data("x".utf8).write(to: root.appendingPathComponent("model.safetensors"))

        let output = try sandbox()
        try HubFetch.place(HubFetch.local(weights: root.appendingPathComponent("model.safetensors"),
                                          config: root.appendingPathComponent("config.json")),
                           beside: output)
        let copied = output.appendingPathComponent("config.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: copied.path)
        XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink,
                          "符号の連なりのまま写している")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "{\"a\":1}")
    }

    /// 頭の印を置くこと。**無いことで見分けるのは弱い**（写し忘れと区別が付かない）。
    func test_頭の印を置く() throws {
        let root = try sandbox()
        try HeadMarker.write(classifier: true, to: root)
        let text = try String(contentsOf: root.appendingPathComponent(HeadMarker.name),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("classifier"))

        try HeadMarker.write(classifier: false, to: root)
        let other = try String(contentsOf: root.appendingPathComponent(HeadMarker.name),
                               encoding: .utf8)
        XCTAssertTrue(other.contains("embedding"))
    }
}
