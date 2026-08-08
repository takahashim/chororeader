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
    private static let idle: TimeInterval = 60

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
