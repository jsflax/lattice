#pragma once
// Diagnostic build only. No installed public API or storage when OFF.
#if defined(LATTICE_COLD_KEEPER_TIMING) && LATTICE_COLD_KEEPER_TIMING
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
namespace lattice::detail::cold_keeper_timing {
enum class phase : uint8_t {
    acquire_enter=1, eviction_done, pool_selected, victim_begin, victim_end,
    constructor_begin, constructor_end, cache_begin, cache_end,
    begin_begin, begin_end, pin_begin, pin_end, publication_begin,
    publication_end, acquire_exit, page_enter, page_admitted,
    sql_begin, sql_end, page_exit,
    open_begin, open_end, settings_end, vector_end,
    busy_begin, busy_end, foreign_keys_end, cache_end_setting, mmap_end, temp_end
};
struct record { int64_t ns=0; uint64_t fact=0; phase tag{}; };
struct snapshot {
    std::array<record,27> records{};
    std::size_t size=0;
    uint64_t generation=0;
    bool invalid=false, acquired=false, queried=false;
    bool acquire_success=false, page_success=false;
};
struct state {
    snapshot data{}; const void* owner=nullptr; bool armed=false;
    bool constructor_window=false, constructor_seen=false;
    const void* constructor=nullptr;
};
inline thread_local state local;
static_assert(sizeof(state)<4096, "bounded per-thread diagnostic storage");
inline void append(phase tag, uint64_t fact=0) noexcept {
    auto& data=local.data;
    if(data.size==data.records.size()) { data.invalid=true; return; }
    const auto now=std::chrono::steady_clock::now().time_since_epoch();
    data.records[data.size++]={std::chrono::duration_cast<std::chrono::nanoseconds>(now).count(),fact,tag};
}
// Caller brackets ONE acquisition and its first actual page on this thread.
// No allocation, log, SQL, callback or lock is used by the recorder.
inline bool arm(const void* owner) noexcept {
    if(local.armed || !owner) { local.data.invalid=true; return false; }
    local={};local.owner=owner;local.armed=true;return true;
}
inline snapshot finish() noexcept {
    if(local.constructor_window || local.constructor)local.data.invalid=true;
    local.armed=false;local.owner=nullptr;return local.data;
}
struct acquire_scope {
    bool enabled=false;
    explicit acquire_scope(const void* owner) noexcept {
        if(!local.armed || local.owner!=owner)return;
        if(local.data.acquired) { local.data.invalid=true;return; }
        enabled=true;local.data.acquired=true;append(phase::acquire_enter);
    }
    void mark(phase tag,uint64_t fact=0) const noexcept { if(enabled)append(tag,fact); }
    void success(uint64_t id) const noexcept {
        if(enabled) {local.data.generation=id;local.data.acquire_success=true;}
    }
    void begin_constructor() const noexcept {
        if(!enabled)return;
        if(local.constructor_window || local.constructor) {local.data.invalid=true;return;}
        local.constructor_window=true;local.constructor_seen=false;mark(phase::constructor_begin);
    }
    void end_constructor() const noexcept {
        if(!enabled)return;
        if(!local.constructor_window || !local.constructor_seen || local.constructor)local.data.invalid=true;
        local.constructor_window=false;mark(phase::constructor_end);
    }
    ~acquire_scope() noexcept {
        if(enabled && (local.constructor_window || local.constructor)) {
            local.data.invalid=true;local.constructor_window=false;local.constructor=nullptr;
        }
        mark(phase::acquire_exit,local.data.acquire_success?1:0);
    }
};
// Activated only between the outer marks around the private keeper factory.
// No ordinary/seed/owner constructor is recorded. Unexpected nested construction
// makes the sample unusable without changing the database operation itself.
struct constructor_scope {
    bool enabled=false; const void* identity=nullptr;
    constructor_scope(bool keeper,const void* instance) noexcept {
        if(!local.armed || !local.constructor_window)return;
        if(!keeper || !instance || local.constructor || local.constructor_seen) {
            local.data.invalid=true;return;
        }
        enabled=true;identity=instance;local.constructor=instance;local.constructor_seen=true;
    }
    void mark(phase tag,uint64_t fact=0) const noexcept {if(enabled)append(tag,fact);}
    ~constructor_scope() noexcept {
        if(!enabled)return;
        if(local.constructor!=identity)local.data.invalid=true;
        local.constructor=nullptr;
    }
};
struct page_scope {
    bool enabled=false;
    page_scope(const void* owner,uint64_t id) noexcept {
        if(!local.armed || local.owner!=owner)return;
        if(!local.data.acquire_success || id!=local.data.generation || local.data.queried) {
            local.data.invalid=true;return;
        }
        enabled=true;local.data.queried=true;append(phase::page_enter);
    }
    void mark(phase tag) const noexcept { if(enabled)append(tag); }
    void success() const noexcept { if(enabled)local.data.page_success=true; }
    ~page_scope() noexcept { if(enabled)append(phase::page_exit,local.data.page_success?1:0); }
};
} // namespace lattice::detail::cold_keeper_timing
#endif
