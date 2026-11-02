// Mechanism probe, not a proposed public API or production busy handler.
// Demonstrates operation-owned cancellation on a serialized shared writer,
// preserving an unrelated writer on the same connection.
#include <sqlite3.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <unistd.h>

using clock_type = std::chrono::steady_clock;
struct cancelled_work {
    std::atomic<bool> requested{false};
    std::mutex mutex;
    std::condition_variable cv;
    bool in_busy_handler = false;
};
struct busy_scope {
    static thread_local busy_scope* current;
    sqlite3* db;
    sqlite3_mutex* mutex;
    cancelled_work& work;
    int restore_ms;
    clock_type::time_point deadline;
    busy_scope(sqlite3* db, cancelled_work& work, int timeout)
        : db(db), mutex(sqlite3_db_mutex(db)), work(work), restore_ms(timeout) {
        if (!mutex || sqlite3_mutex_try(mutex) != SQLITE_OK) std::_Exit(10);
        if (!sqlite3_get_autocommit(db) || current) std::_Exit(11);
        current = this;
    }
    ~busy_scope() {
        sqlite3_busy_timeout(db, restore_ms);
        current = nullptr;
        sqlite3_mutex_leave(mutex);
    }
    static int busy(void* raw, int) {
        auto& scope = *static_cast<busy_scope*>(raw);
        {
            std::lock_guard<std::mutex> lock(scope.work.mutex);
            scope.work.in_busy_handler = true;
            scope.work.cv.notify_all();
        }
        if (scope.work.requested.load() || clock_type::now() >= scope.deadline) return 0;
        sqlite3_sleep(5);
        return !scope.work.requested.load() && clock_type::now() < scope.deadline;
    }
};
thread_local busy_scope* busy_scope::current = nullptr;

// All internal busy-budget changes need this seam. It deliberately retains
// SQLite's own handler outside the owned operation.
void configure_busy(sqlite3* db, int budget_ms) {
    auto* scope = busy_scope::current;
    if (!scope || scope->db != db) {
        sqlite3_busy_timeout(db, budget_ms);
        return;
    }
    scope->deadline = clock_type::now() + std::chrono::milliseconds(budget_ms);
    sqlite3_busy_handler(db, busy_scope::busy, scope);
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    alarm(10);
    sqlite3* holder = nullptr;
    sqlite3* shared = nullptr;
    if (sqlite3_open_v2(argv[1], &holder, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr) != SQLITE_OK ||
        sqlite3_open_v2(argv[1], &shared, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nullptr) != SQLITE_OK) return 3;
    if (sqlite3_exec(holder, "PRAGMA journal_mode=WAL; CREATE TABLE t(v); BEGIN IMMEDIATE;", nullptr, nullptr, nullptr) != SQLITE_OK) return 4;
    constexpr int original_budget_ms = 2000;
    sqlite3_busy_timeout(shared, original_budget_ms);
    cancelled_work work;
    std::atomic<int> maintenance_result{SQLITE_OK};
    std::atomic<int> app_result{SQLITE_ERROR};
    std::atomic<bool> app_started{false};
    clock_type::time_point settled;
    std::thread maintenance([&] {
        {
            busy_scope scope(shared, work, original_budget_ms);
            configure_busy(shared, original_budget_ms);
            // Model the internal BEGIN budget reset that otherwise destroys
            // an externally installed cancellation handler.
            configure_busy(shared, original_budget_ms - 1);
            maintenance_result = sqlite3_exec(shared, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr);
            // A real database::begin_transaction must check cancellation here
            // before considering SQLITE_BUSY/LOCKED a reason to retry.
        }
        settled = clock_type::now();
    });
    {
        std::unique_lock<std::mutex> lock(work.mutex);
        if (!work.cv.wait_for(lock, std::chrono::seconds(5), [&] { return work.in_busy_handler; })) std::_Exit(5);
    }
    std::thread app([&] {
        app_started = true;
        app_result = sqlite3_exec(shared, "INSERT INTO t VALUES(7)", nullptr, nullptr, nullptr);
    });
    while (!app_started) std::this_thread::yield();
    const auto cancelled = clock_type::now();
    work.requested = true;
    maintenance.join();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(settled - cancelled).count();
    const bool holder_preserved = !sqlite3_get_autocommit(holder);
    // Keep the external writer after maintenance ends. The unrelated app
    // statement must retain its normal wait and succeed when this releases.
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    sqlite3_exec(holder, "ROLLBACK", nullptr, nullptr, nullptr);
    app.join();
    sqlite3_stmt* query = nullptr;
    sqlite3_prepare_v2(shared, "PRAGMA busy_timeout", -1, &query, nullptr);
    const int timeout = sqlite3_step(query) == SQLITE_ROW ? sqlite3_column_int(query, 0) : -1;
    sqlite3_finalize(query);
    std::printf("{\"sqlite_version\":\"%s\",\"maintenance_result\":%d,\"cancel_to_settled_ms\":%lld,\"holder_preserved\":%s,\"unrelated_app_result\":%d,\"restored_busy_timeout_ms\":%d}\n",
        sqlite3_libversion(), maintenance_result.load(), static_cast<long long>(elapsed),
        holder_preserved ? "true" : "false", app_result.load(), timeout);
    sqlite3_close(shared);
    sqlite3_close(holder);
    alarm(0);
    return maintenance_result == SQLITE_BUSY && holder_preserved && app_result == SQLITE_OK &&
           timeout == original_budget_ms && elapsed < original_budget_ms ? 0 : 1;
}
