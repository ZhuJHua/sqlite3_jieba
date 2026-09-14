/*
** An FTS5 tokenizer named "jieba", plus a jieba_cut() scalar function.
**
** Only the SQLite plumbing lives here: fts5_api is reachable only from inside a
** loadable extension, via SELECT fts5(?1) + sqlite3_bind_pointer. Segmentation
** itself is in Rust (src/segment.rs).
*/
#include "sqlite3ext.h"
#include "fts5.h"

SQLITE_EXTENSION_INIT1

typedef int (*JiebaEmit)(void *pCtx, int tflags, const char *pToken, int nToken,
                         int iStart, int iEnd);

/* Implemented in Rust. */
int sqlite3_jieba_tokenize(const char *pText, int nText, void *pCtx,
                           JiebaEmit emit);
char *sqlite3_jieba_cut_json(const char *pText, int nText);
void sqlite3_jieba_free_json(char *p);

static int jiebaCreate(void *pUnused, const char **azArg, int nArg,
                       Fts5Tokenizer **ppOut) {
  (void)pUnused;
  (void)azArg;
  (void)nArg;
  /* Stateless: the dictionary lives in a process-wide OnceLock on the Rust
  ** side, so the handle only has to be non-NULL. */
  *ppOut = (Fts5Tokenizer *)ppOut;
  return SQLITE_OK;
}

static void jiebaDelete(Fts5Tokenizer *p) { (void)p; }

static int jiebaTokenize(Fts5Tokenizer *pTokenizer, void *pCtx, int flags,
                         const char *pText, int nText,
                         int (*xToken)(void *, int, const char *, int, int,
                                       int)) {
  (void)pTokenizer;
  /* Documents and queries take the same path: matching positions on both sides
  ** is what keeps phrases and colocated alternatives lining up. */
  (void)flags;
  if (nText <= 0 || pText == 0) return SQLITE_OK;
  return sqlite3_jieba_tokenize(pText, nText, pCtx, xToken);
}

static void jiebaCutFunc(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  const unsigned char *text;
  int nText;
  char *json;
  (void)argc;
  if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
    sqlite3_result_text(ctx, "[]", -1, SQLITE_STATIC);
    return;
  }
  text = sqlite3_value_text(argv[0]);
  nText = sqlite3_value_bytes(argv[0]);
  if (text == 0 || nText <= 0) {
    sqlite3_result_text(ctx, "[]", -1, SQLITE_STATIC);
    return;
  }
  json = sqlite3_jieba_cut_json((const char *)text, nText);
  if (json == 0) {
    sqlite3_result_error_nomem(ctx);
    return;
  }
  sqlite3_result_text(ctx, json, -1, SQLITE_TRANSIENT);
  sqlite3_jieba_free_json(json);
}

/* https://sqlite.org/fts5.html#extending_fts5 */
static fts5_api *jiebaFts5Api(sqlite3 *db) {
  fts5_api *pRet = 0;
  sqlite3_stmt *pStmt = 0;
  if (SQLITE_OK == sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &pStmt, 0)) {
    sqlite3_bind_pointer(pStmt, 1, (void *)&pRet, "fts5_api_ptr", 0);
    sqlite3_step(pStmt);
  }
  sqlite3_finalize(pStmt);
  return pRet;
}

/* Re-exported as sqlite3_jieba_init by src/lib.rs — routing the entry point
** through Rust is what keeps the linker from dropping this object file out of
** the cdylib, and gives Dart a #[no_mangle] symbol to take the address of. */
int sqlite3_jieba_init_impl(sqlite3 *db, char **pzErrMsg,
                            const sqlite3_api_routines *pApi) {
  static fts5_tokenizer tokenizer = {jiebaCreate, jiebaDelete, jiebaTokenize};
  fts5_api *pFts5;
  int rc;
  SQLITE_EXTENSION_INIT2(pApi);

  pFts5 = jiebaFts5Api(db);
  if (pFts5 == 0) {
    *pzErrMsg =
        sqlite3_mprintf("jieba: fts5_api unavailable (is FTS5 compiled in?)");
    return SQLITE_ERROR;
  }
  rc = pFts5->xCreateTokenizer(pFts5, "jieba", 0, &tokenizer, 0);
  if (rc != SQLITE_OK) return rc;

  return sqlite3_create_function_v2(
      db, "jieba_cut", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS,
      0, jiebaCutFunc, 0, 0, 0);
}
