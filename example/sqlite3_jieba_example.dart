import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_jieba/sqlite3_jieba.dart';

void main() {
  // Process-level registration: must happen before the connection is opened.
  loadJiebaTokenizer();

  final db = sqlite3.openInMemory();
  db
    ..execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)')
    // External content, so highlight()/snippet() can reach the original text.
    ..execute(
      "CREATE VIRTUAL TABLE notes_fts USING fts5("
      "body, content='notes', content_rowid='id', tokenize='jieba')",
    )
    ..execute('''
      CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
        INSERT INTO notes_fts(rowid, body) VALUES (new.id, new.body);
      END;
    ''');

  for (final body in [
    '今天天气很好，我去公园散步了',
    '昨天在南京市长江大桥拍了照片',
    'Went to Starbucks, the coffee was fine',
  ]) {
    db.execute('INSERT INTO notes(body) VALUES (?)', [body]);
  }

  // Build the MATCH string from the same vocabulary the index uses.
  const query = '公园散步';
  final tokens =
      (jsonDecode(
                db.select('SELECT jieba_cut(?) AS t', [query]).single['t']
                    as String,
              )
              as List)
          .cast<String>();
  print('tokens: $tokens');

  final match = tokens.map((t) => '"${t.replaceAll('"', '""')}"').join(' OR ');
  final rows = db.select(
    "SELECT highlight(notes_fts, 0, '[', ']') AS hit "
    'FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts)',
    [match],
  );
  for (final row in rows) {
    print(row['hit']);
  }

  db.close();
}
