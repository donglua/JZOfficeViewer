use crate::xml::Node;
use std::collections::HashMap;

#[derive(Debug, Clone, Default)]
pub(super) struct LevelDef {
    pub num_fmt: String,
    pub lvl_text: String,
    pub start: u32,
}

#[derive(Debug, Default)]
pub(super) struct Numbering {
    abstract_nums: HashMap<String, HashMap<u8, LevelDef>>,
    nums: HashMap<String, String>,
    counters: HashMap<(String, u8), u32>,
}

impl Numbering {
    pub fn parse(root: Option<&Node>) -> Self {
        let mut numbering = Self::default();
        let Some(root) = root else {
            return numbering;
        };
        for node in &root.children {
            match node.name.as_str() {
                "abstractNum" => {
                    let id = node.attr("abstractNumId").to_owned();
                    if id.is_empty() {
                        continue;
                    }
                    let mut levels = HashMap::new();
                    for child in &node.children {
                        if child.name == "lvl" {
                            let ilvl = child.attr("ilvl").parse::<u8>().unwrap_or(0);
                            let start = child
                                .child("start")
                                .and_then(|n| n.attr("val").parse::<u32>().ok())
                                .unwrap_or(1);
                            let num_fmt = child
                                .child("numFmt")
                                .map_or("", |n| n.attr("val"))
                                .to_owned();
                            let lvl_text = child
                                .child("lvlText")
                                .map_or("", |n| n.attr("val"))
                                .to_owned();
                            levels.insert(
                                ilvl,
                                LevelDef {
                                    num_fmt,
                                    lvl_text,
                                    start,
                                },
                            );
                        }
                    }
                    numbering.abstract_nums.insert(id, levels);
                }
                "num" => {
                    let id = node.attr("numId").to_owned();
                    if let Some(abstract_num) = node.child("abstractNumId") {
                        let abstract_id = abstract_num.attr("val").to_owned();
                        numbering.nums.insert(id, abstract_id);
                    }
                }
                _ => (),
            }
        }
        numbering
    }

    pub fn bullet(&mut self, num_id: &str, ilvl: u8) -> String {
        let Some(abstract_id) = self.nums.get(num_id) else {
            return "\u{2022} ".to_owned();
        };
        let Some(levels) = self.abstract_nums.get(abstract_id) else {
            return "\u{2022} ".to_owned();
        };
        let Some(level_def) = levels.get(&ilvl) else {
            return "\u{2022} ".to_owned();
        };
        if level_def.num_fmt == "bullet" || level_def.lvl_text.is_empty() {
            let symbol = if level_def.lvl_text.is_empty() {
                "\u{2022}"
            } else {
                level_def.lvl_text.as_str()
            };
            return format!("{symbol} ");
        }

        let key = (num_id.to_owned(), ilvl);
        let counter = self
            .counters
            .entry(key)
            .or_insert(level_def.start.saturating_sub(1));
        *counter = counter.saturating_add(1);
        let current_val = *counter;

        for deeper in (ilvl + 1)..=9 {
            self.counters.remove(&(num_id.to_owned(), deeper));
        }

        let mut result = level_def.lvl_text.clone();
        for lvl_idx in 1..=9 {
            let placeholder = format!("%{lvl_idx}");
            if result.contains(&placeholder) {
                let val = if lvl_idx - 1 == ilvl {
                    current_val
                } else {
                    self.counters
                        .get(&(num_id.to_owned(), lvl_idx - 1))
                        .copied()
                        .unwrap_or(1)
                };
                let formatted = crate::numbering::format_num(val, &level_def.num_fmt);
                result = result.replace(&placeholder, &formatted);
            }
        }
        format!("{result} ")
    }
}
