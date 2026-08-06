# frozen_string_literal: true

require "json"
require "open3"

# 各実装のプローブを呼び出す薄い層。実装が増えてもここだけで吸収する。
class Probe
  class Failure < StandardError; end

  attr_reader :name, :command

  def initialize(name, command)
    @name = name
    @command = command
  end

  # conformance/probes.json に実装の起動方法を書く。
  def self.load_all(path, root: Runner::ROOT)
    return {} unless File.exist?(path)

    JSON.parse(File.read(path)).map do |name, argv|
      [name, new(name, resolve_paths(Array(argv), root))]
    end.to_h
  end

  # パスはリポジトリの根から解いた形にする。
  # tzconf をどこから起動しても同じ場所を指すようにするため。
  # 区切りを含まない要素は PATH から探すものとみなして触らない。
  def self.resolve_paths(argv, root)
    argv.map do |arg|
      next arg unless arg.include?("/")
      next arg if arg.start_with?("/")

      File.join(root, arg)
    end
  end

  # macOS 実装は macos/ の下に置く。実装ごとにディレクトリを分けているため。
  def self.default_swift(root)
    candidates = [
      File.join(root, "macos", "build", "TZReader.app", "Contents", "MacOS", "TZReader"),
      File.join(root, "macos", ".build", "release", "TZReader"),
      File.join(root, "macos", ".build", "debug", "TZReader"),
    ]
    exe = candidates.find { |path| File.exist?(path) }
    exe ? new("swift", [exe]) : nil
  end

  def available?
    File.exist?(command.first) || system("which", command.first, out: File::NULL, err: File::NULL)
  end

  def call(*args, stdin: nil)
    argv = command + ["probe"] + args.map(&:to_s)
    out, err, status = Open3.capture3(*argv, stdin_data: stdin || "")
    unless status.success?
      raise Failure, "#{name}: #{argv.join(' ')} が終了コード #{status.exitstatus} で失敗しました\n#{err}"
    end

    begin
      JSON.parse(out)
    rescue JSON::ParserError => e
      raise Failure, "#{name}: JSON として読めない出力です (#{e.message})\n#{out[0, 400]}"
    end
  end
end
