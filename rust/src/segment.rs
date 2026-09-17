use jieba_rs::{Jieba, TokenizeMode};
use std::borrow::Cow;
use std::sync::OnceLock;
use unicode_segmentation::UnicodeSegmentation;

/// Tokenizer options, mirrored by the `JIEBA_OPT_*` bits in `c/shim.c`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Options {
    /// HMM new-word discovery for runs the dictionary does not cover.
    pub hmm: bool,
    /// Emit dictionary sub-words alongside the long word, colocated. Off, only
    /// the long word is indexed: a smaller index that cannot match sub-words.
    pub search: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            hmm: true,
            search: true,
        }
    }
}

impl Options {
    const HMM: i32 = 0x0001;
    const SEARCH: i32 = 0x0002;

    /// Decodes the bitmask the C shim passes across the ABI.
    pub fn from_bits(bits: i32) -> Self {
        Self {
            hmm: bits & Self::HMM != 0,
            search: bits & Self::SEARCH != 0,
        }
    }

    fn mode(self) -> TokenizeMode {
        if self.search {
            TokenizeMode::Search
        } else {
            TokenizeMode::Default
        }
    }
}

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

/// A token plus the byte range of the **original** text it came from. The two
/// can differ (tokens are lowercased); the range is what FTS5 `highlight()` and
/// `snippet()` mark up.
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

/// `unicode61` drops these too.
#[inline]
fn is_indexable(s: &str) -> bool {
    s.chars().any(char::is_alphanumeric)
}

static JIEBA: OnceLock<Jieba> = OnceLock::new();

fn jieba() -> &'static Jieba {
    JIEBA.get_or_init(Jieba::new)
}

/// Everything that is not Han. jieba's own non-Han branch only understands
/// ASCII (it cuts `schön` into `sch|ö|n`), so boundaries come from UAX#29.
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

fn han<'a>(text: &'a str, span: &Span, opts: Options, out: &mut Vec<Token<'a>>) {
    let slice = &text[span.start..span.end];
    // Search mode emits sub-words in dictionary order, not positional order.
    // FTS5 needs non-decreasing positions and ties COLOCATED to the previous
    // token, so regroup: longest first at each start, shorter ones behind it.
    let mut hits: Vec<_> = jieba()
        .tokenize(slice, opts.mode(), opts.hmm)
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
pub fn tokenize(text: &str, opts: Options) -> Vec<Token<'_>> {
    let mut out = Vec::new();
    for span in spans(text) {
        if span.han {
            han(text, &span, opts, &mut out);
        } else {
            latin(text, &span, &mut out);
        }
    }
    out
}

/// Distinct token texts, first occurrence first. Meant for building a `MATCH`
/// string, so that query terms come from the vocabulary the index was built
/// with.
pub fn distinct_tokens(text: &str, opts: Options) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for token in tokenize(text, opts) {
        if seen.insert(token.text.to_string()) {
            out.push(token.text.into_owned());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokenize(text: &str) -> Vec<Token<'_>> {
        super::tokenize(text, Options::default())
    }

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
    fn empty_and_whitespace_produce_nothing() {
        assert!(tokenize("").is_empty());
        assert!(tokenize("   \n\t ").is_empty());
        assert!(tokenize("!@#$%^&*()").is_empty());
    }

    #[test]
    fn search_off_indexes_only_the_long_word() {
        let opts = Options {
            search: false,
            ..Options::default()
        };
        let tokens = super::tokenize("南京市长江大桥", opts);
        assert!(
            tokens.iter().all(|t| !t.colocated),
            "sub-words are what colocation is for"
        );
        assert_eq!(
            tokens.iter().map(|t| t.text.as_ref()).collect::<Vec<_>>(),
            vec!["南京市", "长江大桥"]
        );
    }

    #[test]
    fn options_round_trip_through_the_abi() {
        assert_eq!(Options::from_bits(0x3), Options::default());
        assert_eq!(
            Options::from_bits(0),
            Options {
                hmm: false,
                search: false
            }
        );
    }

    #[test]
    fn distinct_tokens_dedup_in_order() {
        assert_eq!(
            distinct_tokens("苹果 苹果 香蕉", Options::default()),
            vec!["苹果".to_string(), "香蕉".to_string()]
        );
    }
}
