//! A deliberately small, tolerant JSON reader/writer.
//!
//! It covers the shapes TermiNote writes (null, bool, numbers,
//! strings, arrays and objects) and nothing more. Anything malformed
//! is reported as `None` by the parser rather than crashing: a
//! corrupt data file must never strand the user.
//!
//! Numbers are kept as `f64`, which is exact for every value
//! TermiNote stores (ids and unix-second timestamps are far below
//! 2^53).

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

/// Parse a complete JSON document. Trailing non-whitespace makes the
/// document invalid.
pub fn parse(text: &str) -> Option<Json> {
    let mut parser = Parser::new(text);
    let value = parser.value()?;
    parser.skip_ws();
    if parser.pos != parser.bytes.len() {
        return None;
    }
    Some(value)
}

/// Serialise a value to compact JSON text.
pub fn stringify(value: &Json) -> String {
    let mut out = String::new();
    write_value(value, &mut out);
    out
}

fn write_value(value: &Json, out: &mut String) {
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(true) => out.push_str("true"),
        Json::Bool(false) => out.push_str("false"),
        Json::Num(n) => {
            if n.is_finite() && n.fract() == 0.0 && n.abs() < 9_007_199_254_740_992.0 {
                out.push_str(&(*n as i64).to_string());
            } else if n.is_finite() {
                out.push_str(&n.to_string());
            } else {
                out.push_str("null");
            }
        }
        Json::Str(s) => {
            out.push('"');
            out.push_str(&esc(s));
            out.push('"');
        }
        Json::Arr(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Json::Obj(fields) => {
            out.push('{');
            for (i, (key, val)) in fields.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push('"');
                out.push_str(&esc(key));
                out.push_str("\":");
                write_value(val, out);
            }
            out.push('}');
        }
    }
}

/// Look up `key` in an object's field list.
pub fn get<'a>(fields: &'a [(String, Json)], key: &str) -> Option<&'a Json> {
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

pub fn as_u64(value: &Json) -> Option<u64> {
    match value {
        Json::Num(n) if *n >= 0.0 => Some(*n as u64),
        _ => None,
    }
}

pub fn as_i64(value: &Json) -> Option<i64> {
    match value {
        Json::Num(n) => Some(*n as i64),
        _ => None,
    }
}

pub fn as_bool(value: &Json) -> Option<bool> {
    match value {
        Json::Bool(b) => Some(*b),
        _ => None,
    }
}

pub fn as_str(value: &Json) -> Option<&str> {
    match value {
        Json::Str(s) => Some(s),
        _ => None,
    }
}

pub fn as_arr(value: &Json) -> Option<&Vec<Json>> {
    match value {
        Json::Arr(items) => Some(items),
        _ => None,
    }
}

pub fn as_obj(value: &Json) -> Option<&Vec<(String, Json)>> {
    match value {
        Json::Obj(fields) => Some(fields),
        _ => None,
    }
}

pub fn as_str_arr(value: &Json) -> Vec<String> {
    match as_arr(value) {
        Some(items) => items.iter().filter_map(as_str).map(str::to_owned).collect(),
        None => Vec::new(),
    }
}

/// Escape a string for inclusion inside JSON quotes (without the
/// surrounding quotes themselves).
pub fn esc(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{0008}' => out.push_str("\\b"),
            '\u{000C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                use std::fmt::Write as _;
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            bytes: text.as_bytes(),
            pos: 0,
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn value(&mut self) -> Option<Json> {
        self.skip_ws();
        match self.peek()? {
            b'{' => {
                self.pos += 1;
                let mut fields = Vec::new();
                self.skip_ws();
                if self.peek() == Some(b'}') {
                    self.pos += 1;
                    return Some(Json::Obj(fields));
                }
                loop {
                    let key = match self.value()? {
                        Json::Str(s) => s,
                        _ => return None,
                    };
                    self.skip_ws();
                    if self.peek() != Some(b':') {
                        return None;
                    }
                    self.pos += 1;
                    let val = self.value()?;
                    fields.push((key, val));
                    self.skip_ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b'}') => {
                            self.pos += 1;
                            return Some(Json::Obj(fields));
                        }
                        _ => return None,
                    }
                }
            }
            b'[' => {
                self.pos += 1;
                let mut items = Vec::new();
                self.skip_ws();
                if self.peek() == Some(b']') {
                    self.pos += 1;
                    return Some(Json::Arr(items));
                }
                loop {
                    items.push(self.value()?);
                    self.skip_ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b']') => {
                            self.pos += 1;
                            return Some(Json::Arr(items));
                        }
                        _ => return None,
                    }
                }
            }
            b'"' => self.string().map(Json::Str),
            b'-' | b'0'..=b'9' => self.number().map(Json::Num),
            _ => {
                let start = self.pos;
                while matches!(self.peek(), Some(b'a'..=b'z')) {
                    self.pos += 1;
                }
                match &self.bytes[start..self.pos] {
                    b"true" => Some(Json::Bool(true)),
                    b"false" => Some(Json::Bool(false)),
                    b"null" => Some(Json::Null),
                    _ => None,
                }
            }
        }
    }

    fn hex4(&mut self) -> Option<u32> {
        let hex = self.bytes.get(self.pos..self.pos + 4)?;
        let code = u32::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?;
        self.pos += 4;
        Some(code)
    }

    fn string(&mut self) -> Option<String> {
        if self.peek() != Some(b'"') {
            return None;
        }
        self.pos += 1;
        let mut out = String::new();
        loop {
            let byte = self.peek()?;
            self.pos += 1;
            match byte {
                b'"' => return Some(out),
                b'\\' => {
                    let e = self.peek()?;
                    self.pos += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'u' => {
                            let code = self.hex4()?;
                            if (0xD800..0xDC00).contains(&code) {
                                // High surrogate: a low surrogate should follow.
                                if self.peek() == Some(b'\\') {
                                    self.pos += 1;
                                    if self.peek() == Some(b'u') {
                                        self.pos += 1;
                                        let low = self.hex4()?;
                                        if (0xDC00..0xE000).contains(&low) {
                                            let combined =
                                                0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                                            out.push(
                                                char::from_u32(combined).unwrap_or('\u{FFFD}'),
                                            );
                                        } else {
                                            out.push('\u{FFFD}');
                                            out.push(char::from_u32(low).unwrap_or('\u{FFFD}'));
                                        }
                                    } else {
                                        return None;
                                    }
                                } else {
                                    out.push('\u{FFFD}');
                                }
                            } else {
                                out.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
                            }
                        }
                        _ => return None,
                    }
                }
                _ => {
                    let start = self.pos - 1;
                    let len = utf8_len(byte);
                    let end = start + len;
                    let slice = self.bytes.get(start..end)?;
                    out.push_str(std::str::from_utf8(slice).ok()?);
                    self.pos = end;
                }
            }
        }
    }

    fn number(&mut self) -> Option<f64> {
        let start = self.pos;
        while matches!(
            self.peek(),
            Some(b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')
        ) {
            self.pos += 1;
        }
        std::str::from_utf8(&self.bytes[start..self.pos])
            .ok()?
            .parse()
            .ok()
    }
}

fn utf8_len(first: u8) -> usize {
    if first < 0x80 {
        1
    } else if first >> 5 == 0b110 {
        2
    } else if first >> 4 == 0b1110 {
        3
    } else {
        4
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_all_shapes() {
        let value = Json::Obj(vec![
            ("title".into(), Json::Str("Hello \"world\"\n".into())),
            ("count".into(), Json::Num(42.0)),
            ("ratio".into(), Json::Num(1.5)),
            ("pinned".into(), Json::Bool(true)),
            ("nothing".into(), Json::Null),
            (
                "tags".into(),
                Json::Arr(vec![Json::Str("a".into()), Json::Str("b".into())]),
            ),
            (
                "nested".into(),
                Json::Obj(vec![("x".into(), Json::Num(-3.0))]),
            ),
        ]);
        let text = stringify(&value);
        assert_eq!(parse(&text), Some(value));
    }

    #[test]
    fn parses_null_bool_and_numbers() {
        assert_eq!(parse("null"), Some(Json::Null));
        assert_eq!(parse(" true "), Some(Json::Bool(true)));
        assert_eq!(parse("false"), Some(Json::Bool(false)));
        assert_eq!(parse("-12.5e2"), Some(Json::Num(-1250.0)));
        assert_eq!(parse("[]"), Some(Json::Arr(Vec::new())));
        assert_eq!(parse("{}"), Some(Json::Obj(Vec::new())));
    }

    #[test]
    fn rejects_garbage_and_trailing_text() {
        assert_eq!(parse(""), None);
        assert_eq!(parse("{oops"), None);
        assert_eq!(parse("[1,]"), None);
        assert_eq!(parse("1 2"), None);
        assert_eq!(parse("nul"), None);
    }

    #[test]
    fn unicode_escapes_and_surrogates() {
        assert_eq!(parse(r#""Aé""#), Some(Json::Str("Aé".into())));
        assert_eq!(parse(r#""\uD83D\uDE00""#), Some(Json::Str("😀".into())));
        let text = stringify(&Json::Str("tab\tand \"quote\"".into()));
        assert_eq!(parse(&text), Some(Json::Str("tab\tand \"quote\"".into())));
    }

    #[test]
    fn helpers_read_fields() {
        let value = parse(r#"{"id":7,"name":"n","on":true,"tags":["x","y"]}"#).unwrap();
        let fields = as_obj(&value).unwrap();
        assert_eq!(as_u64(get(fields, "id").unwrap()), Some(7));
        assert_eq!(as_str(get(fields, "name").unwrap()), Some("n"));
        assert_eq!(as_bool(get(fields, "on").unwrap()), Some(true));
        assert_eq!(
            as_str_arr(get(fields, "tags").unwrap()),
            vec!["x".to_string(), "y".to_string()]
        );
        assert_eq!(get(fields, "missing"), None);
    }
}
