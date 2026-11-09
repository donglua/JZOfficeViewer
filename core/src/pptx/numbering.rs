pub(super) fn format(number: u32, scheme: &str) -> Option<String> {
    crate::numbering::format_scheme(number, scheme)
}
