import XCTest
@testable import ChoroReader

/// 埋め込み器の持ち回り。
///
/// **効いていなくても症状は出ない。** 答えは同じで、ただ 1 回ごとに
/// 600 ms 余計にかかるだけである。実際、以前は温めたそばから捨てていて、
/// 検索のたびに払っていた（同じ器で 2 回目を測っていたので気付けなかった）。
@available(macOS 15, *)
final class EmbedderHolderTests: XCTestCase {
    func test_持ち回った器が使われる() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil, "手元にモデルがありません")
        EmbedderHolder.shared.release()

        // 1 度使えば持つ
        _ = try EmbedderHolder.shared.use { try $0.embed("架空の一節である。", as: .query) }
        XCTAssertTrue(EmbedderHolder.shared.isHolding, "使った後も持っていない")

        // 2 度目は開き直さない。作り直すと 600 ms かかるので、桁で分かる。
        let began = Date()
        _ = try EmbedderHolder.shared.use { try $0.embed("別の一節である。", as: .query) }
        let each = Date().timeIntervalSince(began) * 1000
        XCTAssertLessThan(each, 100, "開き直している（\(Int(each)) ms）")
    }

    /// 手放せること。書籍を閉じたときなど、待たずに降ろしたい場面がある。
    func test_手放せる() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil, "手元にモデルがありません")
        _ = try EmbedderHolder.shared.use { try $0.embed("架空の一節である。", as: .query) }
        EmbedderHolder.shared.release()
        XCTAssertFalse(EmbedderHolder.shared.isHolding, "手放せていない")
    }

    /// 使っている最中は手放さないこと。**手放すと、使っている側の足元が崩れる。**
    func test_使っている最中は手放さない() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil, "手元にモデルがありません")
        EmbedderHolder.shared.release()
        _ = try EmbedderHolder.shared.use { embedder in
            EmbedderHolder.shared.release()
            XCTAssertTrue(EmbedderHolder.shared.isHolding, "使っている最中に手放した")
            return try embedder.embed("架空の一節である。", as: .query)
        }
    }

    /// 複数の筋から同時に使えること。索引作りは裏、問いは前で走る。
    func test_複数の筋から同時に使える() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil, "手元にモデルがありません")
        let failures = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: 16) { at in
            do {
                let made = try EmbedderHolder.shared.use {
                    try $0.embed("架空の一節である。番号は \(at)。", as: .document)
                }
                if made?.vector.isEmpty ?? true { failures.add("空のベクトル") }
            } catch {
                failures.add("\(error)")
            }
        }
        XCTAssertEqual(failures.count, 0, "同時に使うと壊れる：\(failures)")
    }
}
