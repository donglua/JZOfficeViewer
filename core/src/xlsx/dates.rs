use super::format::Decimal;

pub(super) fn display(value: &Decimal, code: &str, date1904: bool) -> Option<String> {
    let (date_code, time_code) = match code {
        "yyyy-mm-dd" | "m/d/yy" | "mm/dd/yy" | "m/d/yyyy" | "mm/dd/yyyy" | "mm-dd-yy"
        | "d-mmm-yy" | "d-mmm" | "mmm-yy" => (code, ""),
        "m/d/yy h:mm" => ("m/d/yy", "h:mm"),
        "m/d/yyyy h:mm" => ("m/d/yyyy", "h:mm"),
        "yyyy-mm-dd h:mm:ss" => ("yyyy-mm-dd", "h:mm:ss"),
        "h:mm" | "hh:mm" | "h:mm:ss" | "hh:mm:ss" | "h:mm am/pm" | "h:mm:ss am/pm" | "mm:ss"
        | "[h]:mm:ss" => ("", code),
        _ => return None,
    };
    let max_day = if date1904 { 2_957_003 } else { 2_958_465 };
    let whole_day = value.units(1, false)?;
    if whole_day > max_day {
        return None;
    }
    let seconds = value.units(86_400, true)?;
    let day = if time_code.is_empty() {
        whole_day
    } else {
        seconds / 86_400
    };
    if day > max_day {
        return None;
    }
    let mut result = if date_code.is_empty() {
        String::new()
    } else if day == 0 && !time_code.is_empty() && !date1904 {
        Calendar {
            year: 1900,
            month: 1,
            day: 0,
        }
        .render(date_code)?
    } else {
        calendar(u32::try_from(day).ok()?, date1904)?.render(date_code)?
    };
    if !time_code.is_empty() {
        if !result.is_empty() {
            result.push(' ');
        }
        result.push_str(&time(seconds, time_code));
    }
    Some(result)
}

struct Calendar {
    year: u32,
    month: u32,
    day: u32,
}

impl Calendar {
    fn render(&self, code: &str) -> Option<String> {
        let Self { year, month, day } = *self;
        let short_year = year % 100;
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ];
        let name = months.get(usize::try_from(month.checked_sub(1)?).ok()?)?;
        Some(match code {
            "yyyy-mm-dd" => format!("{year:04}-{month:02}-{day:02}"),
            "m/d/yy" => format!("{month}/{day}/{short_year:02}"),
            "mm/dd/yy" => format!("{month:02}/{day:02}/{short_year:02}"),
            "m/d/yyyy" => format!("{month}/{day}/{year:04}"),
            "mm/dd/yyyy" => format!("{month:02}/{day:02}/{year:04}"),
            "mm-dd-yy" => format!("{month:02}-{day:02}-{short_year:02}"),
            "d-mmm-yy" => format!("{day}-{name}-{short_year:02}"),
            "d-mmm" => format!("{day}-{name}"),
            "mmm-yy" => format!("{name}-{short_year:02}"),
            _ => return None,
        })
    }
}

fn calendar(serial: u32, date1904: bool) -> Option<Calendar> {
    if !date1904 && serial == 60 {
        return Some(Calendar {
            year: 1900,
            month: 2,
            day: 29,
        });
    }
    let epoch = if date1904 { 1904 } else { 1900 };
    let ordinal = if date1904 {
        serial
    } else {
        serial.checked_sub(1 + u32::from(serial > 60))?
    };
    let mut year = epoch + ordinal / 366;
    let mut remaining = ordinal - (days_before_year(year) - days_before_year(epoch));
    while remaining >= 365 + u32::from(leap(year)) {
        remaining -= 365 + u32::from(leap(year));
        year += 1;
    }
    let month_days = [
        31,
        28 + u32::from(leap(year)),
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut month = 1;
    for days in month_days {
        if remaining < days {
            return Some(Calendar {
                year,
                month,
                day: remaining + 1,
            });
        }
        remaining -= days;
        month += 1;
    }
    None
}

const fn leap(year: u32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

const fn days_before_year(year: u32) -> u32 {
    let preceding = year - 1;
    365 * preceding + preceding / 4 - preceding / 100 + preceding / 400
}

fn time(seconds: u64, code: &str) -> String {
    let hour = seconds / 3_600 % 24;
    let minute = seconds / 60 % 60;
    let second = seconds % 60;
    match code {
        "mm:ss" => format!("{minute:02}:{second:02}"),
        "[h]:mm:ss" => format!("{}:{minute:02}:{second:02}", seconds / 3_600),
        _ => {
            let meridiem = code.ends_with("am/pm");
            let shown_hour = if meridiem { (hour + 11) % 12 + 1 } else { hour };
            let width = if code.starts_with("hh") { 2 } else { 1 };
            let mut result = if code.contains("ss") {
                format!("{shown_hour:0width$}:{minute:02}:{second:02}")
            } else {
                format!("{shown_hour:0width$}:{minute:02}")
            };
            if meridiem {
                result.push_str(if hour < 12 { " AM" } else { " PM" });
            }
            result
        }
    }
}
