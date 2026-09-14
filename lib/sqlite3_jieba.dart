/// A jieba-backed FTS5 tokenizer for SQLite.
///
/// Call [loadJiebaTokenizer] once before opening the database you want to
/// search, then declare the virtual table with `tokenize='jieba'`:
///
/// ```dart
/// import 'package:sqlite3/sqlite3.dart';
/// import 'package:sqlite3_jieba/sqlite3_jieba.dart';
///
/// loadJiebaTokenizer();
/// final db = sqlite3.openInMemory();
/// db.execute("CREATE VIRTUAL TABLE notes USING fts5(body, tokenize='jieba')");
/// ```
///
/// Tokens carry byte offsets into the original text, so `highlight()` and
/// `snippet()` return marked-up source rather than index terms.
library;

export 'src/loader.dart';
