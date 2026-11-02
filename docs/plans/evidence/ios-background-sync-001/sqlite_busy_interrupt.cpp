// Small dependency-free probe for the assumption that sqlite3_interrupt()
// promptly ends SQLite's default busy handler. Build/run commands in README.md.
#include <sqlite3.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <unistd.h>

struct trace_gate {
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
};

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    alarm(10);
    sqlite3* holder = nullptr;
    sqlite3* waiter = nullptr;
    if (sqlite3_open(argv[1], &holder) != SQLITE_OK ||
        sqlite3_open(argv[1], &waiter) != SQLITE_OK) return 3;
    if (sqlite3_exec(holder, "PRAGMA journal_mode=WAL; CREATE TABLE t(v); BEGIN IMMEDIATE;", nullptr, nullptr, nullptr) != SQLITE_OK)
        return 4;
    constexpr int busy_budget_ms = 2000;
    sqlite3_busy_timeout(waiter, busy_budget_ms);
    trace_gate gate;
    sqlite3_trace_v2(waiter, SQLITE_TRACE_STMT,
        [](unsigned, void* raw, void*, void*) -> int {
            auto& gate = *static_cast<trace_gate*>(raw);
            std::lock_guard<std::mutex> lock(gate.mutex);
            gate.entered = true;
            gate.cv.notify_all();
            return 0;
        }, &gate);
    std::atomic<int> result{SQLITE_OK};
    std::chrono::steady_clock::time_point ended;
    std::thread blocked([&] {
        result.store(sqlite3_exec(waiter, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr));
        ended = std::chrono::steady_clock::now();
    });
    {
        std::unique_lock<std::mutex> lock(gate.mutex);
        if (!gate.cv.wait_for(lock, std::chrono::seconds(5), [&] { return gate.entered; })) std::_Exit(5);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const auto interrupted = std::chrono::steady_clock::now();
    sqlite3_interrupt(waiter);
    blocked.join();
    const auto latency = std::chrono::duration_cast<std::chrono::milliseconds>(ended - interrupted).count();
    const bool holder_preserved = !sqlite3_get_autocommit(holder);
    sqlite3_exec(holder, "ROLLBACK", nullptr, nullptr, nullptr);
    const int retry = sqlite3_exec(waiter, "BEGIN IMMEDIATE; ROLLBACK;", nullptr, nullptr, nullptr);
    std::printf("{\"sqlite_version\":\"%s\",\"busy_budget_ms\":%d,\"result\":%d,\"interrupt_to_return_ms\":%lld,\"holder_preserved\":%s,\"retry_result\":%d}\n",
        sqlite3_libversion(), busy_budget_ms, result.load(), static_cast<long long>(latency),
        holder_preserved ? "true" : "false", retry);
    sqlite3_close(waiter);
    sqlite3_close(holder);
    alarm(0);
    return result.load() != SQLITE_OK && holder_preserved && retry == SQLITE_OK ? 0 : 1;
}
