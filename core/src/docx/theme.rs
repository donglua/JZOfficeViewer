use crate::xml::Node;
use std::collections::HashMap;

#[derive(Debug, Default, Clone)]
pub(super) struct ThemeFonts {
    fonts: HashMap<String, String>,
}

impl ThemeFonts {
    pub fn parse(root: Option<&Node>) -> Self {
        let mut fonts = HashMap::new();
        let Some(root) = root else {
            return Self { fonts };
        };
        let font_scheme = root
            .child("themeElements")
            .and_then(|te| te.child("fontScheme"));
        let Some(scheme) = font_scheme else {
            return Self { fonts };
        };

        for (slot, prefix) in [("majorFont", "major"), ("minorFont", "minor")] {
            if let Some(font_node) = scheme.child(slot) {
                if let Some(latin) = font_node.child("latin") {
                    let tf = latin.attr("typeface");
                    if !tf.is_empty() {
                        fonts.insert(format!("{prefix}HAnsi"), tf.to_owned());
                        fonts.insert(format!("{prefix}Ascii"), tf.to_owned());
                        fonts.insert(format!("{prefix}Latin"), tf.to_owned());
                    }
                }
                if let Some(ea) = font_node.child("ea") {
                    let mut tf = ea.attr("typeface");
                    if tf.is_empty() {
                        const EAST_ASIA_SCRIPTS: &[&[&str]] =
                            &[&["Hans"], &["Hant"], &["Jpan"], &["Kore", "Hang"]];
                        for candidate in EAST_ASIA_SCRIPTS {
                            if let Some(font) = font_node
                                .named("font")
                                .find(|f| candidate.contains(&f.attr("script")))
                            {
                                let candidate_tf = font.attr("typeface");
                                if !candidate_tf.is_empty() {
                                    tf = candidate_tf;
                                    break;
                                }
                            }
                        }
                    }
                    if !tf.is_empty() {
                        fonts.insert(format!("{prefix}EastAsia"), tf.to_owned());
                    }
                }
                if let Some(cs) = font_node.child("cs") {
                    let tf = cs.attr("typeface");
                    if !tf.is_empty() {
                        fonts.insert(format!("{prefix}Bidi"), tf.to_owned());
                        fonts.insert(format!("{prefix}Cs"), tf.to_owned());
                    }
                }
            }
        }
        Self { fonts }
    }

    pub fn get(&self, theme: &str) -> Option<&str> {
        self.fonts.get(theme).map(|s| s.as_str())
    }
}
