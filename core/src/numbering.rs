#[derive(Debug, Clone, Copy)]
pub(crate) enum Numeral {
    Decimal,
    Alphabetic,
    Roman,
}

pub(crate) fn format_num(number: u32, num_fmt: &str) -> String {
    match num_fmt {
        "lowerLetter" => alphabetic(number, false),
        "upperLetter" => alphabetic(number, true),
        "lowerRoman" => roman(number)
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_else(|| number.to_string()),
        "upperRoman" => roman(number)
            .map(|s| s.to_ascii_uppercase())
            .unwrap_or_else(|| number.to_string()),
        _ => number.to_string(),
    }
}

pub(crate) fn alphabetic(number: u32, uppercase: bool) -> String {
    let index = number.saturating_sub(1);
    let base = if uppercase { b'A' } else { b'a' };
    let letter = char::from_u32(u32::from(base) + index % 26).unwrap_or('a');
    let repeat = usize::try_from(index / 26 + 1).unwrap_or(1).min(10);
    letter.to_string().repeat(repeat)
}

pub(crate) fn format_scheme(number: u32, scheme: &str) -> Option<String> {
    let (numeral, uppercase, prefix, suffix) = match scheme {
        "arabicPeriod" => (Numeral::Decimal, false, "", ". "),
        "arabicParenR" => (Numeral::Decimal, false, "", ") "),
        "arabicParenBoth" => (Numeral::Decimal, false, "(", ") "),
        "arabicPlain" => (Numeral::Decimal, false, "", " "),
        "alphaLcPeriod" => (Numeral::Alphabetic, false, "", ". "),
        "alphaUcPeriod" => (Numeral::Alphabetic, true, "", ". "),
        "alphaLcParenR" => (Numeral::Alphabetic, false, "", ") "),
        "alphaUcParenR" => (Numeral::Alphabetic, true, "", ") "),
        "alphaLcParenBoth" => (Numeral::Alphabetic, false, "(", ") "),
        "alphaUcParenBoth" => (Numeral::Alphabetic, true, "(", ") "),
        "romanLcPeriod" => (Numeral::Roman, false, "", ". "),
        "romanUcPeriod" => (Numeral::Roman, true, "", ". "),
        "romanLcParenR" => (Numeral::Roman, false, "", ") "),
        "romanUcParenR" => (Numeral::Roman, true, "", ") "),
        "romanLcParenBoth" => (Numeral::Roman, false, "(", ") "),
        "romanUcParenBoth" => (Numeral::Roman, true, "(", ") "),
        _ => return None,
    };
    let mut label = match numeral {
        Numeral::Decimal => number.to_string(),
        Numeral::Alphabetic => alphabetic(number, uppercase),
        Numeral::Roman => roman(number)?,
    };
    if uppercase {
        label.make_ascii_uppercase();
    }
    Some(format!("{prefix}{label}{suffix}"))
}

pub(crate) fn roman(mut number: u32) -> Option<String> {
    if !(1..=3999).contains(&number) {
        return None;
    }
    let mut label = String::new();
    for (value, symbol) in [
        (1000, "m"),
        (900, "cm"),
        (500, "d"),
        (400, "cd"),
        (100, "c"),
        (90, "xc"),
        (50, "l"),
        (40, "xl"),
        (10, "x"),
        (9, "ix"),
        (5, "v"),
        (4, "iv"),
        (1, "i"),
    ] {
        while number >= value {
            label.push_str(symbol);
            number -= value;
        }
    }
    Some(label)
}
