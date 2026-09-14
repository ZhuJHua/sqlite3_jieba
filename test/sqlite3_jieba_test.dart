import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_jieba/sqlite3_jieba.dart';
import 'package:test/test.dart';

/// An external content FTS5 table over a source table — the setup where
/// highlight() and snippet() can reach the original text.
Database openWithIndex() {
  final db = sqlite3.openInMemory();
  db
    ..execute(
      'CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, '
      'body TEXT NOT NULL)',
    )
    ..execute('''
      CREATE VIRTUAL TABLE notes_fts USING fts5(
        title, body,
        content='notes', content_rowid='id',
        tokenize='jieba', prefix='2'
      );
    ''')
    ..execute('''
      CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
        INSERT INTO notes_fts(rowid, title, body)
          VALUES (new.id, new.title, new.body);
      END;
    ''')
    ..execute('''
      CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, title, body)
          VALUES ('delete', old.id, old.title, old.body);
      END;
    ''');
  return db;
}

void insert(Database db, int id, String title, String body) => db.execute(
  'INSERT INTO notes(id, title, body) VALUES (?, ?, ?)',
  [id, title, body],
);

List<int> match(Database db, String query) => db
    .select('SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?', [query])
    .map((r) => r['rowid'] as int)
    .toList();

List<String> cut(Database db, String text) =>
    (json.decode(
              db.select('SELECT jieba_cut(?) AS t', [text]).single['t']
                  as String,
            )
            as List)
        .cast<String>();

void main() {
  setUpAll(loadJiebaTokenizer);

  group('jieba_cut', () {
    late Database db;
    setUp(() => db = sqlite3.openInMemory());
    tearDown(() => db.close());

    test('splits Chinese and drops punctuation', () {
      final tokens = cut(db, '今天天气很好，我去公园散步了');
      expect(tokens, contains('今天天气'));
      expect(tokens, contains('公园'));
      expect(tokens, contains('散步'));
      expect(tokens, isNot(contains('，')));
    });

    test('keeps accented Latin words whole and lowercases them', () {
      expect(cut(db, 'Das Wetter ist schön'), contains('schön'));
      expect(cut(db, 'Сегодня хорошая погода'), contains('хорошая'));
      expect(cut(db, 'Running'), ['running']);
    });

    test('returns an empty array for NULL and empty input', () {
      expect(cut(db, ''), isEmpty);
      expect(
        json.decode(
          db.select('SELECT jieba_cut(NULL) AS t').single['t'] as String,
        ),
        isEmpty,
      );
    });
  });

  group('tokenizer', () {
    late Database db;
    setUp(() => db = openWithIndex());
    tearDown(() => db.close());

    test('matches both whole words and their sub-words', () {
      insert(db, 1, '周末记事', '今天天气很好，我去公园散步了');
      insert(db, 2, '加班', '连着两周都在加班，累');

      expect(match(db, '"今天天气"'), [1]);
      expect(match(db, '"天气"'), [1], reason: 'sub-words are indexed colocated');
      expect(match(db, '"公园" OR "加班"'), [1, 2]);
      expect(match(db, '"梨子"'), isEmpty);
    });

    test('highlight and snippet return marked-up source text', () {
      insert(db, 1, '关于苹果的日记', '早上吃了一个苹果，味道不错，然后去上班了');

      final row = db.select(
        "SELECT highlight(notes_fts, 0, '[', ']') AS t, "
        "snippet(notes_fts, 1, '[', ']', '…', 8) AS s "
        'FROM notes_fts WHERE notes_fts MATCH ?',
        ['"苹果"'],
      ).single;

      expect(row['t'], '关于[苹果]的日记');
      expect(row['s'], contains('[苹果]'));
      expect(row['s'], contains('味道'));
    });

    test('offsets survive mixed scripts and emoji', () {
      insert(db, 1, '', '今天去了 Starbucks 🎉 感觉 coffee 不错');
      final marked = db.select(
        "SELECT highlight(notes_fts, 1, '[', ']') AS t "
        'FROM notes_fts WHERE notes_fts MATCH ?',
        ['"coffee"'],
      ).single['t'];
      expect(marked, '今天去了 Starbucks 🎉 感觉 [coffee] 不错');
    });

    test('search is case insensitive for Latin', () {
      insert(db, 1, '', 'I went to Starbucks');
      expect(match(db, '"starbucks"'), [1]);
    });

    test('bm25 column weights order the results', () {
      insert(db, 1, '普通的一天', '中午吃了苹果，下午继续写代码，晚上散步回家');
      insert(db, 2, '苹果', '随便写点什么');
      final ranked = db.select(
        'SELECT rowid FROM notes_fts WHERE notes_fts MATCH ? '
        'ORDER BY bm25(notes_fts, 1.5, 1.0)',
        ['"苹果"'],
      );
      expect(ranked.map((r) => r['rowid']), [2, 1]);
    });

    test('prefix queries work', () {
      insert(db, 1, '', '在北京出差三天');
      expect(match(db, '北京*'), [1]);
    });

    test('delete triggers remove the row from the index', () {
      insert(db, 1, '', '苹果香蕉');
      db.execute('DELETE FROM notes WHERE id = 1');
      expect(match(db, '"苹果"'), isEmpty);
    });

    test("'rebuild' reindexes from the content table", () {
      insert(db, 1, '', '苹果香蕉');
      db
        ..execute('DROP TRIGGER notes_ai')
        ..execute('INSERT INTO notes(id, title, body) VALUES (2, ?, ?)', [
          '',
          '梨子',
        ]);
      expect(match(db, '"梨子"'), isEmpty);

      db.execute("INSERT INTO notes_fts(notes_fts) VALUES('rebuild')");
      expect(match(db, '"梨子"'), [2]);
    });
  });
}
