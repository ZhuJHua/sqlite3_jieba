# sqlite3_jieba

A [jieba](https://github.com/messense/jieba-rs)-backed **FTS5 tokenizer** for SQLite, shipped as a
native asset. It adds a `jieba` tokenizer and a `jieba_cut()` SQL function to
[`package:sqlite3`](https://pub.dev/packages/sqlite3) — no extra files to bundle, no dictionary to
extract at runtime.

Chinese has no spaces, so SQLite's built-in `unicode61` tokenizer indexes a whole sentence as one
term and full-text search effectively stops working. `trigram` works but triples the index and
throws away relevance. This package segments Chinese properly instead.

```sql
CREATE VIRTUAL TABLE notes USING fts5(title, body, tokenize='jieba');
```

## Install

```yaml
dependencies:
  sqlite3_jieba: ^0.1.0
```

Native assets are built by a Dart build hook, so you need [`rustup`](https://rustup.rs) on the
machine that compiles your app (not on your users' machines). Nothing else — no CMake, no NDK setup
beyond what Flutter already requires.

## Use

```dart
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_jieba/sqlite3_jieba.dart';

void main() {
  // Registers via sqlite3_auto_extension, which is process-level state: call it
  // BEFORE opening the database you want to search. Calling it twice is fine.
  loadJiebaTokenizer();

  final db = sqlite3.openInMemory();
  db.execute("CREATE VIRTUAL TABLE notes USING fts5(body, tokenize='jieba')");
  db.execute('INSERT INTO notes(body) VALUES (?)', ['今天天气很好，我去公园散步了']);

  for (final row in db.select(
    "SELECT highlight(notes, 0, '[', ']') AS hit FROM notes WHERE notes MATCH ?",
    ['"公园"'],
  )) {
    print(row['hit']); // 今天天气很好，我去[公园]散步了
  }
}
```

### `jieba_cut(text)`

Returns the distinct tokens of `text` as a JSON array. Use it to build `MATCH` strings from user
input, so the query terms come from the same vocabulary the index was built with:

```dart
final tokens = (jsonDecode(
  db.select('SELECT jieba_cut(?) AS t', [query]).single['t'] as String,
) as List).cast<String>();

final match = tokens.map((t) => '"${t.replaceAll('"', '""')}"').join(' OR ');
db.select('SELECT rowid FROM notes WHERE notes MATCH ?', [match]);
```

### With drift

Register before drift opens its connection — including the background isolate and read pool, which
inherit the process-level registration:

```dart
loadJiebaTokenizer();
final executor = NativeDatabase.createInBackground(File(path), readPool: 3);
```

### With `highlight()` / `snippet()`

Tokens carry **byte offsets into the original text**, so both functions return marked-up source
rather than index terms. They need the text to be reachable, which means a normal or
[external content](https://sqlite.org/fts5.html#external_content_tables) table — on a
`content=''` contentless table SQLite returns `NULL` silently.

## Behaviour

- Input is split into whitespace-delimited runs, and again wherever Han meets non-Han.
- **Han runs** go through jieba in *search* mode: the long word and its dictionary sub-words are
  both indexed, the sub-words marked `FTS5_TOKEN_COLOCATED` so they sit at the same position.
  `今天天气` is findable as `今天天气`, `今天` and `天气`.
- **Everything else** is segmented with Unicode UAX#29 word boundaries and lowercased. No stemming:
  searching `runs` does not match `running`.
- Runs without a letter or digit (punctuation, symbols) are dropped, matching `unicode61`.
- Documents and queries take the identical path, which is what keeps phrase queries aligned.

### Language support

| | Result |
|---|---|
| Chinese | Full dictionary segmentation. |
| Any space-delimited script — Latin (incl. accents), Cyrillic, Greek, Arabic, Hebrew, Vietnamese | Correct word boundaries via UAX#29. |
| Korean | Split at eojeol (space) boundaries only; no morphological analysis, so `공원` does not match `공원을`. |
| Japanese | **Poor.** Han runs are segmented with a *Chinese* dictionary, and kana runs have no word boundaries under UAX#29. |
| Thai, Lao, Khmer, Burmese | **Not supported.** These scripts have no spaces and need their own dictionary segmentation. |

For Japanese or Thai, SQLite's built-in `trigram` tokenizer is the practical fallback.

## How it works

An FTS5 tokenizer has to be a C-ABI loadable extension: `fts5_api` is only reachable from inside
one, through `SELECT fts5(?1)` plus `sqlite3_bind_pointer`. So this package is a Rust `cdylib` with
a ~100-line C shim for the SQLite plumbing; the shim's entry point is re-exported by Rust as
`sqlite3_jieba_init`, and Dart hands that address to `sqlite3_auto_extension` through
`package:sqlite3`'s `SqliteExtension`.

The jieba dictionary (5 MB of text) is DEFLATE-compressed into the binary by `jieba-rs`, so there
are no asset files to ship or unpack.

## License

MIT. Bundles [jieba-rs](https://github.com/messense/jieba-rs) (MIT) and its dictionary, and
[unicode-segmentation](https://github.com/unicode-rs/unicode-segmentation) (MIT/Apache-2.0).
