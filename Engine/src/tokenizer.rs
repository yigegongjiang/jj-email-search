//! Delegate Chinese runs to Jieba and other runs to Tantivy's native tokenizer.
//! This adapter preserves byte offsets for highlighting and native English
//! word positions for phrase queries; it implements no segmentation algorithm.
use tantivy::tokenizer::{SimpleTokenizer, Token, TokenStream, Tokenizer};
#[derive(Clone, Default)]
pub struct MixedTokenizer;
pub struct MixedStream {
    tokens: Vec<Token>,
    cursor: usize,
}
pub fn chinese(c: char) -> bool {
    matches!(c as u32,0x3400..=0x9fff|0xf900..=0xfaff|0x20000..=0x323af)
}
impl Tokenizer for MixedTokenizer {
    type TokenStream<'a> = MixedStream;
    fn token_stream<'a>(&'a mut self, text: &'a str) -> MixedStream {
        let mut tokens = Vec::new();
        let mut chars = text.char_indices().peekable();
        let mut position = 0;
        while let Some((start, c)) = chars.next() {
            let kind = chinese(c);
            while chars.peek().is_some_and(|(_, c)| chinese(*c) == kind) {
                chars.next();
            }
            let end = chars.peek().map(|(i, _)| *i).unwrap_or(text.len());
            let mut jieba = tantivy_jieba::JiebaTokenizer::new();
            let mut english = SimpleTokenizer::default();
            let mut append = |stream: &mut dyn TokenStream| {
                let base = position;
                while stream.advance() {
                    let mut token = stream.token().clone();
                    if token.text.chars().all(|c| !c.is_alphanumeric()) {
                        continue;
                    }
                    token.offset_from += start;
                    token.offset_to += start;
                    token.position += base;
                    position = position.max(token.position + 1);
                    tokens.push(token);
                }
            };
            if kind {
                append(&mut jieba.token_stream(&text[start..end]));
            } else {
                append(&mut english.token_stream(&text[start..end]));
            }
        }
        MixedStream { tokens, cursor: 0 }
    }
}
impl TokenStream for MixedStream {
    fn advance(&mut self) -> bool {
        if self.cursor < self.tokens.len() {
            self.cursor += 1;
            true
        } else {
            false
        }
    }
    fn token(&self) -> &Token {
        &self.tokens[self.cursor - 1]
    }
    fn token_mut(&mut self) -> &mut Token {
        &mut self.tokens[self.cursor - 1]
    }
}
