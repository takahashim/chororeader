# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/runner"

# 比較器が壊れると、実装が食い違っていても全件「一致」と報告されてしまう。
# 検証ツールの中でここだけは必ず守る。
class CompareTest < Minitest::Test
  def setup
    @runner = Runner.new(out: StringIO.new)
  end

  def test_identical_structures_have_no_difference
    doc = { "a" => 1, "b" => ["x", { "c" => true }] }
    assert_empty @runner.compare(doc, Marshal.load(Marshal.dump(doc)))
  end

  def test_detects_changed_scalar
    diffs = @runner.compare({ "spineCount" => 15 }, { "spineCount" => 16 })
    assert_equal 1, diffs.size
    assert_includes diffs.first, "spineCount"
    assert_includes diffs.first, "15"
    assert_includes diffs.first, "16"
  end

  def test_detects_missing_and_extra_keys
    diffs = @runner.compare({ "a" => 1, "b" => 2 }, { "a" => 1, "c" => 3 })
    assert_equal 2, diffs.size
    assert(diffs.any? { |d| d.start_with?("b:") && d.include?("キーがありません") })
    assert(diffs.any? { |d| d.start_with?("c:") && d.include?("増えています") })
  end

  def test_detects_array_size_mismatch
    diffs = @runner.compare({ "items" => [1, 2] }, { "items" => [1] })
    assert_equal 1, diffs.size
    assert_includes diffs.first, "要素数が違います"
  end

  def test_reports_nested_path
    diffs = @runner.compare(
      { "toc" => [{ "children" => [{ "title" => "第 1 章" }] }] },
      { "toc" => [{ "children" => [{ "title" => "第 2 章" }] }] }
    )
    assert_equal 1, diffs.size
    assert_includes diffs.first, "toc[0].children[0].title"
  end

  def test_detects_type_mismatch
    refute_empty @runner.compare({ "a" => [] }, { "a" => {} })
    refute_empty @runner.compare({ "a" => {} }, { "a" => [] })
    refute_empty @runner.compare({ "a" => "1" }, { "a" => 1 })
  end

  def test_distinguishes_null_from_missing
    refute_empty @runner.compare({ "language" => "ja" }, { "language" => nil })
    assert_empty @runner.compare({ "language" => nil }, { "language" => nil })
  end

  # 実装差でありがちな、丸め方の違いを見逃さないこと。
  def test_detects_float_difference
    refute_empty @runner.compare({ "progression" => 0.123 }, { "progression" => 0.124 })
    assert_empty @runner.compare({ "progression" => 0.123 }, { "progression" => 0.123 })
  end
end

# 期待値の置き場所は事例の名前から作る。記号や漢字は潰れるので、
# 長さの同じ問い合わせ 2 つが同じ名前に落ちうる。そのまま通すと、
# 片方の期待値がもう片方を上書きし、両方とも通ったように見えてしまう。
class ExpectedPathTest < Minitest::Test
  def setup
    @runner = Runner.new(out: StringIO.new)
  end

  def test_detects_colliding_expected_paths
    cases = [{ id: "search/counting/まま" }, { id: "search/counting/こう" }]
    error = assert_raises(RuntimeError) { @runner.send(:ensure_distinct_expected_paths, cases) }
    assert_includes error.message, "まま"
    assert_includes error.message, "こう"
  end

  def test_allows_distinct_expected_paths
    cases = [{ id: "search/counting/まま" }, { id: "search/counting/っこう" }]
    @runner.send(:ensure_distinct_expected_paths, cases)
  end
end
