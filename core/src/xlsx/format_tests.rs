use super::{builtin, display};

macro_rules! displays {
    ($($name:ident: ($raw:expr, $code:expr, $date1904:expr) => $expected:expr;)*) => {
        $(#[test]
        fn $name() {
            // Given a stored value, format code, and workbook epoch.
            let (raw, code, date1904) = ($raw, $code, $date1904);
            // When the bounded formatter renders the cell.
            let actual = display(raw, code, date1904);
            // Then supported formats render exactly; unsupported ones defer to the caller.
            assert_eq!(actual.as_deref(), $expected);
        })*
    };
}

displays! {
    general_preserves_big_integer: ("9007199254740993", "General", false) => Some("9007199254740993");
    general_preserves_exponent: ("1.234567890123456789e-20", "general", false) => Some("1.234567890123456789e-20");
    text_preserves_spelling: ("001.200", "@", false) => Some("001.200");
    integer_rounds_half_up: ("12.5", "0", false) => Some("13");
    negative_rounds_away_from_zero: ("-12.5", "0", false) => Some("-13");
    decimal_pads_zeros: ("12", "0.00", false) => Some("12.00");
    decimal_rounds_exact_tie: ("1.005", "0.00", false) => Some("1.01");
    decimal_retains_source_precision: ("9007199254740993.125", "0.00", false) => Some("9007199254740993.13");
    grouping_retains_big_integer: ("9007199254740993", "#,##0", false) => Some("9,007,199,254,740,993");
    grouping_rounds_across_carry: ("999999.995", "#,##0.00", false) => Some("1,000,000.00");
    grouping_keeps_negative_sign: ("-1234.5", "#,##0.00", false) => Some("-1,234.50");
    percent_scales_exactly: ("0.12345", "0.00%", false) => Some("12.35%");
    percent_rounds_integer: (".125", "0%", false) => Some("13%");
    percent_groups: ("123.456", "#,##0.0%", false) => Some("12,345.6%");
    exponent_input_renders_decimal: ("+1.2345E+3", "0.00", false) => Some("1234.50");
    exponent_input_rounds_tiny: ("5e-3", "0.00", false) => Some("0.01");
    decimal_handles_leading_zeros: ("00012.3000", "0.00", false) => Some("12.30");
    decimal_handles_dot_prefix: ("-.50", "0.00", false) => Some("-0.50");
    decimal_handles_dot_suffix: ("12.", "0.00", false) => Some("12.00");
    zero_omits_negative_sign: ("-0.0001", "0.00", false) => Some("0.00");
    optional_decimals_trim: ("1.20", "0.0##", false) => Some("1.2");
    optional_decimals_omit_dot: ("1.000", "0.##", false) => Some("1");
    mandatory_decimals_remain: ("1.000", "0.00##", false) => Some("1.00");
    zero_with_exponent: ("0e300", "0.00", false) => Some("0.00");
    tiny_finite_value: ("1e-300", "0.00", false) => Some("0.00");
    first_1900_day: ("1", "yyyy-mm-dd", false) => Some("1900-01-01");
    pre_leap_1900_day: ("59", "yyyy-mm-dd", false) => Some("1900-02-28");
    fake_1900_leap_day: ("60", "yyyy-mm-dd", false) => Some("1900-02-29");
    post_leap_1900_day: ("61", "yyyy-mm-dd", false) => Some("1900-03-01");
    first_1904_day: ("0", "yyyy-mm-dd", true) => Some("1904-01-01");
    real_1904_leap_day: ("59", "yyyy-mm-dd", true) => Some("1904-02-29");
    modern_1900_date: ("45292", "yyyy-mm-dd", false) => Some("2024-01-01");
    modern_1904_date: ("43830", "yyyy-mm-dd", true) => Some("2024-01-01");
    leap_2000_day: ("36585", "yyyy-mm-dd", false) => Some("2000-02-29");
    century_2100_march: ("73110", "yyyy-mm-dd", false) => Some("2100-03-01");
    numeric_short_date: ("45292", "m/d/yy", false) => Some("1/1/24");
    padded_short_date: ("45292", "mm-dd-yy", false) => Some("01-01-24");
    month_name_date: ("45292", "d-mmm-yy", false) => Some("1-Jan-24");
    month_day_date: ("45292", "d-mmm", false) => Some("1-Jan");
    month_year_date: ("45292", "mmm-yy", false) => Some("Jan-24");
    datetime_has_month_and_minutes: ("45292.75", "m/d/yy h:mm", false) => Some("1/1/24 18:00");
    noon_time: ("0.5", "h:mm", false) => Some("12:00");
    seconds_time: ("0.0625", "h:mm:ss", false) => Some("1:30:00");
    padded_hour_time: ("0.0625", "hh:mm:ss", false) => Some("01:30:00");
    morning_time: ("0.0625", "h:mm AM/PM", false) => Some("1:30 AM");
    evening_time: ("0.75", "h:mm:ss AM/PM", false) => Some("6:00:00 PM");
    midnight_time: ("0", "h:mm AM/PM", false) => Some("12:00 AM");
    noon_meridiem: ("0.5", "h:mm AM/PM", false) => Some("12:00 PM");
    minute_second_time: ("0.0625", "mm:ss", false) => Some("30:00");
    elapsed_hours: ("2.5", "[h]:mm:ss", false) => Some("60:00:00");
    clock_wraps_day: ("2.5", "h:mm:ss", false) => Some("12:00:00");
    fractions_roll_over_seconds: ("0.9999999", "h:mm:ss", false) => Some("0:00:00");
    fractions_roll_into_fake_leap_day: ("59.9999999", "m/d/yy h:mm", false) => Some("2/29/00 0:00");
    fractions_roll_out_of_fake_leap_day: ("60.9999999", "m/d/yy h:mm", false) => Some("3/1/00 0:00");
    date_only_uses_whole_day: ("59.9999999", "yyyy-mm-dd", false) => Some("1900-02-28");
    upper_1900_date: ("2958465", "yyyy-mm-dd", false) => Some("9999-12-31");
    upper_1904_date: ("2957003", "yyyy-mm-dd", true) => Some("9999-12-31");
    uppercase_date_code: ("45292", "YYYY-MM-DD", false) => Some("2024-01-01");
    unsupported_zero_calendar_day: ("0", "yyyy-mm-dd", false) => None;
    unsupported_negative_date: ("-1", "yyyy-mm-dd", false) => None;
    unsupported_negative_time: ("-0.5", "h:mm", true) => None;
    unsupported_date_range: ("2958466", "yyyy-mm-dd", false) => None;
    unsupported_1904_date_range: ("2957004", "yyyy-mm-dd", true) => None;
    unsupported_date_rollover_range: ("2958465.9999999", "m/d/yy h:mm", false) => None;
    supported_colors: ("12", "[Red]0", false) => Some("12");
    supported_locale: ("45292", "[$-409]m/d/yy", false) => Some("1/1/24");
    supported_sections_positive: ("12", "0;[Red]-0", false) => Some("12");
    supported_sections_negative: ("-12", "0;[Red]-0", false) => Some("-12");
    supported_sections_parentheses_negative: ("-1234.5", "#,##0.00;(#,##0.00);\"-\"", false) => Some("(1,234.50)");
    supported_sections_zero_literal: ("0", "#,##0.00;(#,##0.00);\"-\"", false) => Some("-");
    supported_pure_time_with_datetime_format: ("0.5", "m/d/yy h:mm", false) => Some("1/0/00 12:00");
    unsupported_conditions: ("12", "[>0]0", false) => None;
    unsupported_currency: ("12", "$0.00", false) => None;
    unsupported_fraction: ("12.5", "# ?/?", false) => None;
    unsupported_scale_comma: ("12000", "0,", false) => None;
    unsupported_optional_then_mandatory: ("1.23", "0.#0", false) => None;
    unsupported_scientific_code: ("123", "0.00E+00", false) => None;
    unsupported_literal: ("123", "0\" kg\"", false) => None;
    unsupported_trailing_space: ("123", "0 ", false) => None;
    unsupported_empty_code: ("123", "", false) => None;
    invalid_nan: ("NaN", "0.00", false) => None;
    invalid_infinity: ("inf", "yyyy-mm-dd", false) => None;
    invalid_number: ("nope", "0", false) => None;
    invalid_double_sign: ("--1", "0", false) => None;
    invalid_extra_dot: ("1.2.3", "0", false) => None;
    invalid_empty_number: ("", "0", false) => None;
}

#[test]
fn builtin_codes_match_supported_standard_ids() {
    let expected = [
        (0, "General"),
        (1, "0"),
        (2, "0.00"),
        (3, "#,##0"),
        (4, "#,##0.00"),
        (9, "0%"),
        (10, "0.00%"),
        (14, "mm-dd-yy"),
        (15, "d-mmm-yy"),
        (16, "d-mmm"),
        (17, "mmm-yy"),
        (18, "h:mm AM/PM"),
        (19, "h:mm:ss AM/PM"),
        (20, "h:mm"),
        (21, "h:mm:ss"),
        (22, "m/d/yy h:mm"),
        (45, "mm:ss"),
        (46, "[h]:mm:ss"),
        (49, "@"),
    ];
    for (id, code) in expected {
        let actual = builtin(id);
        assert_eq!(actual, Some(code), "built-in {id}");
    }
}

#[test]
fn unsupported_builtin_ids_defer_to_caller() {
    for id in [5, 11, 12, 13, 23, 27, 37, 38, 47, 48, 164, u32::MAX] {
        let actual = builtin(id);
        assert_eq!(actual, None, "built-in {id}");
    }
}

#[test]
fn long_values_and_precision_requests_are_bounded() {
    for (raw, code) in [
        ("1".repeat(1024), "0".into()),
        ("1".into(), format!("0.{}", "0".repeat(1000))),
    ] {
        let actual = display(&raw, &code, false);
        assert_eq!(actual, None);
    }
}
