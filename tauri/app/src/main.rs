// スパイクと違い、こちらは配布物なので release では端末を出さない。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    chororeader_app::run()
}
