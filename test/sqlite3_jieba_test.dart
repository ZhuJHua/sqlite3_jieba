import 'dart:convert';
import 'dart:io';

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

List<String> cut(Database db, String text, [String? options]) {
  final row = options == null
      ? db.select('SELECT jieba_cut(?) AS t', [text])
      : db.select('SELECT jieba_cut(?, ?) AS t', [text, options]);
  return (json.decode(row.single['t'] as String) as List).cast<String>();
}

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

  group('jieba_version', () {
    test('matches the version pub ships', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      final reported = db.select('SELECT jieba_version() AS v').single['v'];
      final declared = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
      expect(
        reported,
        declared,
        reason: 'the Rust crate version and pubspec version have drifted',
      );
    });
  });

  group('locale-aware tables', () {
    test('a locale=1 table indexes and matches', () {
      // fts5_locale() needs fts5_api.iVersion >= 3, which is also what selects
      // the v2 tokenizer registration in the shim.
      if (sqlite3.version.versionNumber < 3047000) {
        markTestSkipped(
          'SQLite ${sqlite3.version.libVersion} predates fts5 v2',
        );
        return;
      }
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db
        ..execute(
          "CREATE VIRTUAL TABLE t USING fts5(a, tokenize='jieba', locale=1)",
        )
        ..execute("INSERT INTO t(a) VALUES (fts5_locale('zh_CN', ?))", [
          '今天天气很好',
        ]);
      expect(
        db.select('SELECT rowid FROM t WHERE t MATCH ?', ['"天气"']),
        hasLength(1),
      );
    });
  });

  group('tokenizer options', () {
    late Database db;
    setUp(() => db = sqlite3.openInMemory());
    tearDown(() => db.close());

    test('search 0 indexes only the long word', () {
      expect(cut(db, '南京市长江大桥'), contains('南京'));
      expect(cut(db, '南京市长江大桥', 'search 0'), ['南京市', '长江大桥']);
    });

    test('rejects unknown options', () {
      expect(
        () => db.execute(
          "CREATE VIRTUAL TABLE t USING fts5(a, tokenize='jieba nope 1')",
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(
        () => db.execute(
          "CREATE VIRTUAL TABLE t USING fts5(a, tokenize='jieba search')",
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(() => cut(db, '公园', 'nope 1'), throwsA(isA<SqliteException>()));
    });

    test('a table built with search 0 does not match sub-words', () {
      db
        ..execute(
          "CREATE VIRTUAL TABLE t USING fts5(a, tokenize='jieba search 0')",
        )
        ..execute('INSERT INTO t(a) VALUES (?)', ['南京市长江大桥']);

      List<Object?> hits(String q) => db
          .select('SELECT rowid FROM t WHERE t MATCH ?', [q])
          .map((r) => r['rowid'])
          .toList();

      expect(hits('"长江大桥"'), [1]);
      expect(hits('"长江"'), isEmpty);
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
  });
}
