#include <LatticeCore.hpp>
#include <atomic>
#include <cstdio>
#include <memory>
#include <string>
#include <unistd.h>

struct ProbePerson {
    std::string name;
    int age;
    std::optional<std::string> email;
};
LATTICE_SCHEMA(ProbePerson, name, age, email);

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    alarm(7);
    lattice::set_log_level(lattice::log_level::off);
    const std::string path(argv[1]);
    auto a = std::make_unique<lattice::lattice_db>(lattice::configuration(path));
    lattice::lattice_db b{lattice::configuration(path)};
    bool fired = false;
    a->add_table_observer("AuditLog", [&a, &fired](const std::vector<lattice::lattice_db::change_event>&) {
        auto& depths = lattice::instance_guard::tls_depths();
        std::fprintf(stderr, "callback depths=%zu map=%p\n", depths.size(), static_cast<void*>(&depths));
        for (const auto& [guard, depth] : depths)
            std::fprintf(stderr, "guard=%p own=%d refs=%d\n", static_cast<const void*>(guard), depth, guard->notify_refcount.load());
        if (a) a.reset();
        fired = true;
        std::fputs("callback destroyed owner\n", stderr);
    });
    b.add(ProbePerson{"boom", 1, std::nullopt});
    std::fprintf(stderr, "returned fired=%d released=%d\n", fired, !a);
    return fired && !a ? 0 : 1;
}
