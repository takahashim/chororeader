import Foundation

/// フォルダの中から書籍を探す。
///
/// 画面にもファイルの中身にも触らない。見つけた道筋を返すだけなので、検査で固められる。
enum BookFinder {
    /// 書籍として扱う拡張子。開くダイアログ（FileOpener）と揃える。
    static let extensions: Set<String> = ["epub", "pdf"]

    /// 潜る深さの上限。
    ///
    /// 蔵書は「出版社ごと」「年ごと」くらいの入れ子で置かれることが多い。
    /// 際限なく潜ると、書籍と関係ない木（Xcode の生成物や node_modules）まで舐める。
    static let maxDepth = 5

    /// `folder` の下にある書籍。見つかった順ではなく、道筋の順に並べて返す。
    ///
    /// 並びを決めておくのは、取り込みの進み方が毎回同じになるようにするためである。
    static func books(in folder: URL, maxDepth: Int = BookFinder.maxDepth) -> [URL] {
        var found: [URL] = []
        walk(folder, depth: 0, limit: maxDepth, into: &found)
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func walk(_ folder: URL, depth: Int, limit: Int, into found: inout [URL]) {
        guard depth <= limit else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true { continue }

            // EPUB は中身が ZIP なので束（package）にはならないが、
            // 束として扱われるフォルダ（.app など）の中は見ない。
            if values?.isDirectory == true {
                if values?.isPackage == true { continue }
                walk(entry, depth: depth + 1, limit: limit, into: &found)
                continue
            }
            if extensions.contains(entry.pathExtension.lowercased()) {
                found.append(entry)
            }
        }
    }
}
