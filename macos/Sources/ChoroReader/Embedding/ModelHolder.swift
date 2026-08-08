import Foundation

final class ModelHolder<Made: AnyObject>: @unchecked Sendable {
    private let gate = NSLock()
    private let make: () throws -> Made?
    private var held: Made?
    private var busy = 0

    init(make: @escaping () throws -> Made?) {
        self.make = make
    }

    /// 持ち回っているもので仕事をする。無ければ作る。
    ///
    /// **UI を持つスレッドから呼んではいけない。** 初回は開くのに数百 ms かかる。
    func use<T>(_ body: (Made) throws -> T) throws -> T? {
        gate.lock()
        let ready: Made
        do {
            if let already = held {
                ready = already
            } else {
                guard let fresh = try make() else {
                    gate.unlock()
                    return nil
                }
                held = fresh
                ready = fresh
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
        return held != nil
    }

    /// 降ろす。意味の層を切ったときに呼ぶ。
    func release() {
        gate.lock()
        if busy == 0 { held = nil }
        gate.unlock()
    }
}

/// 埋め込み器を持ち回る係。降ろすのは意味の層を切ったときだけである。
@available(macOS 15, *)
enum EmbedderHolder {
    static let shared = ModelHolder<CoreMLEmbedder> {
        guard let model = EmbeddingModelStore.installed() else { return nil }
        return try CoreMLEmbedder(model: model)
    }
}

/// 並べ直しの道具を持ち回る係。
///
/// **埋め込み器とは別に持つ。** 別のモデルで、別のバケットを開くためである。
/// 並べ直しは押されたときにしか走らないので、押されるまでは何も抱えない。
@available(macOS 15, *)
enum RerankerHolder {
    static let shared = ModelHolder<CrossEncoder> {
        guard let model = RerankerModelStore.installed() else { return nil }
        return try CrossEncoder(model: model)
    }
}
