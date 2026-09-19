#pragma once

#include <gtest/gtest.h>
#include <LatticeCore.hpp>
#include <filesystem>
#include <random>
#include <cstring>
#include <cstdlib>
#include <thread>
#include <atomic>
#include <condition_variable>

// ============================================================================
// RAII temp database — creates a unique temp file, cleans up on destruction
// ============================================================================

struct TempDB {
    std::filesystem::path path;

    TempDB(std::string name = "test")
        : path(std::filesystem::temp_directory_path()
               / (name + "_" + random_suffix() + ".sqlite")) {}

    ~TempDB() {
        std::filesystem::remove(path);
        std::filesystem::remove(path.string() + "-wal");
        std::filesystem::remove(path.string() + "-shm");
    }

    // Non-copyable, movable
    TempDB(const TempDB&) = delete;
    TempDB& operator=(const TempDB&) = delete;
    TempDB(TempDB&&) = default;
    TempDB& operator=(TempDB&&) = default;

    std::string str() const { return path.string(); }
    operator std::string() const { return str(); }

private:
    static std::string random_suffix() {
        static std::mt19937 rng(std::random_device{}());
        std::uniform_int_distribution<uint32_t> dist;
        return std::to_string(dist(rng));
    }
};

// ============================================================================
// Global test environment — sets up file logging for all tests
// ============================================================================

class LatticeTestEnv : public ::testing::Environment {
public:
    void SetUp() override {
        // Qualification runs can place every artifact beside their receipts.
        // Otherwise follow the platform temp directory (including TMPDIR),
        // rather than bypassing that configuration with a hard-coded /tmp.
        const auto* requested_log = std::getenv("LATTICE_TEST_LOG_PATH");
        const auto log_path = requested_log && *requested_log
            ? std::filesystem::path(requested_log)
            : std::filesystem::temp_directory_path() / "lattice_debug.log";
        log_file_ = fopen(log_path.string().c_str(), "w");
        if (log_file_) {
            lattice::set_log_file(log_file_);
            lattice::set_log_level(lattice::log_level::debug);
        }
    }
    void TearDown() override {
        lattice::set_log_file(nullptr);
        lattice::set_log_level(lattice::log_level::off);
        if (log_file_) { fclose(log_file_); log_file_ = nullptr; }
    }
private:
    FILE* log_file_ = nullptr;
};

static auto* _lattice_env [[maybe_unused]] =
    ::testing::AddGlobalTestEnvironment(new LatticeTestEnv());

