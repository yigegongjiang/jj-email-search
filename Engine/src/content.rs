use anyhow::{Context, Result};
use mail_parser::{MessageParser, MimeHeaders};
use serde::Serialize;
use std::sync::LazyLock;
static REPLY: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"(?i)^(on .{1,400}wrote\s*:|在.{1,400}(写道|寫道)\s*[:：]|.{1,200}于.{1,200}写道\s*[:：])$").unwrap()
});
static ORIGINAL: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"(?i)^[-_]{3,}\s*(original message|原始邮件|原始郵件|forwarded message|转发邮件).{0,30}[-_]{3,}$").unwrap()
});
// Forwarded content is the message's own payload; stripping it would make it unsearchable.
static FORWARD_SUBJECT: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)^\s*(fwd?|转发|轉寄|転送)\s*[:：]").unwrap());
static FORWARD_SEPARATOR: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(
        r"(?im)^\s*[-_]{3,}\s*(forwarded message|转发的邮件|轉寄的郵件|転送されたメッセージ)",
    )
    .unwrap()
});
#[derive(Serialize)]
pub struct Attachment {
    pub index: u32,
    pub name: String,
    pub size: usize,
    pub available: bool,
    /// Image MIME type or image file extension; the App still decodes before rendering.
    pub image: bool,
}
#[derive(Serialize)]
pub struct Preview {
    pub subject: String,
    pub sender: String,
    pub recipients: String,
    pub body: String,
    pub own_body: String,
    pub quoted: bool,
    pub attachments: Vec<Attachment>,
    pub complete: bool,
}
pub fn strip_text(text: &str, mut reply: bool) -> String {
    let lines: Vec<_> = text.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let s = lines[i].trim();
        if !out.is_empty() && ORIGINAL.is_match(s) {
            break;
        }
        if reply && s.starts_with('>') {
            i += 1;
            continue;
        }
        if REPLY.is_match(s)
            && lines
                .get(i + 1)
                .is_some_and(|n| n.trim().is_empty() || n.trim().starts_with('>'))
        {
            reply = true;
            i += 1;
            continue;
        }
        // Outlook's header block is removed only when all four header labels exist.
        if !out.is_empty()
            && (s.starts_with("From:") || s.starts_with("发件人:") || s.starts_with("发件人："))
        {
            let next = lines[i..lines.len().min(i + 10)].join("\n");
            if (next.contains("Sent:") || next.contains("发送时间"))
                && (next.contains("To:") || next.contains("收件人"))
                && (next.contains("Subject:") || next.contains("主题"))
            {
                break;
            }
        }
        out.push(lines[i]);
        i += 1;
    }
    out.join("\n").trim().to_owned()
}
pub fn own_text(message: &mail_parser::Message<'_>) -> String {
    let full = message.body_text(0).unwrap_or_default();
    if message
        .subject()
        .is_some_and(|s| FORWARD_SUBJECT.is_match(s))
        || FORWARD_SEPARATOR.is_match(&full)
    {
        return full.trim().to_owned();
    }
    let reply = !matches!(message.in_reply_to(), mail_parser::HeaderValue::Empty)
        || !matches!(message.references(), mail_parser::HeaderValue::Empty);
    // Structural HTML quote removal keeps new inline responses outside quote nodes.
    if (message.text_body_count() == 0
        || message
            .text_part(0)
            .is_some_and(|p| matches!(p.body, mail_parser::PartType::Html(_))))
        && let Some(html) = message.body_html(0)
    {
        let mut dom = scraper::Html::parse_document(&html);
        let selector = scraper::Selector::parse(if reply {
            "blockquote, .gmail_quote, .yahoo_quoted, .moz-cite-prefix"
        } else {
            "blockquote[type=cite], .gmail_quote, .yahoo_quoted, .moz-cite-prefix"
        })
        .unwrap();
        let ids: Vec<_> = dom.select(&selector).map(|e| e.id()).collect();
        let removed = !ids.is_empty();
        for id in ids {
            if let Some(mut n) = dom.tree.get_mut(id) {
                n.detach();
            }
        }
        let html = dom.html();
        let raw = format!("Content-Type: text/html; charset=utf-8\r\n\r\n{html}");
        if let Some(m) = MessageParser::default().parse(raw.as_bytes())
            && let Some(t) = m.body_text(0)
            && (removed || !t.trim().is_empty())
        {
            return strip_text(&t, reply);
        }
    }
    strip_text(&full, reply)
}
pub fn addresses(a: Option<&mail_parser::Address<'_>>) -> String {
    a.map(|a| {
        a.iter()
            .map(|v| match (&v.name, &v.address) {
                (Some(n), Some(a)) => format!("{n} <{a}>"),
                (_, Some(a)) => a.to_string(),
                (Some(n), _) => n.to_string(),
                _ => String::new(),
            })
            .collect::<Vec<_>>()
            .join(", ")
    })
    .unwrap_or_default()
}
pub fn preview(raw: &[u8]) -> Result<Preview> {
    let message = MessageParser::default()
        .parse(raw)
        .context("Cannot parse stored MIME message")?;
    let body = message.body_text(0).unwrap_or_default().into_owned();
    let own_body = own_text(&message);
    let attachments = message
        .attachments()
        .enumerate()
        .map(|(i, a)| Attachment {
            index: i as u32,
            name: a.attachment_name().unwrap_or("attachment").into(),
            size: a.contents().len(),
            available: attachment_available(a),
            image: is_image(a),
        })
        .collect();
    Ok(Preview {
        subject: message.subject().unwrap_or("(无主题)").into(),
        sender: addresses(message.from()),
        recipients: addresses(message.to()),
        quoted: own_body != body.trim(),
        body,
        own_body,
        attachments,
        complete: !message.parts.iter().any(|p| p.is_encoding_problem),
    })
}

fn is_image(part: &mail_parser::MessagePart<'_>) -> bool {
    // Many mailers send photos as application/octet-stream; the file extension decides then.
    part.content_type()
        .is_some_and(|t| t.c_type.eq_ignore_ascii_case("image"))
        || part.attachment_name().is_some_and(|n| {
            n.rsplit_once('.').is_some_and(|(_, e)| {
                ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"]
                    .iter()
                    .any(|x| e.eq_ignore_ascii_case(x))
            })
        })
}

pub fn attachment_available(part: &mail_parser::MessagePart<'_>) -> bool {
    !part.is_encoding_problem
        && part.content_type().is_none_or(|t| {
            !(t.c_type.eq_ignore_ascii_case("text")
                && t.c_subtype
                    .as_deref()
                    .is_some_and(|s| s.eq_ignore_ascii_case("x-moz-deleted")))
                && !(t.c_type.eq_ignore_ascii_case("message")
                    && t.c_subtype
                        .as_deref()
                        .is_some_and(|s| s.eq_ignore_ascii_case("external-body")))
        })
}
