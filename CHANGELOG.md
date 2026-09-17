## 0.2.0

- The build hook now fetches a prebuilt native library for the target from the GitHub release and
  checks it against a SHA-256 shipped with the package. `rustup` is needed only when it falls back
  to compiling the crate: an uncovered target, a lower deployment target, an unreachable download,
  or a `build_from_source` user-define.
- Registers as an `fts5_tokenizer_v2` when the host SQLite offers `fts5_api.iVersion >= 3`
  (3.47.0+), and as the legacy `fts5_tokenizer` below that. `locale=1` tables and `fts5_locale()`
  now work; jieba segments by dictionary, so the locale is accepted and ignored.
- Refuses to load on SQLite older than 3.31.0, with a message naming the version it found.
- Tokenizer options: `tokenize='jieba search 0 hmm 1'`. An unrecognised option now fails the
  `CREATE VIRTUAL TABLE`.
- `jieba_cut(text, options)` takes the same option string, so a query can be cut the way its table
  was indexed.
- New `jieba_version()` scalar function.
- The vendored SQLite headers now record their provenance (3.53.4) in `rust/c/README.md`.

## 0.1.0

- Initial release: a `jieba` FTS5 tokenizer and a `jieba_cut()` function for `package:sqlite3`.
- Tokens carry byte offsets into the source text, so `highlight()` and `snippet()` return marked-up
  original text.
- Han runs are segmented in jieba search mode with colocated sub-words; everything else uses Unicode
  UAX#29 word boundaries, lowercased.
