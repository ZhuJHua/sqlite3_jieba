import 'package:sqlite3/sqlite3.dart';

import 'bindings.dart';

/// Registers the `jieba` FTS5 tokenizer and the `jieba_cut()` function.
extension JiebaExtension on Sqlite3 {
  /// Makes `tokenize='jieba'` and `jieba_cut()` available on every connection
  /// opened from here on, including connections on other isolates.
  ///
  /// Goes through `sqlite3_auto_extension`, which is **process-level** state,
  /// so it must run *before* the first connection you want it on. Calling it
  /// more than once is harmless.
  void registerJiebaTokenizer() {
    ensureExtensionLoaded(SqliteExtension(jiebaInitAddress()));
  }
}

var _loaded = false;

/// [JiebaExtension.registerJiebaTokenizer] on the default [sqlite3] instance,
/// executed at most once.
void loadJiebaTokenizer() {
  if (_loaded) return;
  sqlite3.registerJiebaTokenizer();
  _loaded = true;
}
