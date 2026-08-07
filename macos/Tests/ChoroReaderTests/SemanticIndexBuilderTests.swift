import XCTest
@testable import ChoroReader

/// 索引を作る係の振る舞い。
///
/// **いちばん怖いのは、入にしていないのに走り出すことである。**
/// 1 冊で数十秒、蔵書ぶんで数時間かかる仕事なので、
/// 黙って始まると電池と発熱で気付かれる。
@MainActor
final class SemanticIndexBuilderTests: XCTestCase {
    private var builder: SemanticIndexBuilder { .shared }

    override func setUp() async throws {
        builder.stop()
        builder.enabled = false
    }

    override func tearDown() async throws {
        builder.stop()
        builder.enabled = false
    }

    private func book() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("book.epub")
        try Data("架空".utf8).write(to: url)   // 中身は問わない。並べるかどうかだけを見る
        return url
    }

    func test_入にしていなければ並べない() throws {
        let url = try book()
        builder.enabled = false
        builder.prioritize(url)
        builder.enqueue([url])
        XCTAssertEqual(builder.pending, 0, "入にしていないのに並べてしまった")
        XCTAssertNil(builder.working)
    }

    func test_入にすれば並ぶ() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil,
                          "手元にモデルがありません")
        let urls = try (0 ..< 3).map { _ in try book() }
        builder.enabled = true
        builder.enqueue(urls)
        // 1 冊目は取り出されて走り出すので、待っているのは残り
        XCTAssertGreaterThanOrEqual(builder.pending, 1)
        builder.stop()
        XCTAssertEqual(builder.pending, 0, "やめたのに並んだまま")
    }

    /// 開いた本は割り込む。読んでいる本の関連箇所が出ないのがいちばん困る。
    func test_開いた本が先に来る() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil,
                          "手元にモデルがありません")
        let others = try (0 ..< 3).map { _ in try book() }
        let opened = try book()
        builder.enabled = true
        builder.enqueue(others)
        let before = builder.pending
        builder.prioritize(opened)
        // 割り込んだぶんだけ増える（1 冊目は走っているので数に入らない）
        XCTAssertEqual(builder.pending, before + 1)
        builder.stop()
    }

    /// モデルが手元に無ければ、入にしていても並べない。
    /// **並べてしまうと、開くたびに落ちて理由だけが溜まる。**
    func test_モデルが無ければ並べない() throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() == nil,
                          "手元にモデルがあるので、この筋は確かめられません")
        let url = try book()
        builder.enabled = true
        builder.prioritize(url)
        XCTAssertEqual(builder.pending, 0)
    }
}

/// 中断の目印。前の筋が上げ、裏の筋が読む。
final class SemanticStopFlagTests: XCTestCase {
    func test_上げるまでは伏せている() {
        let flag = SemanticIndexBuilder.StopFlag()
        XCTAssertFalse(flag.wanted)
        flag.raise()
        XCTAssertTrue(flag.wanted)
    }

    /// 複数の筋から触れること。閂が無いと壊れる形である。
    func test_複数の筋から触れる() {
        let flag = SemanticIndexBuilder.StopFlag()
        let done = expectation(description: "全部返る")
        done.expectedFulfillmentCount = 64
        for at in 0 ..< 64 {
            DispatchQueue.global().async {
                if at == 32 { flag.raise() } else { _ = flag.wanted }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(flag.wanted)
    }
}
