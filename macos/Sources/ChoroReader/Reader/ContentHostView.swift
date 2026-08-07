import AppKit

/// 本文を載せる器。覆われているあいだは中身を捨て、現れたら組み直す。
///
/// WKWebView は 1 つで 34 メガほどと、WebContent プロセスを 1 つ持つ。
/// 書籍を並べて読むのがこのアプリの芯なので（spec 第 4 章）、窓の数は減らせない。
/// 代わりに、**その瞬間に見られていない窓**の中身を手放す。
///
/// 落とすのは完全に覆われた窓だけである。
/// 見えているが非アクティブな窓は落とさない。並べて比べているのがまさにその状態で、
/// そこを落とすと比較そのものが成り立たなくなる。
///
/// 猶予を長く取る。実測では、寝かせて取り戻せるのは 1 窓あたり 12 メガほど（3 割）で、
/// 起こすと畳まれ待ちの WebContent プロセスと新しいものが並ぶ時間ができる
/// （6 窓のうち 5 つを寝かせて起こすと、プロセスは 6 個から 11 個になった）。
/// 行き来のたびに寝かせると差し引きで損をするので、**本当に離れた窓**だけを対象にする。
///
/// `WKProcessPool` を 1 つにして畳んだプロセスを使い回させる手も測ったが、
/// 起こしたときのプロセス数は変わらなかった。効かないので入れていない。
///
/// 画面へ渡すのはこの器にする。中の WKWebView は入れ替わるが、器は変わらない。
/// SwiftUI は器の同一性だけ見ていればよい。
@MainActor
final class ContentHostView: NSView {
    /// 中身を作る／捨てる相手。器は寿命を持たない。
    weak var sleeper: (any ContentSleeper)?

    /// 覆われてから手放すまでの猶予。3 分。
    ///
    /// 短くすると、窓を行き来するたびに寝て起きて、差し引きで損をする。
    /// 本当に離れた窓だけを対象にしたいので長く取る。
    static var grace: TimeInterval = 180

    private var pending: DispatchWorkItem?
    private var watching: NSObjectProtocol?

    override var isFlipped: Bool { true }

    /// 中身を入れ替える。器いっぱいに広げる。
    func hold(_ view: NSView?) {
        subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let watching {
            NotificationCenter.default.removeObserver(watching)
            self.watching = nil
        }
        cancelPending()
        guard let window else { return }

        watching = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
        occlusionChanged()
    }

    private func occlusionChanged() {
        guard let window else { return }
        if window.occlusionState.contains(.visible) {
            cancelPending()
            sleeper?.wakeContent()
        } else {
            scheduleSleep()
        }
    }

    private func scheduleSleep() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                // 猶予のあいだに現れていたら、そのままにする。
                guard self.window?.occlusionState.contains(.visible) != true else { return }
                self.sleeper?.sleepContent()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    deinit {
        if let watching { NotificationCenter.default.removeObserver(watching) }
    }
}

/// 覆われているあいだ中身を手放せるもの。
@MainActor
protocol ContentSleeper: AnyObject {
    /// 中身を捨てる。いまの位置は覚えておく。
    func sleepContent()
    /// 中身を組み直し、覚えていた位置へ戻す。起きていれば何もしない。
    func wakeContent()
    /// いま寝ているか。
    var isAsleep: Bool { get }
}
