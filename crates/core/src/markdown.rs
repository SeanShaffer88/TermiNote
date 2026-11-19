use pulldown_cmark::{
    CowStr, Event, Options, Parser, Tag, TagEnd, html,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MarkdownFormat {
    Bold,
    Italic,
    Strike,
    Code,
    Heading,
    Link,
    Quote,
    Checklist,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkdownEdit {
    pub text: String,
    pub start: usize,
    pub end: usize,
}

pub fn strip_list_markers(text: &str) -> String {
    text.lines()
        .map(strip_one_list_marker)
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn to_numbered_list(text: &str) -> String {
    let lines: Vec<&str> = text.split('\n').collect();
    let nonempty: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|line| !line.trim().is_empty())
        .collect();
    if !nonempty.is_empty() && nonempty.iter().all(|line| has_number_marker(line)) {
        return strip_list_markers(text);
    }
    let mut number = 0;
    lines
        .iter()
        .map(|line| {
            let stripped = strip_one_list_marker(line);
            if !stripped.trim().is_empty() {
                number += 1;
                format!("{number}. {stripped}")
            } else if has_any_list_marker(line) {
                number += 1;
                format!("{number}.")
            } else {
                (*line).to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn to_bullet_list(text: &str) -> String {
    let lines: Vec<&str> = text.split('\n').collect();
    let nonempty: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|line| !line.trim().is_empty())
        .collect();
    if !nonempty.is_empty() && nonempty.iter().all(|line| has_bullet_marker(line)) {
        return strip_list_markers(text);
    }
    lines
        .iter()
        .map(|line| {
            let stripped = strip_one_list_marker(line);
            if !stripped.trim().is_empty() {
                format!("• {stripped}")
            } else if has_any_list_marker(line) {
                "•".into()
            } else {
                (*line).to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn leading_marker_end(line: &str) -> Option<usize> {
    let trimmed = line.trim_start();
    let offset = line.len() - trimmed.len();
    if let Some(rest) = trimmed.strip_prefix('•') {
        if rest.chars().next().is_none_or(char::is_whitespace) {
            return Some(offset + 1 + rest.len() - rest.trim_start().len());
        }
    }
    if let Some(rest) = trimmed.strip_prefix('-').or_else(|| trimmed.strip_prefix('*')) {
        if rest.chars().next().is_none_or(char::is_whitespace) {
            return Some(offset + 1 + rest.len() - rest.trim_start().len());
        }
    }
    let digits = trimmed.chars().take_while(|ch| ch.is_ascii_digit()).count();
    if digits > 0 {
        let bytes = trimmed.as_bytes();
        if bytes.get(digits).is_some_and(|byte| *byte == b'.' || *byte == b')') {
            let after = digits + 1;
            if after == trimmed.len()
                || trimmed[after..]
                    .chars()
                    .next()
                    .is_some_and(char::is_whitespace)
            {
                let spaces = trimmed[after..].len() - trimmed[after..].trim_start().len();
                return Some(offset + after + spaces);
            }
        }
    }
    None
}

fn strip_one_list_marker(line: &str) -> String {
    match leading_marker_end(line) {
        Some(end) => line[end..].to_string(),
        None => line.to_string(),
    }
}

fn has_any_list_marker(line: &str) -> bool {
    leading_marker_end(line).is_some()
}

fn has_number_marker(line: &str) -> bool {
    let trimmed = line.trim_start();
    let digits = trimmed.chars().take_while(|ch| ch.is_ascii_digit()).count();
    digits > 0
        && trimmed
            .as_bytes()
            .get(digits)
            .is_some_and(|byte| *byte == b'.' || *byte == b')')
        && (digits + 1 == trimmed.len()
            || trimmed[digits + 1..].starts_with(char::is_whitespace))
}

fn has_bullet_marker(line: &str) -> bool {
    let trimmed = line.trim_start();
    ["•", "-", "*"].iter().any(|marker| {
        trimmed.strip_prefix(marker).is_some_and(|rest| {
            rest.is_empty() || rest.starts_with(char::is_whitespace)
        })
    })
}

pub fn apply_format(text: &str, start: usize, end: usize, format: MarkdownFormat) -> MarkdownEdit {
    let mut start = floor_char_boundary(text, start.min(text.len()));
    let mut end = floor_char_boundary(text, end.min(text.len()));
    if end < start {
        std::mem::swap(&mut start, &mut end);
    }
    match format {
        MarkdownFormat::Bold => wrap(text, start, end, "**"),
        MarkdownFormat::Italic => wrap(text, start, end, "*"),
        MarkdownFormat::Strike => wrap(text, start, end, "~~"),
        MarkdownFormat::Code => {
            let selected = &text[start..end];
            if selected.contains('\n') {
                let (line_start, line_end) = whole_lines(text, start, end);
                let selected = &text[line_start..line_end];
                let formatted = if selected.starts_with("```") {
                    selected
                        .strip_prefix("```")
                        .unwrap_or(selected)
                        .strip_suffix("```")
                        .unwrap_or(selected)
                        .trim_matches('\n')
                        .to_string()
                } else {
                    format!("```\n{selected}\n```")
                };
                replace_range(text, line_start, line_end, &formatted, line_start, line_start + formatted.len())
            } else {
                wrap(text, start, end, "`")
            }
        }
        MarkdownFormat::Link => {
            let selected = &text[start..end];
            if selected.starts_with('[') && selected.contains("](") && selected.ends_with(')') {
                let label = selected
                    .strip_prefix('[')
                    .and_then(|value| value.split_once("]("))
                    .map(|(label, _)| label)
                    .unwrap_or(selected);
                replace_range(text, start, end, label, start, start + label.len())
            } else {
                let linked = format!("[{selected}](url)");
                let url_start = start + selected.len() + 3;
                replace_range(text, start, end, &linked, url_start, url_start + 3)
            }
        }
        MarkdownFormat::Heading => cycle_heading(text, start, end),
        MarkdownFormat::Quote => line_prefix(text, start, end, |line| {
            line.strip_prefix("> ")
                .map(str::to_string)
                .unwrap_or_else(|| format!("> {line}"))
        }),
        MarkdownFormat::Checklist => line_prefix(text, start, end, |line| {
            if let Some(rest) = checklist_body(line) {
                return rest.to_string();
            }
            let stripped = strip_one_list_marker(line);
            if stripped.trim().is_empty() {
                stripped
            } else {
                format!("- [ ] {stripped}")
            }
        }),
    }
}

fn floor_char_boundary(text: &str, mut index: usize) -> usize {
    while !text.is_char_boundary(index) {
        index -= 1;
    }
    index
}

fn replace_range(
    text: &str,
    start: usize,
    end: usize,
    replacement: &str,
    selection_start: usize,
    selection_end: usize,
) -> MarkdownEdit {
    let mut result = String::with_capacity(text.len() + replacement.len());
    result.push_str(&text[..start]);
    result.push_str(replacement);
    result.push_str(&text[end..]);
    MarkdownEdit {
        text: result,
        start: selection_start,
        end: selection_end,
    }
}

fn wrap(text: &str, start: usize, end: usize, marker: &str) -> MarkdownEdit {
    let selected = &text[start..end];
    let marker_len = marker.len();
    if selected.len() >= marker_len * 2
        && selected.starts_with(marker)
        && selected.ends_with(marker)
    {
        let inner = &selected[marker_len..selected.len() - marker_len];
        return replace_range(text, start, end, inner, start, start + inner.len());
    }
    if start >= marker_len
        && end + marker_len <= text.len()
        && &text[start - marker_len..start] == marker
        && &text[end..end + marker_len] == marker
    {
        let mut result = text.to_string();
        result.replace_range(end..end + marker_len, "");
        result.replace_range(start - marker_len..start, "");
        return MarkdownEdit {
            text: result,
            start: start - marker_len,
            end: end - marker_len,
        };
    }
    let wrapped = format!("{marker}{selected}{marker}");
    let selection_start = if selected.is_empty() {
        start + marker_len
    } else {
        start
    };
    let selection_end = if selected.is_empty() {
        selection_start
    } else {
        start + wrapped.len()
    };
    replace_range(text, start, end, &wrapped, selection_start, selection_end)
}

fn whole_lines(text: &str, start: usize, end: usize) -> (usize, usize) {
    let line_start = text[..start].rfind('\n').map_or(0, |index| index + 1);
    let mut line_end = end;
    if line_end > line_start && text.as_bytes().get(line_end - 1) != Some(&b'\n') {
        line_end = text[line_end..]
            .find('\n')
            .map_or(text.len(), |offset| line_end + offset);
    }
    (line_start, line_end)
}

fn line_prefix(
    text: &str,
    start: usize,
    end: usize,
    toggle: impl Fn(&str) -> String,
) -> MarkdownEdit {
    let (line_start, line_end) = whole_lines(text, start, end);
    let formatted = text[line_start..line_end]
        .split('\n')
        .map(|line| {
            if line.trim().is_empty() {
                line.to_string()
            } else {
                toggle(line)
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    let end = line_start + formatted.len();
    replace_range(text, line_start, line_end, &formatted, line_start, end)
}

fn checklist_body(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "] {
        if let Some(body) = trimmed.strip_prefix(marker) {
            return Some(body);
        }
    }
    None
}

fn cycle_heading(text: &str, start: usize, end: usize) -> MarkdownEdit {
    let (line_start, line_end) = whole_lines(text, start, end);
    let segment = &text[line_start..line_end];
    let current = segment
        .lines()
        .find(|line| !line.trim().is_empty())
        .map(|line| {
            let trimmed = line.trim_start();
            trimmed.chars().take_while(|ch| *ch == '#').count()
        })
        .unwrap_or(0);
    let next = if current >= 3 { 0 } else { current + 1 };
    let prefix = "#".repeat(next);
    let formatted = segment
        .split('\n')
        .map(|line| {
            if line.trim().is_empty() {
                return line.to_string();
            }
            let trimmed = line.trim_start();
            let hashes = trimmed.chars().take_while(|ch| *ch == '#').count();
            let body = if hashes > 0 && trimmed.as_bytes().get(hashes) == Some(&b' ') {
                &trimmed[hashes + 1..]
            } else {
                line
            };
            if next == 0 {
                body.to_string()
            } else {
                format!("{prefix} {body}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    let new_end = line_start + formatted.len();
    replace_range(text, line_start, line_end, &formatted, line_start, new_end)
}

pub fn markdown_html(text: &str) -> String {
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_FOOTNOTES;
    let parser = Parser::new_ext(text, options).map(|event| match event {
        Event::Start(Tag::Image { .. }) => {
            Event::Html(CowStr::from("<span class=\"img\">[Image: "))
        }
        Event::End(TagEnd::Image) => Event::Html(CowStr::from("]</span>")),
        Event::Start(Tag::Link {
            link_type,
            dest_url,
            title,
            id,
        }) if !safe_link(&dest_url) => Event::Start(Tag::Link {
            link_type,
            dest_url: CowStr::from("#"),
            title,
            id,
        }),
        Event::Html(value) | Event::InlineHtml(value) => Event::Text(value),
        other => other,
    });
    let mut output = String::new();
    html::push_html(&mut output, parser);
    output
}

fn safe_link(raw: &str) -> bool {
    let Some((scheme, rest)) = raw.split_once(':') else {
        return false;
    };
    match scheme.to_ascii_lowercase().as_str() {
        "http" | "https" => {
            rest.starts_with("//")
                && !rest[2..].split('/').next().unwrap_or("").is_empty()
                && !rest[2..].split('/').next().unwrap_or("").contains('@')
        }
        "mailto" => !rest.trim().is_empty(),
        _ => false,
    }
}

pub fn render_markdown_plain(text: &str) -> String {
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_FOOTNOTES;
    let mut output = String::new();
    let mut list_numbers = Vec::<Option<u64>>::new();
    let mut pending_break = false;
    for event in Parser::new_ext(text, options) {
        match event {
            Event::Start(Tag::Paragraph) | Event::End(TagEnd::Paragraph) => pending_break = true,
            Event::Start(Tag::Heading { level, .. }) => {
                if !output.is_empty() && !output.ends_with('\n') {
                    output.push('\n');
                }
                output.push_str(&"#".repeat(level as usize));
                output.push(' ');
            }
            Event::End(TagEnd::Heading(_)) => output.push('\n'),
            Event::Start(Tag::List(start)) => list_numbers.push(start),
            Event::End(TagEnd::List(_)) => {
                list_numbers.pop();
                output.push('\n');
            }
            Event::Start(Tag::Item) => {
                if let Some(Some(number)) = list_numbers.last_mut() {
                    output.push_str(&format!("{number}. "));
                    *number = number.saturating_add(1);
                } else {
                    output.push_str("• ");
                }
            }
            Event::End(TagEnd::Item) => output.push('\n'),
            Event::TaskListMarker(checked) => {
                output.push_str(if checked { "[x] " } else { "[ ] " })
            }
            Event::Start(Tag::BlockQuote(_)) => output.push_str("> "),
            Event::End(TagEnd::BlockQuote(_)) => output.push('\n'),
            Event::Start(Tag::CodeBlock(_)) => {
                if !output.is_empty() && !output.ends_with('\n') {
                    output.push('\n');
                }
            }
            Event::End(TagEnd::CodeBlock) => output.push('\n'),
            Event::Start(Tag::Image { .. }) => output.push_str("[Image: "),
            Event::End(TagEnd::Image) => output.push(']'),
            Event::Text(value) | Event::Code(value) => {
                if pending_break && !output.is_empty() && !output.ends_with('\n') {
                    output.push('\n');
                }
                pending_break = false;
                output.push_str(&value);
            }
            Event::SoftBreak | Event::HardBreak => output.push('\n'),
            Event::Rule => output.push_str("---\n"),
            _ => {}
        }
    }
    output.trim_end_matches('\n').to_string()
}

pub fn note_to_html(title: &str, body: &str) -> String {
    let safe_title = title
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;");
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <title>{safe_title}</title><style>\
         body{{background:#0A0A0A;color:#fff;font-family:Consolas,\"Courier New\",monospace;\
         max-width:760px;margin:2em auto;padding:0 1em;line-height:1.6}}\
         a{{color:#FF5A66}}code{{background:#2A2A2A;color:#FF5A66;padding:0 .3em}}\
         pre{{background:#1E1E1E;padding:1em;overflow:auto}}pre code{{background:none;padding:0}}\
         blockquote{{border-left:3px solid #E81123;margin-left:0;padding-left:1em;color:#ddd}}\
         table{{border-collapse:collapse}}td,th{{border:1px solid #2C2C2C;padding:.3em .7em}}\
         th{{background:#2A2A2A}}hr{{border:0;border-top:1px solid #4A4A4A}}\
         .img{{color:#FF5A66}}</style></head><body><h1>{safe_title}</h1>{}</body></html>",
        markdown_html(body)
    )
}

pub fn insert_toc(text: &str) -> String {
    let mut headings = Vec::new();
    let mut in_code = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code {
            continue;
        }
        let trimmed = line.trim_start();
        let level = trimmed.chars().take_while(|ch| *ch == '#').count();
        if (1..=6).contains(&level) && trimmed.as_bytes().get(level) == Some(&b' ') {
            let title = trimmed[level + 1..].trim().to_string();
            if !title.is_empty() {
                headings.push((level, title));
            }
        }
    }
    if headings.is_empty() {
        return text.to_string();
    }
    let toc = headings
        .iter()
        .map(|(level, title)| {
            format!(
                "{}- [{}](#{})",
                "  ".repeat(level - 1),
                title,
                anchor(title)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let block = format!("<!-- TOC -->\n{toc}\n<!-- /TOC -->");
    if let Some(start) = text.find("<!-- TOC -->")
        && let Some(end) = text[start..].find("<!-- /TOC -->")
    {
        let end = start + end + "<!-- /TOC -->".len();
        return format!("{}{}{}", &text[..start], block, &text[end..]);
    }
    format!("{block}\n\n{text}")
}

fn anchor(value: &str) -> String {
    let mut slug = String::new();
    let mut needs_dash = false;
    for ch in value.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            if needs_dash && !slug.is_empty() {
                slug.push('-');
            }
            slug.push(ch);
            needs_dash = false;
        } else if ch.is_ascii_whitespace() || ch == '-' {
            needs_dash = true;
        }
    }
    slug
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_formatting_toggles_and_preserves_selection() {
        let bold = apply_format("hello world", 6, 11, MarkdownFormat::Bold);
        assert_eq!(bold.text, "hello **world**");
        assert_eq!(&bold.text[bold.start..bold.end], "**world**");
        let plain = apply_format(&bold.text, 6, 15, MarkdownFormat::Bold);
        assert_eq!(plain.text, "hello world");
    }

    #[test]
    fn lists_toggle_back_to_plain_text() {
        assert_eq!(to_numbered_list("One\n\nTwo"), "1. One\n\n2. Two");
        assert_eq!(to_numbered_list("1. One\n2. Two"), "One\nTwo");
        assert_eq!(to_bullet_list("One\nTwo"), "• One\n• Two");
        assert_eq!(strip_list_markers("- One\n2. Two"), "One\nTwo");
    }

    #[test]
    fn preview_escapes_raw_html_and_does_not_load_remote_images() {
        let html = markdown_html("<script>alert(1)</script>\n\n![alt](https://example.com/a.png)");
        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;script&gt;"));
        assert!(html.contains("[Image: alt]"));
        assert!(!html.contains("<img"));
    }

    #[test]
    fn toc_rebuilds_existing_block() {
        let body = "<!-- TOC -->\nold\n<!-- /TOC -->\n\n# One\n## Two";
        let result = insert_toc(body);
        assert!(result.contains("- [One](#one)"));
        assert!(result.contains("  - [Two](#two)"));
        assert!(!result.contains("\nold\n"));
    }
}
