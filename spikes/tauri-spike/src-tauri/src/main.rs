// スパイクなので、release でも端末を切り離さない。
// 判定結果は標準出力へ書くため、windows_subsystem = "windows" を付けると読めなくなる。
fn main() {
    app_lib::run();
}
