## 0.1.0

- Initial release: a `jieba` FTS5 tokenizer and a `jieba_cut()` function for `package:sqlite3`.
- Tokens carry byte offsets into the source text, so `highlight()` and `snippet()` return marked-up
  original text.
- Han runs are segmented in jieba search mode with colocated sub-words; everything else uses Unicode
  UAX#29 word boundaries, lowercased.
