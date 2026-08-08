import Foundation

/// 埋め込み器を持ち回る係。
///
/// **作り直すと 1 回あたり約 600 ms かかる**（バケットを開き直すため。実測）。
/// 問いを引くたびに払うと体感に出る。かといって持ち続けると数百 MB が居座り、
/// 「モデルは使い終わったら降ろす」（spec-local-ai.md 第 4.5 節）に反する。
///
/// **使う間は持ち、しばらく使わなければ降ろす。**
///
/// 以前「温めておけば 3.8 ms」と測ったが、あれは同じ埋め込み器で 2 回目を
/// 測っていた。アプリは毎回作り直していたので、温めは効いていなかった。
@available(macOS 15, *)
final class EmbedderHolder: @unchecked Sendable {
    static let shared = EmbedderHolder()

    /// これだけ使われなければ降ろす。
    ///
    /// **握り続ける値段は安い。** 落ち着けば足跡 120 MB・実 RAM 25 MB ほどで、
    /// 推論中に見える数百 MB は 5 秒ほどで返る一時的な作業領域である（実測）。
    /// 一方、手放して作り直すと語彙 127 ms ＋ バケット 456 ms ＝ **583 ms** かかる。
    ///
    /// 置いたままでもページは追い出されるが、それでも引き直しは 25〜30 ms で済む。
    /// **3.7 ms と 25 ms の差は人に分からないが、25 ms と 583 ms の差は分かる。**
    /// だから温かさを保とうとはせず、握っておくことだけを考える。
    ///
    /// 本を全部閉じたときは待たずに降ろす（`DocumentRegistry.release`）。
    private static let idle: TimeInterval = 300

    private let gate = NSLock()
    private var embedder: CoreMLEmbedder?
    private var usedAt = Date.distantPast
    private var busy = 0

    private init() {}

    /// 持ち回っている埋め込み器で仕事をする。無ければ作る。
    ///
    /// **UI を持つスレッドから呼んではいけない。** 初回は開くのに数百 ms かかる。
    func use<T>(_ body: (CoreMLEmbedder) throws -> T) throws -> T? {
        guard let model = EmbeddingModelStore.installed() else { return nil }

        gate.lock()
        let ready: CoreMLEmbedder
        do {
            if let already = embedder {
                ready = already
            } else {
                ready = try CoreMLEmbedder(model: model)
                embedder = ready
            }
            busy += 1
            gate.unlock()
        } catch {
            gate.unlock()
            throw error
        }

        defer {
            gate.lock()
            busy -= 1
            usedAt = Date()
            gate.unlock()
            scheduleRelease()
        }
        return try body(ready)
    }

    /// いま持っているかどうか。画面に出すためのものではなく、検査のため。
    var isHolding: Bool {
        gate.lock()
        defer { gate.unlock() }
        return embedder != nil
    }

    /// すぐ降ろす。書籍を閉じたときなど、待たずに手放したいとき。
    func release() {
        gate.lock()
        if busy == 0 { embedder = nil }
        gate.unlock()
    }

    private func scheduleRelease() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idle + 1) { [weak self] in
            guard let self else { return }
            self.gate.lock()
            // まだ使っている、または間に使われたなら降ろさない。
            if self.busy == 0, Date().timeIntervalSince(self.usedAt) >= Self.idle {
                self.embedder = nil
            }
            self.gate.unlock()
        }
    }
}
