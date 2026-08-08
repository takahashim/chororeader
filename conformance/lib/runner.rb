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
  KNOWN_PATH = File.join(ROOT, "conformance", "known-differences.json")

  def initialize(out: $stdout, known_path: KNOWN_PATH)
    @out = out
    @known_path = known_path
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
    known = []
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
      next if diff.empty?

      # 期待値は recorded_by の出力である。照合は「その実装と probe が揃うか」を見ている。
      if (reason = known_reason(kase[:id], [recorded_by, probe.name]))
        known << [kase[:id], reason, diff]
      else
        failures << [kase[:id], diff]
      end
    end
    report(probe.name, total, failures, known)
  end

  # --- 実装どうしの突き合わせ ---

  def diff(probe_a, probe_b, book: nil)
    failures = []
    known = []
    total = 0
    cases = book ? book_cases(book) : all_cases
    cases.each do |kase|
      total += 1
      a = invoke(probe_a, kase)
      b = invoke(probe_b, kase)
      d = compare(a, b)
      next if d.empty?

      if (reason = known_reason(kase[:id], [probe_a.name, probe_b.name]))
        known << [kase[:id], reason, d]
      else
        failures << [kase[:id], d]
      end
    end
    report("#{probe_a.name} ↔ #{probe_b.name}", total, failures, known)
  end

  # --- 既知の差 ---

  # 実装がまだ揃っていないと分かっている事例。
  #
  # 揃えないと決めたという意味ではない。どちらへ寄せるかを決めるまでのあいだ、
  # 何がどう食い違っているかを毎回の記録に残すための場所である。
  # 載せた事例は不一致として数えないが、差の中身はそのまま出す。
  def known_differences
    @known_differences ||=
      File.exist?(@known_path) ? JSON.parse(File.read(@known_path)) : { "事例" => {} }
  end

  def recorded_by
    known_differences["期待値の記録元"] || "swift"
  end

  # 挙げた実装が別々の組にいるときだけ、既知の差として扱う。
  #
  # 同じ組どうしの食い違いは、既知の差では説明がつかない。新しく壊れたものとして落とす。
  # 組に載っていない実装が混じったときも落とす。分類していないものを黙って見逃さないため。
  def known_reason(id, names)
    entry = known_differences.dig("事例", id)
    return nil unless entry

    groups = entry["分かれ方"] || {}
    where = names.map { |name| groups.find { |_, members| members.include?(name) }&.first }
    return nil if where.any?(&:nil?) || where.uniq.size < 2

    entry["理由"]
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
    ensure_distinct_expected_paths(list)
    list
  end

  # 期待値の置き場所は、事例の名前から作る。
  # 記号や漢字は `_` に均すので、長さの同じ問い合わせ 2 つが同じ名前に落ちうる。
  # そうなると片方の期待値がもう片方を上書きし、両方とも通ったように見えてしまう。
  # 名前を作る規則を変えると既存の期待値が全部引っ越すので、重なりを見つけて止めるだけにする。
  def ensure_distinct_expected_paths(cases)
    seen = {}
    cases.each do |kase|
      name = File.basename(expected_path(kase[:id]))
      if (other = seen[name])
        raise "事例「#{other}」と「#{kase[:id]}」の期待値が同じ置き場所（#{name}）になります。" \
              "どちらかの名前を変えてください。"
      end
      seen[name] = kase[:id]
    end
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

  def report(label, total, failures, known = [])
    if failures.empty?
      @out.puts(known.empty? ? "#{label}: #{total} 件すべて一致しました"
                             : "#{label}: #{total} 件中 #{total - known.size} 件が一致、#{known.size} 件は既知の差")
    else
      @out.puts "#{label}: #{total} 件中 #{failures.size} 件が不一致"
      failures.each { |id, diffs| print_case(id, nil, diffs) }
    end

    unless known.empty?
      @out.puts "\n既知の差（conformance/known-differences.json）"
      known.each { |id, reason, diffs| print_case(id, reason, diffs) }
    end

    failures.empty?
  end

  def print_case(id, reason, diffs)
    @out.puts "\n  #{id}"
    @out.puts "    ← #{reason}" if reason
    Array(diffs).first(12).each { |line| @out.puts "    #{line}" }
    @out.puts "    （ほか #{Array(diffs).size - 12} 件）" if Array(diffs).size > 12
  end
end
