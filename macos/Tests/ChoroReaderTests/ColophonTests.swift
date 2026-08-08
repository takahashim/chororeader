import XCTest
@testable import ChoroReader

/// 奥付の紙面から書誌を拾うところ。
///
/// **紙面は名乗りではない。** 版元が明示した値と違い、こちらは読み取った推測である。
/// 頁番号も電話番号も同じ紙面に並んでいるので、**間違って拾わないこと**を厚く見る。
final class ColophonTests: XCTestCase {
    // MARK: - ISBN の検査数字

    /// 実在の形（13 桁）で合うこと。**架空の番号は検査数字が合わない**ので、
    /// ここだけは実在の書籍が名乗る形を使う（番号そのものに著作物性は無い）。
    func test_検査数字の合うISBNを通す() {
        XCTAssertTrue(Colophon.isValid("9784774170077"))
        XCTAssertTrue(Colophon.isValid("9784774177786"))
        XCTAssertTrue(Colophon.isValid("4774170070"))
    }

    /// **1 桁違えば落ちること。** これが効かないと、紙面の数字を拾ってしまう。
    func test_桁が違えば落とす() {
        XCTAssertFalse(Colophon.isValid("9784774170078"))
        XCTAssertFalse(Colophon.isValid("9784774170076"))
        XCTAssertFalse(Colophon.isValid("1234567890123"))
        XCTAssertFalse(Colophon.isValid(""))
        XCTAssertFalse(Colophon.isValid("978477417007"))
    }

    /// 末尾が X の 10 桁も通ること。
    func test_末尾がXの10桁も通す() {
        XCTAssertTrue(Colophon.isValid("080442957X"))
        XCTAssertFalse(Colophon.isValid("080442957Y"))
    }

    // MARK: - 紙面から拾う

    func test_紙面のISBNを拾う() {
        let text = """
        架空書房
        定価 本体 2,800 円（税別）
        ISBN978-4-7741-7007-7
        Printed in Japan
        """
        XCTAssertEqual(Colophon.isbn(in: text), "9784774170077")
    }

    /// 区切りの形はまちまち。空白入りも C コードつきも通ること。
    func test_区切りが違っても拾う() {
        XCTAssertEqual(Colophon.isbn(in: "ISBN 978-4-7741-7778-6 C3055"), "9784774177786")
        XCTAssertEqual(Colophon.isbn(in: "ISBN：9784774170077"), "9784774170077")
    }

    /// **検査数字の合わない数は拾わない。** 紙面には頁番号も電話番号も並ぶ。
    func test_それらしいだけの数は拾わない() {
        XCTAssertNil(Colophon.isbn(in: "ISBN 978-4-7741-7007-8"))
        XCTAssertNil(Colophon.isbn(in: "電話 03-1234-5678　〒101-0051"))
        XCTAssertNil(Colophon.isbn(in: "架空の本文である。"))
    }

    /// 合わない数の後ろに合う数があれば、そちらを拾うこと。
    func test_合うものが後ろにあれば拾う() {
        let text = """
        ISBN 978-4-7741-7007-8
        ISBN 978-4-7741-7007-7
        """
        XCTAssertEqual(Colophon.isbn(in: text), "9784774170077")
    }

    // MARK: - 発行所

    func test_発行所を拾う() {
        XCTAssertEqual(Colophon.publisher(in: "発行所　架空書房"), "架空書房")
        XCTAssertEqual(Colophon.publisher(in: "発行元：株式会社架空出版"), "株式会社架空出版")
    }

    /// **住所や電話番号を巻き込まない。** 奥付は発行所の後ろに住所が続く。
    func test_住所を巻き込まない() {
        let text = "発行所　架空書房　〒101-0051 東京都千代田区架空 1-2-3"
        XCTAssertEqual(Colophon.publisher(in: text), "架空書房")
    }

    func test_発行所が無ければ拾わない() {
        XCTAssertNil(Colophon.publisher(in: "架空の本文である。"))
        XCTAssertNil(Colophon.publisher(in: "発行所"))
    }
}
