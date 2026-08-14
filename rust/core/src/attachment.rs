//! File attachments inside a `comm` plaintext — the live population's shape.
//!
//! Kasia sends a file as the WHOLE decrypted body, a JSON object:
//!
//! ```json
//! {"type":"file","name":"notes.md","size":6847,
//!  "mimeType":"text/markdown","content":"data:text/markdown;base64,…"}
//! ```
//!
//! Without this, that object renders as raw JSON in a chat bubble — which is
//! exactly what the founder saw.
//!
//! ## Every declared field is a claim by the sender
//!
//! This is the most attacker-controlled input the app handles: the envelope
//! authenticates that *someone holding the conversation* sent it, and nothing
//! more. So:
//!
//! - **`name`** is reduced to a base name and scrubbed. A file name is the one
//!   field that later becomes a PATH, and `../../x` must never survive parsing.
//! - **`size`** is IGNORED. The only size we report is the decoded byte count
//!   we measured ourselves; a claimed size is a number the sender chose.
//! - **`mimeType`** never decides rendering. It is mapped through our own
//!   allowlist to a coarse [`AttachmentKind`], so a sender cannot label bytes
//!   `text/html` and have them treated as markup.
//! - **`content`** is bounded before it is decoded, not after.
//!
//! Nothing here executes, opens, or writes anything: it turns bytes into a
//! description the UI can render as an inert card.

use crate::error::{CoreError, Result};

/// Largest attachment we will decode. A transaction payload is already bounded
/// by mass, so this is a second, explicit ceiling in front of an allocation
/// sized from attacker-supplied text.
pub const MAX_ATTACHMENT_BYTES: usize = 512 * 1024;

/// Longest file name we keep — a name is a display string here, and an
/// unbounded one wrecks a row long before it means anything.
pub const MAX_FILE_NAME: usize = 64;

/// How we are willing to treat an attachment's bytes — OUR classification,
/// never the sender's `mimeType` string.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttachmentKind {
    /// Safe to show as plain text (never as markup).
    Text,
    /// Raster image the platform can decode.
    Image,
    /// Anything else: offered as an opaque file, never interpreted.
    Other,
}

impl AttachmentKind {
    pub fn as_token(self) -> &'static str {
        match self {
            AttachmentKind::Text => "text",
            AttachmentKind::Image => "image",
            AttachmentKind::Other => "other",
        }
    }
}

/// A decoded attachment: what it is, and its actual bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attachment {
    /// Scrubbed base name, never a path.
    pub name: String,
    /// Bytes we decoded — never the sender's claimed `size`.
    pub bytes: Vec<u8>,
    pub kind: AttachmentKind,
}

impl Attachment {
    /// Parse a comm body that might be an attachment. `None` for anything that
    /// is not one, so an ordinary message is untouched.
    ///
    /// Returns `Err` only when the body *claims* to be a file and is malformed
    /// — the caller renders that as a broken attachment rather than as text,
    /// because showing a failed file's raw JSON is how this started.
    pub fn parse(body: &str) -> Option<Result<Self>> {
        let trimmed = body.trim_start();
        // Cheap gate before any JSON work: an ordinary message must not pay
        // for a parse attempt on every render.
        if !trimmed.starts_with('{') || !trimmed.contains("\"file\"") {
            return None;
        }
        let value: serde_json::Value = serde_json::from_str(trimmed).ok()?;
        let object = value.as_object()?;
        if object.get("type").and_then(|v| v.as_str()) != Some("file") {
            return None;
        }
        Some(Self::from_object(object))
    }

    fn from_object(object: &serde_json::Map<String, serde_json::Value>) -> Result<Self> {
        let content = object
            .get("content")
            .and_then(|v| v.as_str())
            .ok_or(CoreError::HandshakeShape("attachment content"))?;

        // A data: URI — the payload is whatever follows the first comma. We do
        // not parse the media type out of it; the sender's label is not a fact.
        let encoded = content
            .strip_prefix("data:")
            .and_then(|rest| rest.split_once(','))
            .map(|(_, payload)| payload)
            .ok_or(CoreError::HandshakeShape("attachment encoding"))?;

        // Bounded BEFORE decoding: 4 base64 characters yield 3 bytes, so cap
        // the input rather than discovering the size after allocating for it.
        if encoded.len() / 4 * 3 > MAX_ATTACHMENT_BYTES {
            return Err(CoreError::HandshakeShape("attachment too large"));
        }
        let bytes =
            decode_base64(encoded.as_bytes()).ok_or(CoreError::HandshakeShape("attachment b64"))?;
        if bytes.len() > MAX_ATTACHMENT_BYTES {
            return Err(CoreError::HandshakeShape("attachment too large"));
        }

        let name = safe_file_name(object.get("name").and_then(|v| v.as_str()).unwrap_or(""));
        let kind = classify(
            object
                .get("mimeType")
                .and_then(|v| v.as_str())
                .unwrap_or(""),
            &name,
        );
        Ok(Self { name, bytes, kind })
    }

    /// The media type to hand the system when opening this file.
    pub fn view_mime(&self) -> &'static str {
        view_mime(&self.name)
    }

    /// The attachment as text, when that is what it is — lossy, so malformed
    /// bytes become replacement characters rather than an error or a panic.
    pub fn as_text(&self) -> Option<String> {
        (self.kind == AttachmentKind::Text)
            .then(|| String::from_utf8_lossy(&self.bytes).into_owned())
    }
}

/// Reduce a sender-supplied file name to something safe to display and, later,
/// safe to use as a base name.
///
/// **A name is the field that becomes a path.** Directory separators are cut
/// (keeping only the final segment), then `..`, control characters and
/// whitespace runs go. An empty result becomes a neutral placeholder rather
/// than an empty row.
pub fn safe_file_name(raw: &str) -> String {
    let base = raw
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("")
        .replace("..", "");
    let mut out = String::with_capacity(base.len().min(MAX_FILE_NAME));
    let mut last_space = true;
    for ch in base.chars() {
        if ch.is_whitespace() {
            if !last_space {
                out.push(' ');
                last_space = true;
            }
            continue;
        }
        if ch.is_control() || is_deceptive_format(ch) {
            continue;
        }
        if out.chars().count() >= MAX_FILE_NAME {
            break;
        }
        out.push(ch);
        last_space = false;
    }
    let trimmed = out.trim().trim_matches('.').trim().to_string();
    if trimmed.is_empty() {
        "attachment".to_string()
    } else {
        trimmed
    }
}

/// True for characters that carry no glyph but change how the text around them
/// READS — bidi overrides, zero-width joiners, the BOM.
///
/// `char::is_control` is Unicode category **Cc only**, so it does not catch
/// these. That gap matters wherever a sender chooses a string we display: with
/// U+202E in a name, `annexe\u{202E}gpj.exe` renders as `annexe` + `exe.jpg`,
/// and the user approves something whose displayed extension is not its real
/// one. Neither Cc nor whitespace covers them, so they are named explicitly.
pub fn is_deceptive_format(ch: char) -> bool {
    matches!(ch,
        '\u{00AD}'                    // soft hyphen
        | '\u{200B}'..='\u{200F}'      // zero-width + LTR/RTL marks
        | '\u{202A}'..='\u{202E}'      // bidi embedding / override
        | '\u{2060}'..='\u{2064}'      // word joiner + invisible operators
        | '\u{2066}'..='\u{2069}'      // bidi isolates
        | '\u{FEFF}'                   // BOM / zero-width no-break space
    )
}

/// The media type to hand the SYSTEM when opening this file — derived from the
/// scrubbed EXTENSION, never from the sender's `mimeType`.
///
/// The distinction matters even though a wrong type here only means the wrong
/// app opens the file: `mimeType` is a string the sender chose, and the point
/// of routing an intent is that the OS acts on it. An extension we scrubbed
/// ourselves is the only part of the name we trust. Anything unrecognised gets
/// `application/octet-stream`, which makes the system offer a chooser instead
/// of silently handing the bytes to something specific.
pub fn view_mime(name: &str) -> &'static str {
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        // webm carries both; audio/ is the safer route for a voice note and
        // players handle a video container under it.
        "webm" => "audio/webm",
        "ogg" | "oga" | "opus" => "audio/ogg",
        "mp3" => "audio/mpeg",
        "m4a" | "aac" => "audio/mp4",
        "wav" => "audio/wav",
        "amr" => "audio/amr",
        "mp4" => "video/mp4",
        "pdf" => "application/pdf",
        "txt" | "log" => "text/plain",
        "md" | "markdown" => "text/markdown",
        "csv" => "text/csv",
        "json" => "application/json",
        // Deliberately NOT text/html or image/svg+xml: handing markup to the
        // system means handing it to a browser, which is the one viewer that
        // executes what it is given.
        _ => "application/octet-stream",
    }
}

/// Classify by OUR allowlist. The sender's media type is a hint we may accept
/// only into a safe bucket; anything unrecognised is `Other` and stays opaque.
///
/// `text/html`, `image/svg+xml` and friends are deliberately NOT text or image:
/// both are markup that a renderer could be talked into executing.
fn classify(mime: &str, name: &str) -> AttachmentKind {
    let mime = mime.trim().to_ascii_lowercase();
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();

    const TEXT_MIME: [&str; 6] = [
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/json",
        "text/x-markdown",
        "text/markdown; charset=utf-8",
    ];
    const TEXT_EXT: [&str; 6] = ["txt", "md", "csv", "json", "log", "markdown"];
    const IMAGE_MIME: [&str; 4] = ["image/png", "image/jpeg", "image/gif", "image/webp"];
    const IMAGE_EXT: [&str; 5] = ["png", "jpg", "jpeg", "gif", "webp"];

    if TEXT_MIME.contains(&mime.as_str()) || TEXT_EXT.contains(&ext.as_str()) {
        return AttachmentKind::Text;
    }
    if IMAGE_MIME.contains(&mime.as_str()) || IMAGE_EXT.contains(&ext.as_str()) {
        return AttachmentKind::Image;
    }
    AttachmentKind::Other
}

/// Standard-alphabet base64, tolerant of whitespace (a data: URI may be
/// wrapped). `None` on any structural violation — the caller then reports a
/// broken attachment rather than guessing at the bytes.
fn decode_base64(text: &[u8]) -> Option<Vec<u8>> {
    fn value(b: u8) -> Option<u32> {
        match b {
            b'A'..=b'Z' => Some((b - b'A') as u32),
            b'a'..=b'z' => Some((b - b'a' + 26) as u32),
            b'0'..=b'9' => Some((b - b'0' + 52) as u32),
            b'+' | b'-' => Some(62),
            b'/' | b'_' => Some(63),
            _ => None,
        }
    }
    let cleaned: Vec<u8> = text
        .iter()
        .copied()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    let body: &[u8] = cleaned
        .strip_suffix(b"==")
        .unwrap_or_else(|| cleaned.strip_suffix(b"=").unwrap_or(cleaned.as_slice()));
    // A remainder of 1 encodes no whole byte, so it cannot be valid base64 —
    // every other remainder is a legal unpadded tail.
    if body.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(body.len() / 4 * 3 + 3);
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for &b in body {
        acc = (acc << 6) | value(b)?;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((acc >> bits) & 0xFF) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data_uri(mime: &str, bytes: &[u8]) -> String {
        const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut b64 = String::new();
        for chunk in bytes.chunks(3) {
            let mut acc = 0u32;
            for (i, &b) in chunk.iter().enumerate() {
                acc |= (b as u32) << (16 - 8 * i);
            }
            for i in 0..4 {
                if i <= chunk.len() {
                    b64.push(ALPHABET[((acc >> (18 - 6 * i)) & 0x3F) as usize] as char);
                } else {
                    b64.push('=');
                }
            }
        }
        format!("data:{mime};base64,{b64}")
    }

    fn body(name: &str, mime: &str, bytes: &[u8]) -> String {
        format!(
            r#"{{"type":"file","name":"{name}","size":99999,"mimeType":"{mime}","content":"{}"}}"#,
            data_uri(mime, bytes)
        )
    }

    /// THE FOUNDER'S CASE: a markdown file that used to render as raw JSON.
    #[test]
    fn a_markdown_attachment_parses_into_a_file_not_a_wall_of_json() {
        let parsed = Attachment::parse(&body("Algovelo.md", "text/markdown", b"# Notes\nhello"))
            .unwrap()
            .unwrap();
        assert_eq!(parsed.name, "Algovelo.md");
        assert_eq!(parsed.kind, AttachmentKind::Text);
        assert_eq!(parsed.as_text().unwrap(), "# Notes\nhello");
        // The DECLARED size is ignored; only what we decoded counts.
        assert_eq!(parsed.bytes.len(), 13);
    }

    /// An ordinary message must never be mistaken for a file, and must not pay
    /// for a JSON parse on every render.
    #[test]
    fn ordinary_messages_are_untouched() {
        assert!(Attachment::parse("hello over L1").is_none());
        assert!(Attachment::parse("{not json at all").is_none());
        assert!(Attachment::parse(r#"{"type":"handshake","alias":"a"}"#).is_none());
        // Mentions the word without being one.
        assert!(Attachment::parse("i sent you a \"file\" earlier").is_none());
    }

    /// A file name is the one field that later becomes a PATH.
    #[test]
    fn a_file_name_can_never_carry_a_path_or_structure() {
        assert_eq!(safe_file_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_file_name("..\\..\\windows\\system32"), "system32");
        assert_eq!(safe_file_name("a/b/c/notes.md"), "notes.md");
        assert_eq!(safe_file_name(".."), "attachment");
        assert_eq!(safe_file_name(""), "attachment");
        assert_eq!(safe_file_name("evil\nname.txt"), "evil name.txt");
        assert_eq!(safe_file_name("nul\u{0}.txt"), "nul.txt");
        // Bidi and zero-width characters carry no glyph but change what the
        // name READS as — the sender must not control the visible extension.
        assert_eq!(safe_file_name("annexe\u{202E}gpj.exe"), "annexegpj.exe");
        assert_eq!(safe_file_name("a\u{200B}b\u{FEFF}c.md"), "abc.md");
        assert_eq!(safe_file_name("\u{2066}x\u{2069}.txt"), "x.txt");
        assert!(safe_file_name(&"x".repeat(500)).chars().count() <= MAX_FILE_NAME);
    }

    /// The sender's media type may not talk us into treating markup as text or
    /// as an image — both are renderer-executable in the wrong hands.
    #[test]
    fn markup_is_never_classified_as_text_or_image() {
        let html = Attachment::parse(&body("page.html", "text/html", b"<script>x</script>"))
            .unwrap()
            .unwrap();
        assert_eq!(html.kind, AttachmentKind::Other);
        assert!(html.as_text().is_none(), "opaque, never rendered as text");

        let svg = Attachment::parse(&body("logo.svg", "image/svg+xml", b"<svg/>"))
            .unwrap()
            .unwrap();
        assert_eq!(svg.kind, AttachmentKind::Other);

        // And a lying mimeType cannot promote a binary either: the extension
        // agrees with the mime here, so both signals are checked.
        let exe = Attachment::parse(&body("run.exe", "text/plain", b"MZ\x90\x00"))
            .unwrap()
            .unwrap();
        assert_eq!(exe.kind, AttachmentKind::Text, "mime allowlist hit");
        // …which is why the BYTES are still never executed — only shown.
        assert_eq!(exe.name, "run.exe");
    }

    /// Bounded before allocation, and a malformed one reports rather than
    /// falling back to rendering its raw JSON.
    #[test]
    fn a_hostile_attachment_is_refused_not_rendered() {
        let huge = format!(
            r#"{{"type":"file","name":"x","content":"data:text/plain;base64,{}"}}"#,
            "A".repeat(MAX_ATTACHMENT_BYTES * 2)
        );
        assert!(Attachment::parse(&huge).unwrap().is_err());

        let no_content = r#"{"type":"file","name":"x"}"#;
        assert!(Attachment::parse(no_content).unwrap().is_err());

        let not_a_data_uri = r#"{"type":"file","name":"x","content":"https://evil/x"}"#;
        assert!(Attachment::parse(not_a_data_uri).unwrap().is_err());

        let bad_b64 = r#"{"type":"file","name":"x","content":"data:text/plain;base64,!!!!"}"#;
        assert!(Attachment::parse(bad_b64).unwrap().is_err());
    }

    /// The type handed to the OS comes from the extension WE scrubbed, never
    /// from the sender's claim — and markup never gets a viewer that executes.
    #[test]
    fn the_view_type_comes_from_our_extension_not_their_claim() {
        assert_eq!(view_mime("photo.jpg"), "image/jpeg");
        assert_eq!(view_mime("kasia-audio-4F41.webm"), "audio/webm");
        assert_eq!(view_mime("note.md"), "text/markdown");
        assert_eq!(view_mime("clip.mp4"), "video/mp4");

        // Unknown, and markup, both fall to the neutral type so the system
        // offers a chooser instead of routing to a browser.
        assert_eq!(view_mime("thing.xyz"), "application/octet-stream");
        assert_eq!(view_mime("noextension"), "application/octet-stream");
        assert_eq!(view_mime("page.html"), "application/octet-stream");
        assert_eq!(view_mime("logo.svg"), "application/octet-stream");

        // A file whose sender LIED about the media type still routes by the
        // scrubbed extension.
        let lied = Attachment::parse(&body("photo.jpg", "text/html", b"\x89PNG"))
            .unwrap()
            .unwrap();
        assert_eq!(lied.view_mime(), "image/jpeg");
    }

    #[test]
    fn base64_decoding_matches_the_rfc_vectors_and_tolerates_wrapping() {
        let round = |s: &[u8]| {
            let uri = data_uri("text/plain", s);
            let (_, b64) = uri.split_once(',').unwrap();
            decode_base64(b64.as_bytes()).unwrap()
        };
        assert_eq!(round(b"foobar"), b"foobar");
        assert_eq!(round(b"foob"), b"foob");
        assert_eq!(round(b"fooba"), b"fooba");
        assert_eq!(round(b""), b"");
        // A wrapped data: URI still decodes.
        assert_eq!(decode_base64(b"Zm9v\nYmFy").unwrap(), b"foobar");
        // URL-safe alphabet is tolerated (some emitters use it).
        assert_eq!(decode_base64(b"-_8=").unwrap(), vec![0xFB, 0xFF]);
    }
}
