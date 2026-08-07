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

    private var queue: [URL] = []
    private var running = false
    /// いま走っている仕事に「やめてくれ」と伝える目印。
    /// 裏の筋から同期で読めるようにしてあるので、節ごとに聞きに行かなくてよい。
    private var stopFlag = StopFlag()
    /// 何冊目の仕事か。遅れて届いた進み具合を捨てるために使う。
    private var generation = 0

    private init() {}

    // MARK: - 頼む

    /// 開いた本を先に作る。**割り込ませる。**
    /// 読んでいる本の関連箇所が出ないのが、いちばん困る。
    func prioritize(_ url: URL) {
        guard enabled, EmbeddingModelStore.installed() != nil else { return }
        guard !SemanticIndexStore.hasIndex(for: url) else { return }
        queue.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        queue.insert(url, at: 0)
        start()
    }

    /// 残りを順に作る。既に索引のあるものは並べない。
    func enqueue(_ urls: [URL]) {
        guard enabled, EmbeddingModelStore.installed() != nil else { return }
        let known = Set(queue.map(\.standardizedFileURL))
        for url in urls where !known.contains(url.standardizedFileURL) {
            guard !SemanticIndexStore.hasIndex(for: url) else { continue }
            queue.append(url)
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
        guard !stopFlag.wanted, let url = queue.first else {
            running = false
            working = nil
            return
        }
        queue.removeFirst()

        // 2 冊目からは電源の条件を見る。開いた本は繋がっていなくても作る。
        let isFirst = working == nil
        if !isFirst, onPowerOnly, !onPower() {
            running = false
            working = nil
            return
        }

        let title = LibraryStore.shared.entry(for: BookID(url: url))?.displayTitle
            ?? url.deletingPathExtension().lastPathComponent
        generation += 1
        let mine = generation
        let stop = stopFlag
        working = Working(title: title, done: 0, total: 0)

        Task.detached(priority: .utility) {
            let result = Self.build(url, stop: stop, report: { done, total in
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
        guard let model = EmbeddingModelStore.installed() else { return .done }
        guard let source = SearchIndexStore.open(url) else {
            return .failure("\(url.lastPathComponent) を開けませんでした")
        }
        do {
            let embedder = try CoreMLEmbedder(model: model)
            _ = try SemanticIndexStore.build(for: url, source: source, embedder: embedder,
                                             progress: { report($0.done, $0.total) },
                                             shouldStop: { stop.wanted })
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
