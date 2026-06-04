#include "csqlite_shims.h"

int csqlite_db_config_onoff(sqlite3 *db, int op, int onoff) {
    /* The boolean db-config options take `(int onoff, int *pRes)`; we
     * don't need the resolved value back, so pass a NULL out-pointer. */
    return sqlite3_db_config(db, op, onoff, (int *)0);
}
