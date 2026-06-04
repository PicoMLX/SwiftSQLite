#ifndef CSQLITE_SHIMS_H
#define CSQLITE_SHIMS_H

#include "sqlite3.h"

/*
 * Thin C shims over the parts of the SQLite API that Swift cannot call
 * directly. Kept tiny and committed (unlike sqlite3.c, which is fetched).
 */

/*
 * sqlite3_db_config() is variadic in C, and Swift cannot import C
 * variadic functions. Every boolean DB-config option we use
 * (SQLITE_DBCONFIG_DEFENSIVE, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION,
 * SQLITE_DBCONFIG_TRUSTED_SCHEMA, …) takes the same `(int onoff, int *pRes)`
 * argument shape, so a single fixed-signature wrapper covers them all.
 *
 * Returns the underlying sqlite3_db_config() result code.
 */
int csqlite_db_config_onoff(sqlite3 *db, int op, int onoff);

#endif /* CSQLITE_SHIMS_H */
