/*
** An FTS5 tokenizer named "jieba", plus jieba_cut() and jieba_version()
** scalar functions.
**
** Only the SQLite plumbing lives here, because fts5_api is reachable only from
** inside a loadable extension. Segmentation is in Rust (src/segment.rs).
**
** Built against the SQLite headers vendored in this directory; see README.md
** for their provenance.
*/
#include "sqlite3ext.h"
#include "fts5.h"

#include <string.h>

SQLITE_EXTENSION_INIT1

/*
** SQLITE_INNOCUOUS (3.31.0) is the newest interface used here. Older libraries
** reject it from sqlite3_create_function_v2() with SQLITE_MISUSE, so refuse up
** front with a message that says why.
*/
#define JIEBA_MIN_SQLITE_VERSION 3031000

/* Tokenizer options, mirrored by JiebaOptions in src/segment.rs. */
#define JIEBA_OPT_HMM 0x0001    /* HMM new-word discovery for unknown runs */
#define JIEBA_OPT_SEARCH 0x0002 /* emit dictionary sub-words, colocated */
#define JIEBA_OPT_DEFAULT (JIEBA_OPT_HMM | JIEBA_OPT_SEARCH)

typedef int (*JiebaEmit)(void *pCtx, int tflags, const char *pToken, int nToken,
                         int iStart, int iEnd);

/* Implemented in Rust. */
int sqlite3_jieba_tokenize(const char *pText, int nText, int opts, void *pCtx,
                           JiebaEmit emit);
char *sqlite3_jieba_cut_json(const char *pText, int nText, int opts);
void sqlite3_jieba_free_json(char *p);
const char *sqlite3_jieba_version(void);

typedef struct JiebaTokenizer JiebaTokenizer;
struct JiebaTokenizer {
  int opts;
};

/*
** One "key value" option pair, as it appears after the tokenizer name in
** CREATE VIRTUAL TABLE or in the second argument to jieba_cut().
*/
static int jiebaOption(const char *zKey, const char *zVal, int *pOpts) {
  int bit;
  if (sqlite3_stricmp(zKey, "hmm") == 0) {
    bit = JIEBA_OPT_HMM;
  } else if (sqlite3_stricmp(zKey, "search") == 0) {
    bit = JIEBA_OPT_SEARCH;
  } else {
    return SQLITE_ERROR;
  }
  if (sqlite3_stricmp(zVal, "1") == 0) {
    *pOpts |= bit;
  } else if (sqlite3_stricmp(zVal, "0") == 0) {
    *pOpts &= ~bit;
  } else {
    return SQLITE_ERROR;
  }
  return SQLITE_OK;
}

static int jiebaOptions(const char **azArg, int nArg, int *pOpts) {
  int i;
  int opts = JIEBA_OPT_DEFAULT;
  /* Unknown or malformed options are an error, as they are for unicode61:
  ** silently ignoring them would index a table differently than it reads. */
  if (nArg % 2) return SQLITE_ERROR;
  for (i = 0; i < nArg; i += 2) {
    if (azArg[i] == 0 || azArg[i + 1] == 0) return SQLITE_ERROR;
    if (jiebaOption(azArg[i], azArg[i + 1], &opts) != SQLITE_OK) {
      return SQLITE_ERROR;
    }
  }
  *pOpts = opts;
  return SQLITE_OK;
}

static int jiebaCreate(void *pUnused, const char **azArg, int nArg,
                       Fts5Tokenizer **ppOut) {
  JiebaTokenizer *p;
  int opts = JIEBA_OPT_DEFAULT;
  (void)pUnused;
  if (jiebaOptions(azArg, nArg, &opts) != SQLITE_OK) return SQLITE_ERROR;
  p = (JiebaTokenizer *)sqlite3_malloc(sizeof(*p));
  if (p == 0) return SQLITE_NOMEM;
  p->opts = opts;
  *ppOut = (Fts5Tokenizer *)p;
  return SQLITE_OK;
}

static void jiebaDelete(Fts5Tokenizer *p) { sqlite3_free(p); }

static int jiebaTokenizeV2(Fts5Tokenizer *pTokenizer, void *pCtx, int flags,
                           const char *pText, int nText, const char *pLocale,
                           int nLocale,
                           int (*xToken)(void *, int, const char *, int, int,
                                         int)) {
  /* Documents and queries take the same path, which is what keeps their
  ** positions lined up. Segmentation is dictionary-driven, not locale-driven,
  ** so the locale is accepted and ignored. */
  (void)flags;
  (void)pLocale;
  (void)nLocale;
  if (nText <= 0 || pText == 0) return SQLITE_OK;
  return sqlite3_jieba_tokenize(pText, nText,
                                ((JiebaTokenizer *)pTokenizer)->opts, pCtx,
                                xToken);
}

static int jiebaTokenizeV1(Fts5Tokenizer *pTokenizer, void *pCtx, int flags,
                           const char *pText, int nText,
                           int (*xToken)(void *, int, const char *, int, int,
                                         int)) {
  return jiebaTokenizeV2(pTokenizer, pCtx, flags, pText, nText, 0, 0, xToken);
}

static void jiebaFreeJson(void *p) { sqlite3_jieba_free_json((char *)p); }

/*
** Apply a "key value key value" option string, the same text that follows the
** tokenizer name in CREATE VIRTUAL TABLE.
*/
static int jiebaOptionString(const char *z, int *pOpts) {
  char *zCopy = sqlite3_mprintf("%s", z);
  const char **az;
  int nArg = 0;
  int i = 0;
  int rc;

  if (zCopy == 0) return SQLITE_NOMEM;
  /* Comfortably more entries than there can be space-delimited words. */
  az = (const char **)sqlite3_malloc((int)((strlen(zCopy) + 2) * sizeof(*az)));
  if (az == 0) {
    sqlite3_free(zCopy);
    return SQLITE_NOMEM;
  }
  while (zCopy[i]) {
    while (zCopy[i] == ' ') i++;
    if (zCopy[i] == 0) break;
    az[nArg++] = &zCopy[i];
    while (zCopy[i] && zCopy[i] != ' ') i++;
    if (zCopy[i]) zCopy[i++] = 0;
  }
  rc = jiebaOptions(az, nArg, pOpts);
  sqlite3_free((void *)az);
  sqlite3_free(zCopy);
  return rc;
}

/*
** jieba_cut(text) / jieba_cut(text, options): the distinct tokens of text as a
** JSON array. The second form takes the same options as the tokenizer, so a
** query can be cut the way its table was indexed.
*/
static void jiebaCutFunc(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  const unsigned char *text;
  int nText;
  char *json;
  int opts = JIEBA_OPT_DEFAULT;

  if (argc == 2) {
    const char *zOpts = (const char *)sqlite3_value_text(argv[1]);
    int rc;
    if (zOpts == 0) {
      sqlite3_result_error(ctx, "jieba_cut: options must not be NULL", -1);
      return;
    }
    rc = jiebaOptionString(zOpts, &opts);
    if (rc == SQLITE_NOMEM) {
      sqlite3_result_error_nomem(ctx);
      return;
    }
    if (rc != SQLITE_OK) {
      sqlite3_result_error(ctx, "jieba_cut: unrecognised options", -1);
      return;
    }
  }

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
  json = sqlite3_jieba_cut_json((const char *)text, nText, opts);
  if (json == 0) {
    sqlite3_result_error_nomem(ctx);
    return;
  }
  sqlite3_result_text(ctx, json, -1, jiebaFreeJson);
}

/* jieba_version(): this extension's semantic version. */
static void jiebaVersionFunc(sqlite3_context *ctx, int argc,
                             sqlite3_value **argv) {
  (void)argc;
  (void)argv;
  sqlite3_result_text(ctx, sqlite3_jieba_version(), -1, SQLITE_STATIC);
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

static int jiebaError(char **pzErrMsg, const char *zFormat, ...) {
  va_list ap;
  if (pzErrMsg) {
    va_start(ap, zFormat);
    *pzErrMsg = sqlite3_vmprintf(zFormat, ap);
    va_end(ap);
  }
  return SQLITE_ERROR;
}

/* Re-exported as sqlite3_jieba_init by src/lib.rs. */
int sqlite3_jieba_init_impl(sqlite3 *db, char **pzErrMsg,
                            const sqlite3_api_routines *pApi) {
  /* iVersion 2 is the current fts5_tokenizer_v2 revision. */
  static fts5_tokenizer_v2 tokenizerV2 = {2, jiebaCreate, jiebaDelete,
                                          jiebaTokenizeV2};
  static fts5_tokenizer tokenizerV1 = {jiebaCreate, jiebaDelete,
                                       jiebaTokenizeV1};
  fts5_api *pFts5;
  int rc;
  int i;
  SQLITE_EXTENSION_INIT2(pApi);

  if (sqlite3_libversion_number() < JIEBA_MIN_SQLITE_VERSION) {
    return jiebaError(pzErrMsg, "jieba: SQLite %s is too old, need 3.31.0+",
                      sqlite3_libversion());
  }

  pFts5 = jiebaFts5Api(db);
  if (pFts5 == 0) {
    return jiebaError(pzErrMsg,
                      "jieba: fts5_api unavailable (is FTS5 compiled in?)");
  }

  /* fts5_api.iVersion >= 3 (SQLite 3.47.0) is where xCreateTokenizer_v2 and
  ** locale-aware tokenizers arrived. Register as v2 when the host supports it
  ** so that fts5_locale() columns work, and fall back to the legacy object
  ** otherwise; both behave identically here. */
  if (pFts5->iVersion >= 3) {
    rc = pFts5->xCreateTokenizer_v2(pFts5, "jieba", 0, &tokenizerV2, 0);
  } else {
    rc = pFts5->xCreateTokenizer(pFts5, "jieba", 0, &tokenizerV1, 0);
  }
  if (rc != SQLITE_OK) {
    return jiebaError(pzErrMsg, "jieba: could not register tokenizer (%d)", rc);
  }

  for (i = 1; i <= 2; i++) {
    rc = sqlite3_create_function_v2(
        db, "jieba_cut", i,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, 0, jiebaCutFunc,
        0, 0, 0);
    if (rc != SQLITE_OK) {
      return jiebaError(pzErrMsg, "jieba: could not register jieba_cut/%d (%d)",
                        i, rc);
    }
  }
  rc = sqlite3_create_function_v2(
      db, "jieba_version", 0,
      SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, 0,
      jiebaVersionFunc, 0, 0, 0);
  if (rc != SQLITE_OK) {
    return jiebaError(pzErrMsg, "jieba: could not register jieba_version (%d)",
                      rc);
  }
  return SQLITE_OK;
}
