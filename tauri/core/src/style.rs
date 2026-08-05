//! 表示設定の値そのもの。生成する CSS は入力から一意に決まるため、実装間で揃える対象になる。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Theme {
    Light,
    Sepia,
    Dark,
}

impl Theme {
    pub fn parse(value: Option<&str>) -> Self {
        match value.map(str::to_ascii_lowercase).as_deref() {
            Some("sepia") => Theme::Sepia,
            Some("dark") => Theme::Dark,
            _ => Theme::Light,
        }
    }

    fn background(self) -> &'static str {
        match self {
            Theme::Light => "#ffffff",
            Theme::Sepia => "#f6efe2",
            Theme::Dark => "#1c1c1e",
        }
    }

    fn foreground(self) -> &'static str {
        match self {
            Theme::Light => "#1a1a1a",
            Theme::Sepia => "#3a3226",
            Theme::Dark => "#d6d6d6",
        }
    }

    fn link(self) -> &'static str {
        match self {
            Theme::Light => "#0b5cad",
            Theme::Sepia => "#8a5a1a",
            Theme::Dark => "#79b1ff",
        }
    }

    fn code_background(self) -> &'static str {
        match self {
            Theme::Light => "#f4f4f6",
            Theme::Sepia => "#ece3d2",
            Theme::Dark => "#2b2b2e",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ReaderStyle {
    pub font_size_percent: f64,
    pub line_height: f64,
    pub max_width_em: f64,
    pub theme: Theme,
    pub body_font: String,
    pub code_font: String,
    pub code_wrap: bool,
    pub publisher_style: bool,
}

impl Default for ReaderStyle {
    fn default() -> Self {
        Self {
            font_size_percent: 100.0,
            line_height: 1.8,
            max_width_em: 42.0,
            theme: Theme::Light,
            body_font: String::new(),
            code_font: "SF Mono".to_string(),
            code_wrap: false,
            publisher_style: false,
        }
    }
}

impl ReaderStyle {
    /// 暗いテーマでは、背景色を持たない要素にだけ文字色を当てる。その印付けが要るかどうか。
    pub fn needs_foreground_marking(&self) -> bool {
        !self.publisher_style && self.theme == Theme::Dark
    }

    /// 本文へ被せるスタイル。出版社 CSS を壊さない範囲に絞る。
    pub fn css(&self) -> String {
        let background = self.theme.background();
        let foreground = self.theme.foreground();
        let width_rule = if self.max_width_em > 0.0 {
            format!("max-width: {}em !important;", self.max_width_em as i64)
        } else {
            String::new()
        };
        let body_font_rule = if self.body_font.is_empty() {
            String::new()
        } else {
            format!("font-family: \"{}\", serif !important;", self.body_font)
        };

        // 出版社スタイル優先のときは、色と幅だけを最小限に整える。
        if self.publisher_style {
            return format!(
                "html {{ background-color: {background} !important; }}\n\
                 body {{ {width_rule} margin-left: auto !important; margin-right: auto !important; }}\n\
                 img, svg, video {{ max-width: 100% !important; height: auto !important; }}\n\
                 pre {{ overflow-x: auto; }}"
            );
        }

        // 文字色の上書きは暗いテーマだけに限る。
        // 明るいテーマとセピアでは、出版社の配色は明るい紙を前提に組まれていてそのまま読める。
        // 一律に上書きすると、見出しの黒帯のように背景色を持つ要素から文字色を奪ってしまう。
        let color_rules = if self.theme == Theme::Dark {
            format!(
                "body {{ color: {foreground} !important; }}\n\
                 /* 背景色を持たない要素だけに当てる。印は tzrApplyForeground が付ける。 */\n\
                 .tzr-fg {{ color: {foreground} !important; }}\n\
                 a.tzr-fg, .tzr-fg a:not([class]) {{ color: {} !important; }}",
                self.theme.link()
            )
        } else {
            format!("body {{ color: {foreground}; }}")
        };

        let line_height = format!("{:.2}", self.line_height);
        let font_size = self.font_size_percent as i64;
        let code_font = &self.code_font;
        let code_background = self.theme.code_background();
        let white_space = if self.code_wrap { "pre-wrap" } else { "pre" };
        let word_break = if self.code_wrap { "break-all" } else { "normal" };

        format!(
            "html {{\n\
             \x20   font-size: {font_size}% !important;\n\
             \x20   background-color: {background} !important;\n\
             \x20   -webkit-text-size-adjust: none;\n\
             }}\n\
             body {{\n\
             \x20   line-height: {line_height} !important;\n\
             \x20   {width_rule}\n\
             \x20   margin: 0 auto !important;\n\
             \x20   padding: 2em 1.6em 6em !important;\n\
             \x20   background-color: {background} !important;\n\
             \x20   {body_font_rule}\n\
             }}\n\
             {color_rules}\n\
             img, svg, video {{ max-width: 100% !important; height: auto !important; }}\n\
             table {{ max-width: 100% !important; display: block; overflow-x: auto; }}\n\
             /* コードは等幅で読めることを最優先にし、内側の色付けには触れない */\n\
             pre, code, kbd, samp {{\n\
             \x20   font-family: \"{code_font}\", ui-monospace, Menlo, monospace !important;\n\
             \x20   background-color: {code_background} !important;\n\
             }}\n\
             pre {{\n\
             \x20   padding: 0.8em 1em !important;\n\
             \x20   border-radius: 6px;\n\
             \x20   overflow-x: auto !important;\n\
             \x20   white-space: {white_space} !important;\n\
             \x20   word-break: {word_break} !important;\n\
             }}"
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 幅の指定が無いときは行を空白だけにする() {
        let style = ReaderStyle {
            max_width_em: 0.0,
            ..Default::default()
        };
        assert!(style.css().contains("line-height: 1.80 !important;\n    \n    margin: 0 auto"));
    }

    #[test]
    fn 明るいテーマでは文字色を上書きしない() {
        let style = ReaderStyle::default();
        assert!(style.css().contains("body { color: #1a1a1a; }"));
        assert!(!style.needs_foreground_marking());
    }

    #[test]
    fn 暗いテーマだけが印付けを要る() {
        let style = ReaderStyle {
            theme: Theme::Dark,
            ..Default::default()
        };
        assert!(style.needs_foreground_marking());
        assert!(style.css().contains(".tzr-fg { color: #d6d6d6 !important; }"));
    }
}
