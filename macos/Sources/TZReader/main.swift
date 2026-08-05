import Foundation

// `TZReader probe ...` で起動されたときは GUI を立ち上げず、検証用 CLI として動く。
// Windows 実装と振る舞いを突き合わせるための入り口（conformance/CONTRACT.md）。
if ProbeCLI.shouldRun(CommandLine.arguments) {
    ProbeCLI.run(Array(CommandLine.arguments.dropFirst()))
} else {
    TZReaderApp.main()
}
