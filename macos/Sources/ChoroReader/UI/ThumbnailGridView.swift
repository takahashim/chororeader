import AppKit
import SwiftUI

struct ThumbnailGridView: View {
    @ObservedObject var session: ReaderSession
    let provider: ThumbnailProvider

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 12)]

    private var currentPage: Int {
        session.fixed?.currentPage ?? session.locator.page ?? 0
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0 ..< provider.pageCount, id: \.self) { index in
                        ThumbnailCell(provider: provider,
                                      index: index,
                                      isCurrent: index == currentPage) {
                            open(page: index, newWindow: NSEvent.modifierFlags.contains(.command))
                        }
                        .id(index)
                        .contextMenu {
                            Button("新しいウィンドウで開く") { open(page: index, newWindow: true) }
                        }
                    }
                }
                .padding(10)
            }
            .onAppear { scroller.scrollTo(currentPage, anchor: .center) }
        }
    }

    private func open(page: Int, newWindow: Bool) {
        let locator = Locator(href: session.document.publication?.readingOrder[safe: page]?.href,
                              page: page,
                              progression: 0,
                              title: "\(page + 1) ページ")
        if newWindow {
            session.openInNewWindow(locator)
        } else {
            session.go(to: locator)
        }
    }
}

private struct ThumbnailCell: View {
    let provider: ThumbnailProvider
    let index: Int
    let isCurrent: Bool
    let action: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25),
                                      lineWidth: isCurrent ? 2.5 : 0.5)
                }
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            guard image == nil else { return }
            if let hit = provider.cached(at: index) {
                image = hit
                return
            }
            await withCheckedContinuation { continuation in
                provider.thumbnail(at: index, maxPixel: 320) { made in
                    image = made
                    continuation.resume()
                }
            }
        }
    }
}
