# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "probe"
require_relative "cases"
require_relative "fixtures"

# 実装の出力を、凍結した期待値または別実装の出力と突き合わせる。
class Runner
  ROOT = File.expand_path("../..", __dir__)
  FIXTURE_DIR = File.join(ROOT, "conformance", "fixtures")
  EXPECTED_DIR = File.join(ROOT, "conformance", "expected")

  def initialize(out: $stdout)
    @out = out
  end

  # --- フィクスチャ生成 ---

  def generate_fixtures
    names = Fixtures.build_all(FIXTURE_DIR)
    @out.puts "フィクスチャ #{names.size} 件を生成しました: #{FIXTURE_DIR}"
    names
  end

  # --- 期待値の記録 ---

  def record(probe)
    FileUtils.mkdir_p(EXPECTED_DIR)
    count = 0
    each_case do |kase|
      result = invoke(probe, kase)
      File.write(expected_path(kase[:id]), JSON.pretty_generate(result) + "\n")
      count += 1
    end
    @out.puts "#{probe.name} の出力から期待値 #{count} 件を記録しました: #{EXPECTED_DIR}"
    @out.puts "内容を目で確かめてから凍結してください。片方の誤りがそのまま仕様になります。"
    count
  end

  # --- 期待値との照合 ---

  def conformance(probe)
    failures = []
    total = 0
    each_case do |kase|
      total += 1
      path = expected_path(kase[:id])
      unless File.exist?(path)
        failures << [kase[:id], "期待値がありません（record で作成してください）"]
        next
      end
      expected = JSON.parse(File.read(path))
      actual = invoke(probe, kase)
      diff = compare(expected, actual)
      failures << [kase[:id], diff] unless diff.empty?
    end
    report(probe.name, total, failures)
  end

  # --- 実装どうしの突き合わせ ---

  def diff(probe_a, probe_b, book: nil)
    failures = []
    total = 0
    cases = book ? book_cases(book) : all_cases
    cases.each do |kase|
      total += 1
      a = invoke(probe_a, kase)
      b = invoke(probe_b, kase)
      d = compare(a, b)
      failures << [kase[:id], d] unless d.empty?
    end
    report("#{probe_a.name} ↔ #{probe_b.name}", total, failures)
  end

  # 構造の差を、場所が分かる形で列挙する。
  # 比較器が壊れると全件が通ってしまうため、ここは test/runner_test.rb で守る。
  def compare(expected, actual, path = "")
    case expected
    when Hash
      return ["#{path}: 型が違います（期待 Hash, 実際 #{actual.class}）"] unless actual.is_a?(Hash)

      (expected.keys | actual.keys).sort.flat_map do |key|
        child = path.empty? ? key : "#{path}.#{key}"
        if !expected.key?(key) then ["#{child}: 期待値に無いキーが増えています（#{actual[key].inspect}）"]
        elsif !actual.key?(key) then ["#{child}: キーがありません"]
        else compare(expected[key], actual[key], child)
        end
      end
    when Array
      return ["#{path}: 型が違います（期待 Array, 実際 #{actual.class}）"] unless actual.is_a?(Array)

      if expected.size != actual.size
        ["#{path}: 要素数が違います（期待 #{expected.size}, 実際 #{actual.size}）"]
      else
        expected.each_with_index.flat_map { |e, i| compare(e, actual[i], "#{path}[#{i}]") }
      end
    else
      expected == actual ? [] : ["#{path}: 期待 #{expected.inspect} / 実際 #{actual.inspect}"]
    end
  end

  private

  def each_case(&block)
    all_cases.each(&block)
  end

  def all_cases
    fixtures = Dir[File.join(FIXTURE_DIR, "*.epub")].sort
    list = Cases.global
    fixtures.each do |path|
      name = File.basename(path, ".epub")
      Cases.for_fixture(name).each do |kase|
        list << kase.merge(fixture: path)
      end
    end
    list
  end

  # 手元の実書籍に対する突き合わせ。期待値は持たず、2 実装の出力差だけを見る。
  def book_cases(path)
    [
      { id: "parse/#{File.basename(path)}", args: ["parse", :fixture], fixture: path },
      { id: "report/#{File.basename(path)}", args: ["report", :fixture], fixture: path },
      { id: "detect/#{File.basename(path)}", args: ["detect", :fixture], fixture: path },
    ]
  end

  def invoke(probe, kase)
    args = kase[:args].map { |a| a == :fixture ? kase[:fixture] : a }
    probe.call(*args, stdin: kase[:stdin])
  end

  def expected_path(id)
    File.join(EXPECTED_DIR, id.gsub("/", "__").gsub(/[^\w.\-()（）]/, "_") + ".json")
  end

  def report(label, total, failures)
    if failures.empty?
      @out.puts "#{label}: #{total} 件すべて一致しました"
      return true
    end

    @out.puts "#{label}: #{total} 件中 #{failures.size} 件が不一致"
    failures.each do |id, diffs|
      @out.puts "\n  #{id}"
      Array(diffs).first(12).each { |line| @out.puts "    #{line}" }
      @out.puts "    （ほか #{Array(diffs).size - 12} 件）" if Array(diffs).size > 12
    end
    false
  end
end
