import Foundation

/// 埋め込み器を持ち回る係。
///
/// **一度作ったら持ち続ける。** 降ろすのは意味の層を切ったときだけである。
///
/// 作り直すと 1 回あたり **583 ms**（語彙 127 ms ＋ バケット 1 本 456 ms、実測）。
/// 一方、握り続ける値段は安い。
///
/// | 置いた時間 | 足跡 | 実 RAM |
/// |---|---|---|
/// | 推論の直後 | 112 MB | 140 MB |
/// | 15 秒 | 112 MB | 25 MB |
/// | 3 分 | 112 MB | **17 MB** |
///
/// 数百 MB に見えるのは推論中の一時的な作業領域で、数秒で返る。
/// 落ち着けば写した重みのページが RAM から追い出され、**膨らまない**。
/// 見張る値打ちが無いので、時計で降ろすのはやめた。
///
/// 「本を全部閉じたら降ろす」も試したが、やめた。
/// **書棚こそ意味検索を打つ場所**で、本を閉じた後に引くと 583 ms 払うことになる。
///
/// 置いたままページが追い出されていても、引き直しは 25〜30 ms で済む。
/// **3.7 ms と 25 ms の差は人に分からないが、25 ms と 583 ms の差は分かる。**
/// だから温かさを保とうとはせず、握っておくことだけを考える。
///
/// なお以前「温めておけば 3.8 ms」と測ったが、あれは同じ埋め込み器で 2 回目を
/// 測っていた。アプリは毎回作り直していたので、温めは効いていなかった。
@available(macOS 15, *)
final class EmbedderHolder: @unchecked Sendable {
    static let shared = EmbedderHolder()

    private let gate = NSLock()
    private var embedder: CoreMLEmbedder?
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
            gate.unlock()
        }
        return try body(ready)
    }

    /// いま持っているかどうか。画面に出すためのものではなく、検査のため。
    var isHolding: Bool {
        gate.lock()
        defer { gate.unlock() }
        return embedder != nil
    }

    /// 降ろす。意味の層を切ったときに呼ぶ。
    func release() {
        gate.lock()
        if busy == 0 { embedder = nil }
        gate.unlock()
    }
}
