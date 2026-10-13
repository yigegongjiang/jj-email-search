//! Highlight indexed tokens, with the same analyzer and field scope as search.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashSet};
use tantivy::{
    query::{BooleanQuery, Occur, Query},
    schema::Schema,
    tokenizer::{LowerCaser, TextAnalyzer},
};

#[derive(Deserialize, Serialize, Ord, PartialOrd, Eq, PartialEq)]
pub struct HighlightTerm {
    field: String,
    text: String,
}
#[derive(Deserialize)]
pub struct HighlightText {
    field: String,
    text: String,
}
#[derive(Serialize)]
pub struct HighlightRange {
    location: usize,
    length: usize,
}

pub fn terms(query: &dyn Query, schema: &Schema) -> BTreeSet<HighlightTerm> {
    let mut result = BTreeSet::new();
    if let Some(boolean) = query.downcast_ref::<BooleanQuery>() {
        for (occur, clause) in boolean.clauses() {
            if *occur != Occur::MustNot {
                result.extend(terms(clause.as_ref(), schema));
            }
        }
    } else {
        query.query_terms(&mut |term, _| {
            let field = schema.get_field_name(term.field());
            if matches!(field, "subject" | "sender" | "recipients" | "body")
                && let Some(text) = term.value().as_str()
            {
                result.insert(HighlightTerm {
                    field: field.into(),
                    text: text.into(),
                });
            }
        });
    }
    result
}

pub fn ranges(texts: &[HighlightText], terms: &[HighlightTerm]) -> Vec<Vec<HighlightRange>> {
    let mut analyzer = TextAnalyzer::builder(crate::tokenizer::MixedTokenizer)
        .filter(LowerCaser)
        .build();
    texts
        .iter()
        .map(|input| {
            let wanted: HashSet<&str> = terms
                .iter()
                .filter(|term| term.field == input.field)
                .map(|term| term.text.as_str())
                .collect();
            if wanted.is_empty() {
                return Vec::new();
            }
            let mut bytes = Vec::new();
            let mut stream = analyzer.token_stream(&input.text);
            while stream.advance() {
                let token = stream.token();
                if wanted.contains(token.text.as_str()) {
                    bytes.push((token.offset_from, token.offset_to));
                }
            }
            bytes.sort_unstable();
            let mut merged: Vec<(usize, usize)> = Vec::new();
            for (start, end) in bytes {
                if let Some(last) = merged.last_mut()
                    && start <= last.1
                {
                    last.1 = last.1.max(end);
                } else {
                    merged.push((start, end));
                }
            }
            // Convert byte offsets in one forward pass, including supplementary Unicode.
            let (mut cursor, mut location) = (0, 0);
            merged
                .into_iter()
                .map(|(start, end)| {
                    location += input.text[cursor..start].encode_utf16().count();
                    let length = input.text[start..end].encode_utf16().count();
                    let range = HighlightRange { location, length };
                    cursor = end;
                    location += length;
                    range
                })
                .collect()
        })
        .collect()
}
