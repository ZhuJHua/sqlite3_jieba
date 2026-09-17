# sqlite3_jieba

A [jieba](https://github.com/messense/jieba-rs)-backed **FTS5 tokenizer** for
[`package:sqlite3`](https://pub.dev/packages/sqlite3), shipped as a native asset.

Chinese text has no word boundaries, so `unicode61` indexes a whole sentence as a single term. This
package runs Han text through jieba's dictionary instead, so `公园` matches inside
`我去公园散步了`.

```sql
CREATE VIRTUAL TABLE notes USING fts5(title, body, tokenize='jieba');
```

## Install

```yaml
dependencies:
  sqlite3_jieba: ^0.2.1
```

A build hook fetches the native library for your target from the GitHub release and checks it
against a SHA-256 shipped with the package. SQLite 3.31.0 or later.

| Prebuilt for | |
|---|---|
| Android | arm64-v8a, armeabi-v7a, x86_64 — API 21+ |
| iOS | arm64 device, arm64 + x64 simulator — iOS 12+ |
| macOS | arm64, x64 — macOS 10.14+ |
| Linux | arm64, x64 — glibc 2.35+ |
| Windows | arm64, x64 |

Outside that table — an uncovered target, a lower deployment target, or an unreachable download —
the hook compiles the Rust crate on your build machine, which needs [`rustup`](https://rustup.rs).
It logs which path it took.

## Use

```dart
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_jieba/sqlite3_jieba.dart';

void main() {
  // Process-level registration: call it BEFORE opening the database you want
  // to search. Calling it twice is fine.
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

With drift, register before the connection is opened; the background isolate and read pool inherit
it:

```dart
loadJiebaTokenizer();
final executor = NativeDatabase.createInBackground(File(path), readPool: 3);
```

### Building `MATCH` strings

`jieba_cut(text)` returns the distinct tokens of `text` as a JSON array, so query terms come from
the same vocabulary as the index:

```dart
final tokens = (jsonDecode(
  db.select('SELECT jieba_cut(?) AS t', [query]).single['t'] as String,
) as List).cast<String>();

final match = tokens.map((t) => '"${t.replaceAll('"', '""')}"').join(' OR ');
db.select('SELECT rowid FROM notes WHERE notes MATCH ?', [match]);
```

### `highlight()` and `snippet()`

Tokens carry byte offsets into the original text, so both return marked-up source rather than index
terms. Reaching that text requires a normal or
[external content](https://sqlite.org/fts5.html#external_content_tables) table; on a `content=''`
table SQLite returns `NULL`.

### Options

Options follow the tokenizer name as `key value` pairs, and are stored with the table — changing
them means reindexing. An unrecognised option fails the `CREATE VIRTUAL TABLE`.

| Option | Default | |
|---|---|---|
| `search` | `1` | Index the long word together with its dictionary sub-words. `0` indexes the long word alone, for a smaller index where `长江大桥` matches only in full. |
| `hmm` | `1` | Fall back to jieba's HMM model for words outside the dictionary. `0` keeps segmentation to dictionary entries. |

```sql
CREATE VIRTUAL TABLE notes USING fts5(body, tokenize='jieba search 0');
```

`jieba_cut(text, options)` takes the same string, so a query can be cut the way its table was
indexed. `jieba_version()` returns the package version.

## Behaviour

Input is split at whitespace and wherever Han meets non-Han.

- **Han runs** go through jieba in search mode: the long word and its dictionary sub-words are both
  indexed, sub-words marked `FTS5_TOKEN_COLOCATED`. `今天天气` is findable as `今天天气`, `今天` and
  `天气`.
- **Everything else** uses Unicode UAX#29 word boundaries, lowercased. Terms are indexed as
  written, so `runs` and `running` stay separate.
- Runs with no letter or digit are dropped, matching `unicode61`.
- Documents and queries take the identical path, so phrase queries line up.

| Language | |
|---|---|
| Chinese | Full dictionary segmentation. |
| Any space-delimited script — Latin (incl. accents), Cyrillic, Greek, Arabic, Hebrew, Vietnamese | Word boundaries via UAX#29. |
| Korean | Splits at spaces, so `공원을` is one term and `공원` finds it through a prefix query. |
| Japanese | Han runs use the *Chinese* dictionary and kana has no UAX#29 boundaries; `trigram` does better. |
| Thai, Lao, Khmer, Burmese | These scripts need their own dictionary; use `trigram`. |

## How it works

An FTS5 tokenizer has to be a C-ABI loadable extension, since `fts5_api` is only reachable from
inside one. So this is a Rust `cdylib` with a small C shim, whose entry point Dart hands to
`sqlite3_auto_extension` via `package:sqlite3`'s `SqliteExtension`. The 5 MB jieba dictionary is
DEFLATE-compressed into the binary.

The shim registers as an `fts5_tokenizer_v2` when the host offers `fts5_api.iVersion >= 3`
(SQLite 3.47+), which is what makes `locale=1` tables work, and as the legacy `fts5_tokenizer`
below that. Each interface is probed at load time, so one binary covers an old system SQLite and a
current `sqlite3_flutter_libs` alike.

## License

MIT. Bundles [jieba-rs](https://github.com/messense/jieba-rs) (MIT) and its dictionary, and
[unicode-segmentation](https://github.com/unicode-rs/unicode-segmentation) (MIT/Apache-2.0).
