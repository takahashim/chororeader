import Foundation

/// `.mlpackage` を組み立てて置く。
///
/// ```text
/// <名前>.mlpackage/
///   Manifest.json
///   Data/com.apple.CoreML/model.mlmodel      ← Model（protobuf）。中に MIL Program
///   Data/com.apple.CoreML/weights/weight.bin ← 重み
/// ```
///
/// field の番号は kohagi の `proto/CoreMLModelSubset.proto`（coremltools から
/// そのまま持ってきたもの）から写した。
public enum ModelPackage {
    /// macOS 15 向け。**MIL の opset `CoreML8` と対になる。**
    static let specificationVersion = 9

    /// モデルが外へ見せる 1 つの入口／出口。
    ///
    /// プログラムの中の値とは別に持つ。**中の値は界面ではない。**
    struct Feature {
        var name: String
        var dataType: MILProgram.DataType
        var shape: [Int]
    }

    // MARK: - Manifest

    /// 2 つの識別子は中身を持たない。Core ML は `rootModelIdentifier` が
    /// 実在する項目を指していればよい。**同じモデルを 2 度作れば同じ bytes になる**
    /// よう、生成せずに固定してある（本物の束は毎回新しい UUID を持つ）。
    private static let modelID = "6B0C4B1A-1E7C-4B7E-9E3D-000000000001"
    private static let weightsID = "6B0C4B1A-1E7C-4B7E-9E3D-000000000002"

    private static var manifest: String {
        // 組み立てずに書き下す。鍵が 4 つだけで、参照とバイトで見比べるのに読みやすい。
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

    /// 関数を複数持つモデル（multi-function の束）。
    ///
    /// **上位の input／output ではなく、関数ごとに界面を書く。** そして
    /// どれを既定にするかを名指しする。
    static func model(program: Protowire,
                      functions: [(name: String, inputs: [Feature], outputs: [Feature])],
                      defaultFunction: String) -> Protowire {
        Protowire.message { model in
            // Model.specificationVersion = 1
            model.field(1, varint: UInt64(specificationVersion))
            // Model.description = 2
            model.field(2, message: Protowire.message { description in
                // ModelDescription.functions = 20
                for one in functions {
                    description.field(20, message: Protowire.message { function in
                        // FunctionDescription.name = 1、input = 2、output = 3
                        function.field(1, string: one.name)
                        for feature in one.inputs { function.field(2, message: featureMessage(feature)) }
                        for feature in one.outputs { function.field(3, message: featureMessage(feature)) }
                    })
                }
                // ModelDescription.defaultFunctionName = 21
                description.field(21, string: defaultFunction)
            })
            // Model.mlProgram = 502
            model.field(502, message: program)
        }
    }

    private static func featureMessage(_ feature: Feature) -> Protowire {
        Protowire.message { described in
            // FeatureDescription.name = 1、type = 3
            described.field(1, string: feature.name)
            described.field(3, message: Protowire.message { type in
                // FeatureType.multiArrayType = 5
                type.field(5, message: Protowire.message { array in
                    // ArrayFeatureType.shape = 1、dataType = 2
                    for size in feature.shape { array.field(1, varint: UInt64(size)) }
                    array.field(2, varint: arrayDataType(feature.dataType))
                })
            })
        }
    }

    /// `ArrayFeatureType.ArrayDataType`。**MIL の `DataType` とは別の番号である。**
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
