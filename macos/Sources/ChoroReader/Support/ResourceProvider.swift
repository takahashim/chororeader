import Foundation

/// 本文とその周辺リソースの供給元。
/// 供給できる範囲をこの型が決めることで、スキームハンドラは出所を意識せずに済む。
protocol ResourceProvider: AnyObject {
    func contains(_ path: String) -> Bool
    func read(_ path: String) throws -> Data
}

extension ZipArchive: ResourceProvider {}
