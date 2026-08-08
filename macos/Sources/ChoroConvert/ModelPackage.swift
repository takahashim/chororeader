import Foundation

public enum ModelPackage {
    static let specificationVersion = 9

    struct Feature {
        var name: String
        var dataType: MILProgram.DataType
        var shape: [Int]
    }

    // MARK: - Manifest

    private static let modelID = "6B0C4B1A-1E7C-4B7E-9E3D-000000000001"
    private static let weightsID = "6B0C4B1A-1E7C-4B7E-9E3D-000000000002"

    private static var manifest: String {
        """
        {
            "fileFormatVersion": "1.0.0",
            "itemInfoEntries": {
                "\(weightsID)": {
                    "author": "com.apple.CoreML",
                    "description": "CoreML Model Weights",
                    "name": "weights",
                    "path": "com.apple.CoreML/weights"
                },
                "\(modelID)": {
                    "author": "com.apple.CoreML",
                    "description": "CoreML Model Specification",
                    "name": "model.mlmodel",
                    "path": "com.apple.CoreML/model.mlmodel"
                }
            },
            "rootModelIdentifier": "\(modelID)"
        }

        """
    }

    // MARK: - Model

    static func model(program: Protowire,
                      functions: [(name: String, inputs: [Feature], outputs: [Feature])],
                      defaultFunction: String) -> Protowire {
        Protowire.message { model in
            model.field(1, varint: UInt64(specificationVersion))
            model.field(2, message: Protowire.message { description in
                for one in functions {
                    description.field(20, message: Protowire.message { function in
                        function.field(1, string: one.name)
                        for feature in one.inputs { function.field(2, message: featureMessage(feature)) }
                        for feature in one.outputs { function.field(3, message: featureMessage(feature)) }
                    })
                }
                description.field(21, string: defaultFunction)
            })
            model.field(502, message: program)
        }
    }

    private static func featureMessage(_ feature: Feature) -> Protowire {
        Protowire.message { described in
            described.field(1, string: feature.name)
            described.field(3, message: Protowire.message { type in
                type.field(5, message: Protowire.message { array in
                    for size in feature.shape { array.field(1, varint: UInt64(size)) }
                    array.field(2, varint: arrayDataType(feature.dataType))
                })
            })
        }
    }

    private static func arrayDataType(_ type: MILProgram.DataType) -> UInt64 {
        switch type {
        case .fp16: return 65552
        case .fp32: return 65568
        case .int32: return 131104
        default: return 0
        }
    }

    // MARK: - 置く

    /// `.mlpackage` を置く。既にあれば置き換える。
    ///
    /// **重みが空でもファイルは書く。** manifest が指す置き場所が無いと、
    /// Core ML の組み立てが落ちる。
    public static func write(_ model: ModelBytes, weights: Data, to url: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        let data = url.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        try manager.createDirectory(at: data.appendingPathComponent("weights", isDirectory: true),
                                    withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: url.appendingPathComponent("Manifest.json"))
        try model.data.write(to: data.appendingPathComponent("model.mlmodel"))
        try weights.write(to: data.appendingPathComponent("weights/weight.bin"))
    }
}

/// 書き出した `Model` の中身。**外へは bytes としてだけ見せる。**
///
/// protobuf の組み立て（`Protowire`）は変換器の内側の都合であり、
/// 使う側が触るものではない。
public struct ModelBytes {
    public let data: Data

    init(_ wire: Protowire) { data = wire.data }
}

/// 束が何の頭を持つかを、そばに書き添える。
///
/// 埋め込みは `1_Pooling/config.json` を持つが、reranker は持たない。
/// **無いことで見分けるのは弱い**（写し忘れと区別が付かない）ので、
/// 印を 1 つ置く。
public enum HeadMarker {
    public static let name = "choro-head.json"

    public static func write(classifier: Bool, to directory: URL) throws {
        let head = classifier ? "classifier" : "embedding"
        let text = """
        {
          "head": "\(head)"
        }

        """
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }
}
