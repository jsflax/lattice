#include "automatic_setup_fixture.hpp"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

// These existing friends have no definition in a linked production target.
// The native test executable has its own, separate definitions. Keep the SDK
// definitions in this one test-only TU, out of the Swift-imported umbrella.
namespace lattice::detail {
struct sync_discovery_test_access {
    static std::shared_ptr<database> actual_writer(lattice_db& owner) {
        std::lock_guard lock(owner.connection_ownership_mutex_);
        if(owner.closed_.load(std::memory_order_acquire)||!owner.guard_||
           !owner.guard_->alive.load(std::memory_order_seq_cst))return {};
        return owner.db_;
    }
};
struct canonical_writer_custody_test_access {
    static sqlite3* actual_handle(database& writer) {return writer.internal_handle();}
};
}

namespace lattice::automatic_setup_test_support {
struct writer_mutex_hold::state {
    using clock=std::chrono::steady_clock;
    const clock::time_point acquireUntil=clock::now()+std::chrono::seconds(2);
    std::shared_ptr<database> writer;
    sqlite3_mutex* target=nullptr;
    mutable std::mutex mutex;
    std::condition_variable changed;
    std::mutex joinMutex;
    holder_facts observed;
    std::thread worker;

    explicit state(std::shared_ptr<database> actual):writer(std::move(actual)) {
        observed.workerFinished=false;observed.writerRetired=false;
    }
    void request_release() noexcept {
        {std::lock_guard lock(mutex);observed.releaseRequested=true;}
        changed.notify_all();
    }
    void finish_worker() noexcept {
        {std::lock_guard lock(mutex);observed.workerFinished=true;}
        changed.notify_all();
    }
    void run() noexcept {
        struct unlock {
            sqlite3_mutex* target;bool held=false;
            ~unlock(){if(held)sqlite3_mutex_leave(target);}
        } custody{target};
        try {
            for(;;) {
                {
                    std::lock_guard lock(mutex);
                    if(observed.releaseRequested){if(!observed.acquisitionTimedOut)observed.status=5;break;}
                    if(clock::now()>=acquireUntil){observed.acquisitionTimedOut=true;observed.status=4;break;}
                }
                const int rc=sqlite3_mutex_try(target);
                if(rc==SQLITE_OK) {
                    custody.held=true;
                    {
                        std::unique_lock lock(mutex);
                        // A late-acquired mutex cannot satisfy the rendezvous.
                        if(observed.releaseRequested){if(!observed.acquisitionTimedOut)observed.status=5;}
                        else if(clock::now()>=acquireUntil){observed.acquisitionTimedOut=true;observed.status=4;}
                        else {
                            observed.acquisitionSucceeded=true;observed.status=0;changed.notify_all();
                            const auto holdUntil=clock::now()+std::chrono::seconds(8);
                            if(!changed.wait_until(lock,holdUntil,[&]{return observed.releaseRequested;})) {
                                observed.safetyDeadlineReleased=true;observed.status=8;
                            }
                        }
                    }
                    break;
                }
                if(rc!=SQLITE_BUSY){std::lock_guard lock(mutex);observed.status=6;break;}
                std::unique_lock lock(mutex);
                changed.wait_until(lock,std::min(acquireUntil,clock::now()+std::chrono::milliseconds(1)),
                    [&]{return observed.releaseRequested;});
            }
        }catch(...){std::lock_guard lock(mutex);observed.status=7;}
        // Publish completion only after actual same-thread SQLite release.
        if(custody.held){sqlite3_mutex_leave(target);custody.held=false;}
        finish_worker();
    }
    void start() {
        // Every field exists before worker launch. No foreign callback is run
        // on this worker, whether or not it owns the SQLite mutex.
        worker=std::thread([this]{run();});
        std::unique_lock lock(mutex);
        if(!changed.wait_until(lock,acquireUntil,[&]{return observed.acquisitionSucceeded||observed.workerFinished;})) {
            observed.acquisitionTimedOut=true;observed.releaseRequested=true;observed.status=4;
            changed.notify_all();
        }
    }
    bool retire() noexcept {
        request_release();
        std::lock_guard join(joinMutex);
        // No code exposes the worker or invokes user code there; retirement
        // can never be called by that worker. Serial callers join at most once.
        if(worker.joinable())worker.join();
        // No observation/leaf lock is held while the final writer retires.
        writer.reset();
        std::lock_guard lock(mutex);observed.writerRetired=true;
        return observed.workerFinished&&
            !observed.acquisitionTimedOut&&!observed.safetyDeadlineReleased&&observed.status==0;
    }
    ~state() {
        // Containment for an erroneous test drop, never a success oracle.
        // Correct fixtures explicitly retire on their opening keyed IO lane.
        retire();
    }
};

writer_mutex_hold::writer_mutex_hold(std::shared_ptr<state> value) noexcept:value_(std::move(value)){}
holder_facts writer_mutex_hold::facts()const noexcept {
    if(!value_)return {};
    std::lock_guard lock(value_->mutex);return value_->observed;
}
void writer_mutex_hold::request_release()const noexcept {if(value_)value_->request_release();}
bool writer_mutex_hold::retire_on_io()const noexcept {return value_&&value_->retire();}
writer_mutex_hold hold_actual_writer(const swift_lattice_ref& ref)noexcept {
    try {
        auto owner=swift_lattice_ref::shared_for_lattice(const_cast<swift_lattice*>(ref.get()));
        if(!owner)return {};
        auto writer=detail::sync_discovery_test_access::actual_writer(*owner);
        owner.reset(); // The test helper must not keep the SDK owner alive.
        if(!writer)return {};
        auto value=std::make_shared<writer_mutex_hold::state>(std::move(writer));
#if defined(__APPLE__) || defined(__linux__)
        auto* handle=detail::canonical_writer_custody_test_access::actual_handle(*value->writer);
        value->target=handle?sqlite3_db_mutex(handle):nullptr;
        if(!value->target){value->observed.status=2;value->observed.workerFinished=true;return writer_mutex_hold(value);}
        try{value->start();}
        catch(...){
            // A rendezvous error after launch cannot fabricate worker drain.
            value->retire();
            std::lock_guard lock(value->mutex);value->observed.status=7;value->observed.workerFinished=true;
        }
#else
        value->observed.status=3;value->observed.workerFinished=true;
#endif
        return writer_mutex_hold(value);
    }catch(...){return {};}
}
}
