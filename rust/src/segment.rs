use jieba_rs::{Jieba, TokenizeMode};
use std::borrow::Cow;
use std::sync::OnceLock;
use unicode_segmentation::UnicodeSegmentation;

#[inline]
fn is_han(c: char) -> bool {
    matches!(c,
        '\u{4E00}'..='\u{9FFF}'   |
        '\u{3400}'..='\u{4DBF}'   |
        '\u{20000}'..='\u{2A6DF}' |
        '\u{2A700}'..='\u{2B73F}' |
        '\u{2B740}'..='\u{2B81F}' |
        '\u{F900}'..='\u{FAFF}'   |
        '\u{2F800}'..='\u{2FA1F}'
    )
}

/// A token plus the byte range of the **original** text it came from. The token
/// text may differ from that range (it is lowercased), which is what lets FTS5
/// `highlight()` / `snippet()` mark up the source rather than the index.
pub struct Token<'a> {
    pub text: Cow<'a, str>,
    pub start: usize,
    pub end: usize,
    /// Same position as the previous token (FTS5_TOKEN_COLOCATED).
    pub colocated: bool,
}

struct Span {
    start: usize,
    end: usize,
    han: bool,
}

/// Whitespace-delimited runs, split again wherever Han meets non-Han.
fn spans(text: &str) -> Vec<Span> {
    let mut out: Vec<Span> = Vec::new();
    let mut start: Option<usize> = None;
    let mut kind = false;

    for (i, ch) in text.char_indices() {
        if ch.is_whitespace() {
            if let Some(s) = start.take() {
                out.push(Span {
                    start: s,
                    end: i,
                    han: kind,
                });
            }
            continue;
        }
        let ch_is_han = is_han(ch);
        match start {
            None => {
                start = Some(i);
                kind = ch_is_han;
            }
            Some(s) if ch_is_han != kind => {
                out.push(Span {
                    start: s,
                    end: i,
                    han: kind,
                });
                start = Some(i);
                kind = ch_is_han;
            }
            Some(_) => {}
        }
    }
    if let Some(s) = start {
        out.push(Span {
            start: s,
            end: text.len(),
            han: kind,
        });
    }
    out
}

/// Runs with no letter or digit carry no recall; `unicode61` drops them too.
#[inline]
fn is_indexable(s: &str) -> bool {
    s.chars().any(char::is_alphanumeric)
}

static JIEBA: OnceLock<Jieba> = OnceLock::new();

fn jieba() -> &'static Jieba {
    JIEBA.get_or_init(Jieba::new)
}

/// Everything that is not Han. jieba's own non-Han branch only understands
/// ASCII — it cuts `schön` into `sch|ö|n`, and Cyrillic, Greek, Arabic and
/// Hangul into single characters — so word boundaries come from Unicode UAX#29
/// instead.
fn latin<'a>(text: &'a str, span: &Span, out: &mut Vec<Token<'a>>) {
    let slice = &text[span.start..span.end];
    for (off, word) in slice.unicode_word_indices() {
        if !is_indexable(word) {
            continue;
        }
        let lower = word.to_lowercase();
        out.push(Token {
            text: if lower == word {
                Cow::Borrowed(word)
            } else {
                Cow::Owned(lower)
            },
            start: span.start + off,
            end: span.start + off + word.len(),
            colocated: false,
        });
    }
}

fn han<'a>(text: &'a str, span: &Span, out: &mut Vec<Token<'a>>) {
    let slice = &text[span.start..span.end];
    // Search mode also yields the sub-words of every long word, but in
    // dictionary order rather than positional order: for 南京市长江大桥 it emits
    // 南京(0) 京市(1) 南京市(0) 长江(3) 大桥(5) 长江大桥(3). FTS5 needs
    // non-decreasing positions and only ties COLOCATED to the token right before
    // it, so regroup: longest first at each start, shorter variants colocated
    // behind it.
    let mut hits: Vec<_> = jieba()
        .tokenize(slice, TokenizeMode::Search, true)
        .into_iter()
        .filter(|t| is_indexable(t.word))
        .collect();
    hits.sort_by(|a, b| {
        a.byte_start
            .cmp(&b.byte_start)
            .then(b.byte_end.cmp(&a.byte_end))
    });

    let mut previous_start: Option<usize> = None;
    for hit in hits {
        let colocated = previous_start == Some(hit.byte_start);
        previous_start = Some(hit.byte_start);
        out.push(Token {
            text: Cow::Borrowed(hit.word),
            start: span.start + hit.byte_start,
            end: span.start + hit.byte_end,
            colocated,
        });
    }
}

/// Tokens in order of occurrence, byte offsets into `text`.
pub fn tokenize(text: &str) -> Vec<Token<'_>> {
    let mut out = Vec::new();
    for span in spans(text) {
        if span.han {
            han(text, &span, &mut out);
        } else {
            latin(text, &span, &mut out);
        }
    }
    out
}

/// Distinct token texts, first occurrence first. Meant for building a `MATCH`
/// string, so that query terms come from the vocabulary the index was built
/// with.
pub fn distinct_tokens(text: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for token in tokenize(text) {
        if seen.insert(token.text.to_string()) {
            out.push(token.text.into_owned());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(text: &str) -> Vec<String> {
        tokenize(text)
            .into_iter()
            .map(|t| t.text.into_owned())
            .collect()
    }

    #[test]
    fn offsets_point_at_the_source_word() {
        for text in [
            "今天天气很好，我去公园散步了",
            "今天去了Starbucks，感觉coffee不错",
            "emoji 🎉 混排 test running 结束",
            "Das Wetter ist schön, ich ging spazieren",
            "Сегодня хорошая погода",
            "全角标点，。！？和 ASCII, . ! ?",
        ] {
            for token in tokenize(text) {
                assert!(text.is_char_boundary(token.start), "{text}");
                assert!(text.is_char_boundary(token.end), "{text}");
                assert!(token.start < token.end, "empty range in {text}");
                assert_eq!(
                    text[token.start..token.end].to_lowercase(),
                    token.text.as_ref(),
                    "offset drift in {text}"
                );
            }
        }
    }

    #[test]
    fn positions_never_go_backwards() {
        let tokens = tokenize("南京市长江大桥今天很好看 running fast");
        assert!(!tokens[0].colocated, "the first token cannot be colocated");
        let mut last = 0;
        for token in &tokens {
            assert!(token.start >= last);
            last = token.start;
        }
    }

    #[test]
    fn colocated_groups_put_the_longest_first() {
        let shape: Vec<_> = tokenize("南京市长江大桥")
            .iter()
            .map(|t| (t.text.to_string(), t.start, t.colocated))
            .collect();
        assert_eq!(
            shape,
            vec![
                ("南京市".to_string(), 0, false),
                ("南京".to_string(), 0, true),
                ("京市".to_string(), 3, false),
                ("长江大桥".to_string(), 9, false),
                ("长江".to_string(), 9, true),
                ("大桥".to_string(), 15, false),
            ]
        );
    }

    #[test]
    fn punctuation_is_dropped() {
        let tokens = texts("标点，。！？符号");
        assert!(!tokens.iter().any(|t| t == "，" || t == "。"));
        assert!(tokens.iter().any(|t| t == "标点"));
        assert!(tokens.iter().any(|t| t == "符号"));
    }

    #[test]
    fn search_mode_expands_long_words() {
        let tokens = texts("今天天气很好");
        assert!(tokens.iter().any(|t| t == "今天天气"));
        assert!(tokens.iter().any(|t| t == "今天"));
        assert!(tokens.iter().any(|t| t == "天气"));
    }

    #[test]
    fn mixed_scripts_keep_whole_words() {
        let tokens = texts("今天去了Starbucks，感觉coffee不错");
        assert!(tokens.iter().any(|t| t == "今天"));
        assert!(tokens.iter().any(|t| t == "不错"));
        assert!(tokens.contains(&"starbucks".to_string()));
        assert!(tokens.contains(&"coffee".to_string()));
    }

    #[test]
    fn accented_latin_is_not_shredded() {
        // jieba's own non-Han branch only understands ASCII; UAX#29 keeps these
        // whole.
        assert!(texts("Das Wetter ist schön").contains(&"schön".to_string()));
        assert!(texts("thời tiết đẹp").contains(&"thời".to_string()));
        assert!(texts("хорошая погода").contains(&"хорошая".to_string()));
        assert!(texts("καλός καιρός").contains(&"καλός".to_string()));
    }

    #[test]
    fn latin_is_lowercased_but_not_stemmed() {
        assert_eq!(
            texts("Running WEATHER"),
            vec!["running".to_string(), "weather".to_string()]
        );
    }

    #[test]
    fn duplicates_survive_for_term_frequency() {
        assert_eq!(
            texts("hello hello hello")
                .iter()
                .filter(|t| t.as_str() == "hello")
                .count(),
            3
        );
    }

    #[test]
    fn segmentation_goldens() {
        const CASES: &[(&str, &str)] = &[
            (
                "今天天气很好，我去公园散步了",
                "今天天气/很/好/我/去/公园/散步/了",
            ),
            (
                "北京大学的研究生正在做自然语言处理",
                "北京大学/的/研究生/正在/做/自然语言/处理",
            ),
            ("百年孤独是一本很棒的小说", "百年孤独/是/一本/很棒/的/小说"),
        ];
        for (text, expected) in CASES {
            let got: Vec<&str> = jieba()
                .tokenize(text, TokenizeMode::Default, true)
                .into_iter()
                .map(|t| t.word)
                .filter(|w| is_indexable(w))
                .collect();
            assert_eq!(got.join("/"), *expected, "segmentation drift: {text}");
        }
    }

    #[test]
    fn empty_and_whitespace_produce_nothing() {
        assert!(tokenize("").is_empty());
        assert!(tokenize("   \n\t ").is_empty());
        assert!(tokenize("!@#$%^&*()").is_empty());
    }

    #[test]
    fn distinct_tokens_dedup_in_order() {
        assert_eq!(
            distinct_tokens("苹果 苹果 香蕉"),
            vec!["苹果".to_string(), "香蕉".to_string()]
        );
    }
}
