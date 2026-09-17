# Vendored SQLite headers

`sqlite3.h`, `sqlite3ext.h` and `fts5.h` are copied verbatim from the SQLite
amalgamation. They are headers only — no SQLite code is compiled or linked
here. The extension binds to whatever SQLite `package:sqlite3` loads at
runtime, through the `sqlite3_api_routines` table.

| | |
|---|---|
| Version | 3.53.4 |
| Version number | 3053004 |
| Source ID | `2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc` |
| Source | <https://sqlite.org/download.html> (`sqlite-amalgamation-3530400.zip`) |

These set the *ceiling* of what the shim can reference, not the floor. The
runtime floor is `JIEBA_MIN_SQLITE_VERSION` in `shim.c` (3.31.0, where
`SQLITE_INNOCUOUS` appeared), checked at load time. Anything newer is probed
rather than assumed — `fts5_api.iVersion >= 3` selects `xCreateTokenizer_v2`.

To update: drop in the three headers from a newer amalgamation, refresh the
table above, and confirm `JIEBA_MIN_SQLITE_VERSION` still covers every
interface `shim.c` uses.
