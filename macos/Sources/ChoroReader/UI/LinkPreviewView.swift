import SwiftUI
import WebKit

/// リンク先を、本文の位置を動かさずに確かめるためのポップオーバー。
/// 数秒で済む確認はここで終え、読み比べたくなったら別ウィンドウへ送る。
struct LinkPreviewView: View {
    @ObservedObject var controller: WebNavigatorController
    let request: PreviewRequest
    @ObservedObject var session: ReaderSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            PreviewWebView(webView: controller.previewView)
                .frame(width: 420, height: request.isFootnote ? 150 : 260)
            Divider()
            footer
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: request.isFootnote ? "text.quote" : "doc.text")
                .foregroundStyle(.secondary)
            Text(request.target.title ?? (request.isFootnote ? "脚注" : "リンク先"))
                .font(.callout.bold())
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("ここへ移動") {
                controller.dismissPreview()
                session.go(to: request.target)
            }
            Button("新しいウィンドウで開く") {
                controller.dismissPreview()
                session.openInNewWindow(request.target)
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct PreviewWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
