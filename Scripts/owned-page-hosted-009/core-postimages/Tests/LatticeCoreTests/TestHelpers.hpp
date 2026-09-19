#pragma once

#include "TestRuntime.hpp"

// ============================================================================
// Helpers
// ============================================================================

/// Pack a vector of floats into a byte vector (for vec0 BLOBs)
inline std::vector<uint8_t> pack_floats(const std::vector<float>& f) {
    std::vector<uint8_t> b(f.size() * sizeof(float));
    std::memcpy(b.data(), f.data(), b.size());
    return b;
}

/// Unpack bytes back to floats
inline std::vector<float> unpack_floats(const std::vector<uint8_t>& b) {
    std::vector<float> f(b.size() / sizeof(float));
    std::memcpy(f.data(), b.data(), b.size());
    return f;
}

/// Generate a simple fake UUID
inline std::string fake_uuid(int counter) {
    return "test-uuid-" + std::to_string(counter);
}

// ============================================================================
// Model Definitions
// ============================================================================

struct TestPerson {
    std::string name;
    int age;
    std::optional<std::string> email;
};
LATTICE_SCHEMA(TestPerson, name, age, email);

struct TestDog {
    std::string name;
    double weight;
    bool is_good_boy;
};
LATTICE_SCHEMA(TestDog, name, weight, is_good_boy);

struct TestTrip {
    std::string name;
    int days;
    std::optional<std::string> notes;
};
LATTICE_SCHEMA(TestTrip, name, days, notes);

struct TestAllTypes {
    int int_val;
    int64_t int64_val;
    double double_val;
    bool bool_val;
    std::string string_val;
    std::optional<int> optional_int;
    std::optional<std::string> optional_string;
};
LATTICE_SCHEMA(TestAllTypes, int_val, int64_val, double_val, bool_val, string_val, optional_int, optional_string);

struct TestPet {
    std::string name;
    double weight;
};
LATTICE_SCHEMA(TestPet, name, weight);

struct TestOwner {
    std::string name;
    TestPet* pet;
};
LATTICE_SCHEMA(TestOwner, name, pet);

struct TestPlace {
    std::string name;
    lattice::geo_bounds location;
};
LATTICE_SCHEMA(TestPlace, name, location);

struct TestLandmark {
    std::string name;
    std::optional<lattice::geo_bounds> bounds;
};
LATTICE_SCHEMA(TestLandmark, name, bounds);

struct TestRegion {
    std::string name;
    std::vector<lattice::geo_bounds> zones;
};
LATTICE_SCHEMA(TestRegion, name, zones);
