pub(super) const fn builtin(id: u32) -> Option<&'static str> {
    Some(match id {
        0 => "General",
        1 => "0",
        2 => "0.00",
        3 => "#,##0",
        4 => "#,##0.00",
        9 => "0%",
        10 => "0.00%",
        14 => "mm-dd-yy",
        15 => "d-mmm-yy",
        16 => "d-mmm",
        17 => "mmm-yy",
        18 => "h:mm AM/PM",
        19 => "h:mm:ss AM/PM",
        20 => "h:mm",
        21 => "h:mm:ss",
        22 => "m/d/yy h:mm",
        45 => "mm:ss",
        46 => "[h]:mm:ss",
        49 => "@",
        _ => return None,
    })
}

pub(crate) fn display(raw: &str, code: &str, date1904: bool) -> Option<String> {
    if code.is_empty() {
        return None;
    }
    if code.eq_ignore_ascii_case("General") || code == "@" {
        return Some(raw.to_owned());
    }
    if raw.len() > 512 || code.len() > 128 {
        return None;
    }
    let value = Decimal::parse(raw)?;

    // 1. 按未转义分号切分 sections
    let raw_sections = split_format_sections(code);
    let is_zero = value.digits.is_empty() || value.digits.iter().all(|d| *d == b'0');
    let is_negative = value.negative && !is_zero;

    let selected = match raw_sections.len() {
        1 => raw_sections[0],
        2 => {
            if is_negative {
                raw_sections[1]
            } else {
                raw_sections[0]
            }
        }
        3 | 4 => {
            if is_negative {
                raw_sections[1]
            } else if is_zero {
                raw_sections[2]
            } else {
                raw_sections[0]
            }
        }
        _ => return None,
    };

    if selected.is_empty() {
        return if raw_sections.len() > 1 {
            Some(String::new())
        } else {
            None
        };
    }

    // 2. 剥离中括号指令标签 ([$-409], [Red] 等)
    let cleaned = strip_format_brackets(selected);
    if cleaned.is_empty() {
        return if raw_sections.len() > 1 {
            Some(String::new())
        } else {
            None
        };
    }
    if cleaned == "@" {
        return Some(raw.to_owned());
    }

    let trimmed = cleaned.trim();
    // 处理纯文本字面量段落（例如 "-" 或 "N/A" 或 "\"-\""）
    if trimmed == "\"-\"" || trimmed == "-" {
        return Some("-".to_owned());
    }
    if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2 {
        let inside = &trimmed[1..trimmed.len() - 1];
        if !inside.contains('"') {
            return Some(inside.to_owned());
        }
    }

    // 3. 处理带括号或显式负号的负数段，如 (#,##0.00) 或 -0
    // 若原代码含有尾随空格，保持原样交给 number 判定 unsupported_trailing_space
    let has_trailing_space = cleaned.ends_with(' ');
    let (prefix, inner_code, suffix) = if trimmed.starts_with('(') && trimmed.ends_with(')') {
        ("(", trimmed[1..trimmed.len() - 1].trim(), ")")
    } else if trimmed.starts_with('-') && raw_sections.len() > 1 {
        ("-", trimmed[1..].trim(), "")
    } else if has_trailing_space {
        ("", cleaned.as_str(), "")
    } else {
        ("", trimmed, "")
    };

    if inner_code.starts_with(['0', '#']) {
        let eval_val = if is_negative && (raw_sections.len() > 1 || !prefix.is_empty()) {
            Decimal {
                negative: false,
                digits: value.digits.clone(),
                point: value.point,
            }
        } else {
            Decimal {
                negative: value.negative,
                digits: value.digits.clone(),
                point: value.point,
            }
        };
        let formatted = number(&eval_val, inner_code)?;
        if !prefix.is_empty() || !suffix.is_empty() {
            Some(format!("{prefix}{formatted}{suffix}"))
        } else {
            Some(formatted)
        }
    } else {
        super::dates::display(&value, &inner_code.to_ascii_lowercase(), date1904)
    }
}

fn strip_format_brackets(code: &str) -> String {
    let mut out = String::with_capacity(code.len());
    let mut chars = code.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\\' {
            out.push(ch);
            if let Some(next) = chars.next() {
                out.push(next);
            }
            continue;
        }
        if ch == '"' {
            out.push(ch);
            for inner in chars.by_ref() {
                out.push(inner);
                if inner == '"' {
                    break;
                }
            }
            continue;
        }
        if ch == '[' {
            let mut tag = String::new();
            let mut closed = false;
            for inner in chars.by_ref() {
                if inner == ']' {
                    closed = true;
                    break;
                }
                tag.push(inner);
            }
            if !closed {
                out.push('[');
                out.push_str(&tag);
                break;
            }
            let lower = tag.trim().to_ascii_lowercase();
            // 保留时间耗时括号 [h], [hh], [m], [mm], [s], [ss]
            if matches!(lower.as_str(), "h" | "hh" | "m" | "mm" | "s" | "ss") {
                out.push('[');
                out.push_str(&tag);
                out.push(']');
            } else if lower.starts_with("$-") || is_color_tag(&lower) {
                // 剥离 [$-409] 区域代码与颜色标签
                continue;
            } else {
                out.push('[');
                out.push_str(&tag);
                out.push(']');
            }
        } else {
            out.push(ch);
        }
    }
    out
}

fn is_color_tag(tag: &str) -> bool {
    matches!(
        tag,
        "black" | "blue" | "cyan" | "green" | "magenta" | "red" | "white" | "yellow"
    ) || (tag.starts_with("color") && tag[5..].chars().all(|c| c.is_ascii_digit()))
}

fn split_format_sections(code: &str) -> Vec<&str> {
    let mut sections = Vec::new();
    let mut in_quotes = false;
    let mut in_brackets = false;
    let mut start = 0;
    let bytes = code.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => {
                i += 2;
                continue;
            }
            b'"' => in_quotes = !in_quotes,
            b'[' if !in_quotes => in_brackets = true,
            b']' if !in_quotes => in_brackets = false,
            b';' if !in_quotes && !in_brackets => {
                sections.push(&code[start..i]);
                start = i + 1;
            }
            _ => (),
        }
        i += 1;
    }
    sections.push(&code[start..]);
    sections
}

pub(super) struct Decimal {
    negative: bool,
    digits: Vec<u8>,
    point: i32,
}

impl Decimal {
    fn parse(raw: &str) -> Option<Self> {
        if !raw.parse::<f64>().ok()?.is_finite() {
            return None;
        }
        let negative = raw.starts_with('-');
        let unsigned = raw.strip_prefix(['-', '+']).unwrap_or(raw);
        let (mantissa, exponent) = match unsigned.split_once(['e', 'E']) {
            Some((mantissa, exponent)) => (mantissa, exponent.parse::<i32>().ok()?),
            None => (unsigned, 0),
        };
        if !(-400..=400).contains(&exponent) {
            return None;
        }
        let (integer, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
        let mut digits: Vec<u8> = integer.bytes().chain(fraction.bytes()).collect();
        if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
            return None;
        }
        let leading = digits.iter().take_while(|digit| **digit == b'0').count();
        let point = i32::try_from(integer.len()).ok()? + exponent - i32::try_from(leading).ok()?;
        digits.drain(..leading);
        Some(Self {
            negative,
            digits,
            point,
        })
    }

    fn quantize(&self, places: i32, round: bool) -> Option<Vec<u8>> {
        let end = self.point + places;
        if end > 512 {
            return None;
        }
        if end < 0 || self.digits.is_empty() {
            return Some(vec![b'0']);
        }
        let end = usize::try_from(end).ok()?;
        let mut result = self.digits[..end.min(self.digits.len())].to_vec();
        result.resize(end, b'0');
        if round && self.digits.get(end).is_some_and(|digit| *digit >= b'5') {
            let mut carry = true;
            for digit in result.iter_mut().rev() {
                if *digit < b'9' {
                    *digit += 1;
                    carry = false;
                    break;
                }
                *digit = b'0';
            }
            if carry {
                result.insert(0, b'1');
            }
        }
        if result.is_empty() {
            result.push(b'0');
        }
        Some(result)
    }

    pub(super) fn units(&self, multiplier: u32, round: bool) -> Option<u64> {
        if self.negative && !self.digits.is_empty() {
            return None;
        }
        let mut scaled = Self {
            negative: false,
            digits: self.digits.clone(),
            point: self.point,
        };
        let mut carry = 0;
        for digit in scaled.digits.iter_mut().rev() {
            let product = u32::from(*digit - b'0')
                .checked_mul(multiplier)?
                .checked_add(carry)?;
            *digit = u8::try_from(product % 10).ok()? + b'0';
            carry = product / 10;
        }
        while carry > 0 {
            scaled
                .digits
                .insert(0, u8::try_from(carry % 10).ok()? + b'0');
            scaled.point += 1;
            carry /= 10;
        }
        scaled
            .quantize(0, round)?
            .into_iter()
            .try_fold(0_u64, |value, digit| {
                value.checked_mul(10)?.checked_add(u64::from(digit - b'0'))
            })
    }
}

fn number(value: &Decimal, code: &str) -> Option<String> {
    let percent = code.ends_with('%');
    let body = code.strip_suffix('%').unwrap_or(code);
    let (integer, decimals) = body.split_once('.').unwrap_or((body, ""));
    let grouped = match integer {
        "0" => false,
        "#,##0" => true,
        _ => return None,
    };
    let required = decimals.bytes().take_while(|digit| *digit == b'0').count();
    if decimals.len() > 15
        || !decimals[required..].bytes().all(|digit| digit == b'#')
        || (decimals.is_empty() && body.contains('.'))
    {
        return None;
    }
    let places = i32::try_from(decimals.len()).ok()? + if percent { 2 } else { 0 };
    let digits = value.quantize(places, true)?;
    let negative = value.negative && digits.iter().any(|digit| *digit != b'0');
    let mut padded = vec![b'0'; (decimals.len() + 1).saturating_sub(digits.len())];
    padded.extend(digits);
    let split = padded.len() - decimals.len();
    let mut result = String::with_capacity(padded.len() + padded.len() / 3 + 3);
    if negative {
        result.push('-');
    }
    for (index, digit) in padded[..split].iter().enumerate() {
        if grouped && index > 0 && (split - index) % 3 == 0 {
            result.push(',');
        }
        result.push(char::from(*digit));
    }
    let mut end = padded.len();
    while end > split + required && padded[end - 1] == b'0' {
        end -= 1;
    }
    if end > split {
        result.push('.');
        result.extend(padded[split..end].iter().copied().map(char::from));
    }
    if percent {
        result.push('%');
    }
    Some(result)
}

#[cfg(test)]
#[path = "format_tests.rs"]
mod tests;
