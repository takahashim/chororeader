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

/// 書棚が落ち着いたら作り始めるところ。
extension SemanticIndexBuilderTests {
    /// **入にしていなければ、書棚を開いても何も始まらない。**
    /// ここが崩れると、切っているつもりの人の機械で数時間ぶんの仕事が黙って走る。
    func test_入にしていなければ書棚でも始まらない() async throws {
        let urls = try (0 ..< 3).map { _ in try book() }
        builder.enabled = false
        builder.scheduleIdle(urls)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(builder.pending, 0, "入にしていないのに並べてしまった")
        XCTAssertNil(builder.working)
    }

    /// すぐには始めないこと。書棚を開いた直後は表紙の読み込みなどが走っている。
    func test_すぐには始めない() async throws {
        try XCTSkipUnless(EmbeddingModelStore.installed() != nil, "手元にモデルがありません")
        let urls = try (0 ..< 3).map { _ in try book() }
        builder.enabled = true
        builder.scheduleIdle(urls)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(builder.pending, 0, "待たずに始めている")
        builder.stop()
    }
}

/// 置いてあるものの版。
final class SemanticIndexStaleTests: XCTestCase {
    func test_無ければ版違いとは言わない() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("choro-none-\(UUID().uuidString).epub")
        XCTAssertNil(SemanticIndexStore.recordedModel(for: url))
        // **「無い」を「版違い」と言ってはいけない。** 作り直しを促す文言が出てしまう。
        XCTAssertFalse(SemanticIndexStore.isStale(for: url))
    }
}

/// 進み具合をどれだけ届けるか。
///
/// **書棚は索引作りを観測しない**ようにしたが、設定の画面は見ている。
/// 毎段落届けると 1 冊で 600 回描き直され、押した先から戻ることがあった。
/// 間引きすぎれば帯が飛び飛びになる。その両端を押さえる。
final class SemanticIndexBuilderReportTests: XCTestCase {
    /// **終わりは必ず届く。** 届かないと帯が 99% で止まる。
    func test_終わりは必ず届く() {
        XCTAssertTrue(SemanticIndexBuilder.shouldReport(done: 600, total: 600))
        XCTAssertTrue(SemanticIndexBuilder.shouldReport(done: 1, total: 1))
        XCTAssertTrue(SemanticIndexBuilder.shouldReport(done: 5, total: 0))
    }

    /// 1 冊ぶんで届く回数が、段落の数よりずっと少ないこと。
    func test_毎段落は届けない() {
        let total = 600
        let times = (0 ... total).filter { SemanticIndexBuilder.shouldReport(done: $0, total: total) }.count
        XCTAssertLessThan(times, total / 4, "間引けていない（\(times) 回）")
        XCTAssertGreaterThan(times, 20, "間引きすぎて帯が飛ぶ（\(times) 回）")
    }

    /// 段落の少ない本でも帯が動くこと。**割り算で 0 にならないこと。**
    func test_短い本でも動く() {
        for total in [1, 3, 17, 99] {
            let times = (0 ... total).filter { SemanticIndexBuilder.shouldReport(done: $0, total: total) }.count
            XCTAssertEqual(times, total + 1, "\(total) 段落の本で間引いている")
        }
    }
}
