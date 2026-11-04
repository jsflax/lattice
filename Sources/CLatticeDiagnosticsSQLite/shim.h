#include <sqlite3.h>
#include <stddef.h>

/* Swift cannot call sqlite3_db_config's variadic interface. */
static inline int lattice_sqlite_disable_dqs(sqlite3 *db) {
    return sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DML, 0, NULL);
}
