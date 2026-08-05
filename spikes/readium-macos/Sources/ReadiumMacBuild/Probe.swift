import Foundation
import ReadiumShared
import ReadiumStreamer

// macOS ビルド可否の検証用。パース層の主要型を参照できるかだけを確認する。
enum Probe {
    static func types() -> [Any.Type] {
        [
            Publication.self,
            Locator.self,
            EPUBParser.self,
            AssetRetriever.self,
        ]
    }
}
