import Foundation
import IOKit.ps
import SwiftUI

/// 意味の索引を作る係。
///
/// **初回が重いことを前提に組む**（spec-local-ai.md 第 4.4 節）。
/// 1 冊で数十秒、蔵書 1,000 冊なら数時間かかる。だから
///
/// - 順番を付ける（いま開いた本 → 最近読んだ本 → 残り）
/// - 進み具合を見せ、途中でやめられる
/// - 残りは既定では電源に繋がっているときだけ進める
///
/// 二字組索引（`IndexBuilder`）と違って**黙って始めない**。
/// あちらは 1 冊 1 秒で済むが、こちらは電池と時間を目に見えて使う。
@MainActor
final class SemanticIndexBuilder: ObservableObject {
    static let shared = SemanticIndexBuilder()

    /// 意味の層を使うか。既定では入にしない。
    @AppStorage("semanticEnabled") var enabled = false { willSet { objectWillChange.send() } }
    /// 開いている本以外を進めるのは電源に繋がっているときだけにするか。
    @AppStorage("semanticOnPowerOnly") var onPowerOnly = true { willSet { objectWillChange.send() } }

    /// いま何をしているか。無ければ止まっている。
    @Published private(set) var working: Working?
    /// 直近に落ちた理由。画面に出すためのもの。
    @Published private(set) var failure: String?

    struct Working {
        var title: String
        var done: Int
        var total: Int

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// 待っている仕事。**電源の条件を仕事そのものに持たせる。**
    ///
    /// 以前は「`working` が空なら 1 冊目＝開いた本」と見なしていたが、
    /// `working` は画面に出すための状態である。中断の直後も 1 冊終えた直後も空なので、
    /// まとめて並べた 1 冊目まで電源の条件を素通りしていた。
    private struct Job {
        var url: URL
        /// 開いた本は、電源に繋がっていなくても作る。
        var ignoresPower: Bool
    }

    private var queue: [Job] = []
    private var running = false
    /// いま走っている仕事に「やめてくれ」と伝える目印。
    /// 裏の筋から同期で読めるようにしてあるので、節ごとに聞きに行かなくてよい。
    private var stopFlag = StopFlag()
    /// 何冊目の仕事か。遅れて届いた進み具合を捨てるために使う。
    private var generation = 0

    private init() {}

    // MARK: - 温める

    /// 短いバケットを裏で先に開いておく。
    ///
    /// バケットは 1 本開くのに数百 ms かかる（findings-buckets.md）。
    /// 裏で走る索引づくりには見えないが、**launch 後の最初の問いだけは表に出る**。
    /// 意味の層を入にした時点で開いておけば、待ち時間は 0 になる。
    private var warmed = false

    func warm() {
        guard enabled, !warmed, EmbeddingModelStore.installed() != nil else { return }
        warmed = true
        Task.detached(priority: .utility) {
            guard #available(macOS 15, *) else { return }
            // 短い問いを 1 回通す。これで問いが使うバケットが開く。
            // **持ち回る係を通す**（その場で作って捨てると、温めた先が残らない）。
            _ = try? EmbedderHolder.shared.use { try $0.embed("架空", as: .query) }
        }
    }

    // MARK: - 頼む

    /// 開いた本を先に作る。**割り込ませる。**
    /// 読んでいる本の関連箇所が出ないのが、いちばん困る。
    func prioritize(_ url: URL) {
        guard enabled, EmbeddingModelStore.installed() != nil else { return }
        guard !SemanticIndexStore.hasIndex(for: url) else { return }
        queue.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        queue.insert(Job(url: url, ignoresPower: true), at: 0)
        start()
    }

    /// 書棚が落ち着いたら、残りを作り始める。
    ///
    /// 二字組索引と同じ折で作る（spec-local-ai.md 第 4.4 節）。ただし
    /// **入にしていなければ何もしない**し、開いた本以外は電源に繋がっている
    /// ときだけ進む。「黙って始めない」という約束はそこで守られている。
    ///
    /// 書棚は開いたまま置かれることが多いので、少し待ってから始める。
    /// 開いた直後は表紙の読み込みなどが走っており、そこへ重ねない。
    func scheduleIdle(_ urls: [URL]) {
        guard enabled, EmbeddingModelStore.installed() != nil else { return }
        idleGeneration += 1
        let mine = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay) { [weak self] in
            // その間に書棚が動いたら、そちらの番に譲る。
            guard let self, self.idleGeneration == mine else { return }
            self.enqueue(urls)
        }
    }

    /// 書棚が開いてから、これだけ待つ。
    private static let idleDelay: TimeInterval = 8
    private var idleGeneration = 0

    /// 残りを順に作る。既に索引のあるものは並べない。
    func enqueue(_ urls: [URL]) {
        guard enabled, EmbeddingModelStore.installed() != nil else { return }
        let known = Set(queue.map(\.url.standardizedFileURL))
        for url in urls where !known.contains(url.standardizedFileURL) {
            guard !SemanticIndexStore.hasIndex(for: url) else { continue }
            queue.append(Job(url: url, ignoresPower: false))
        }
        start()
    }

    /// 途中でやめる。作りかけは置かない。
    func stop() {
        stopFlag.raise()
        queue.removeAll()
    }

    var pending: Int { queue.count }

    // MARK: - 進める

    private func start() {
        guard !running, !queue.isEmpty else { return }
        running = true
        stopFlag = StopFlag()
        step()
    }

    private func step() {
        guard !stopFlag.wanted, let job = queue.first else {
            running = false
            working = nil
            return
        }
        queue.removeFirst()

        if !job.ignoresPower, onPowerOnly, !onPower() {
            running = false
            working = nil
            return
        }

        let url = job.url
        let title = LibraryStore.shared.entry(for: BookID(url: url))?.displayTitle
            ?? url.deletingPathExtension().lastPathComponent
        generation += 1
        let mine = generation
        let stop = stopFlag
        working = Working(title: title, done: 0, total: 0)

        Task.detached(priority: .utility) {
            let result = Self.build(url, stop: stop, report: { done, total in
                // **毎段落は届けない。** 1 冊 600 段落ぶん流すと、見ている画面が
                // その回数だけ描き直される。人に見えるのは進み具合の帯なので、
                // 表示が動くところだけで足りる。
                guard Self.shouldReport(done: done, total: total) else { return }
                Task { @MainActor [weak self] in
                    // 遅れて届いた分で、次の本の進み具合を上書きしない。
                    guard let self, self.generation == mine else { return }
                    self.working = Working(title: title, done: done, total: total)
                }
            })
            await MainActor.run { [weak self] in
                guard let self else { return }
                if case let .failure(why) = result { self.failure = why }
                self.step()
            }
        }
    }

    /// 進み具合を届けるか。**1% 動いたときと、終わったときだけ。**
    ///
    /// 純粋な計算にしてあるのは、ここを検査で押さえるためである。
    /// 間引きすぎると帯が飛び飛びになり、間引かなければ画面が固まる。
    nonisolated static func shouldReport(done: Int, total: Int) -> Bool {
        guard total > 0 else { return true }
        if done >= total { return true }
        return done % max(1, total / 100) == 0
    }

    private enum Outcome {
        case done
        case failure(String)
    }

    /// UI を持たない筋で走る部分。
    ///
    /// `nonisolated` にしてあるのは、書籍を丸ごと読み、節ごとに推論を回す仕事だからである。
    private nonisolated static func build(_ url: URL,
                                          stop: StopFlag,
                                          report: @escaping (Int, Int) -> Void) -> Outcome {
        guard #available(macOS 15, *) else { return .done }
        guard let source = SearchIndexStore.open(url) else {
            return .failure("\(url.lastPathComponent) を開けませんでした")
        }
        do {
            _ = try EmbedderHolder.shared.use { embedder in
                try SemanticIndexStore.build(for: url, source: source, embedder: embedder,
                                             progress: { report($0.done, $0.total) },
                                             shouldStop: { stop.wanted })
            }
            return .done
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 中断の希望。**前の筋が上げ、裏の筋が読む。**
    ///
    /// 節ごとに MainActor へ聞きに行くと、待ち時間の方が仕事より高く付く。
    /// 1 つの目印を両方から触る形にして、閂だけ掛ける。
    final class StopFlag: @unchecked Sendable {
        private let gate = NSLock()
        private var value = false

        var wanted: Bool {
            gate.lock()
            defer { gate.unlock() }
            return value
        }

        func raise() {
            gate.lock()
            value = true
            gate.unlock()
        }
    }

    /// 電源に繋がっているか。
    private func onPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return true }   // 分からなければ止めない
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            if info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue { return true }
        }
        return sources.isEmpty   // 電池を持たない機械（据え置き）は繋がっている扱い
    }
}
