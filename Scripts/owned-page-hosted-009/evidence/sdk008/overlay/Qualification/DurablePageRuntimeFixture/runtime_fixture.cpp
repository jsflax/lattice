#include "runtime_fixture.hpp"
#include <lattice.hpp>
#include "observation_owner.hpp"
#include "experimental_durable_page_native.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

static_assert(LATTICE_HAS_FRT == 1, "fixture owner must use the accepted native macOS FRT1 ABI");
namespace lattice {
// Exact weak-only friend seam already used by accepted DurablePageBridgeTests.
// The existing test TU is NOT linked into this executable.
struct experimental_durable_page_test_access {
    static std::weak_ptr<const void> weak(const experimental_durable_page& value) {
        return std::shared_ptr<const void>(value.impl_);
    }
};
}
namespace durable_runtime_fixture {
namespace {
namespace owned = lattice::observation_owned;
namespace frames = lattice::observation_frames;
namespace replay = frames::replay;
using Page = lattice::experimental_durable_page;
using Stop = lattice::experimental_durable_stop_control;
using Bridge = lattice::experimental_durable_bridge_access;
counters counts;
std::weak_ptr<const void> backing;
struct text_copy { bool is_null = true; std::string bytes; };
struct expected_page {
    replay::snapshot_state snapshot;
    replay::frame_header frame;
    replay::encoded_cursor token{};
    uint64_t text_bytes = 0;
    std::array<int64_t, 2> audit_ids{};
    std::array<std::array<text_copy, 5>, 2> texts;
    std::array<std::array<replay::integer_field, 3>, 2> integers;
} expected;
void require(bool value, const char* reason) {
    if (!value) throw std::runtime_error(reason);
}
void fail(const char* reason) noexcept {
    ++counts.failures;
    std::fprintf(stderr, "DURABLE_FIXTURE_FAILURE: %.400s\n", reason);
}
lattice::SchemaVector schema() {
    lattice::swift_schema_entry entry; entry.table_name = "OwnedModel";
    lattice::property_descriptor value; value.name = "value"; value.type = lattice::column_type::integer;
    entry.properties["value"] = value;
    return {entry};
}
struct fixture {
    std::filesystem::path path;
    std::unique_ptr<lattice::swift_lattice_ref> ref;
    std::weak_ptr<lattice::swift_lattice> owner_lifetime;
    explicit fixture(const char* name) {
        const char* root = std::getenv("DURABLE_RUNTIME_DATA_ROOT");
        require(root && name, "owned data root/path required");
        path = std::filesystem::path(name);
        require(path.is_absolute() && path.parent_path() == std::filesystem::path(root), "path must be directly inside owned data root");
        require(path.filename() == "original.sqlite" || path.filename() == "independent.sqlite" || path.filename() == "cancelled.sqlite", "unexpected fixture filename");
        require(!std::filesystem::exists(path) && !std::filesystem::exists(path.string() + "-wal") && !std::filesystem::exists(path.string() + "-shm"), "fresh fixture required");
        ref.reset(lattice::swift_lattice_ref::create(lattice::swift_configuration(path.string()), schema()));
        require(ref && ref->get(), "owner creation");
        // Lookup returns a temporary shared_ptr from the existing weak cache.
        // Keep only a weak witness; discard the temporary before any work.
        owner_lifetime = lattice::swift_lattice_ref::shared_for_lattice(ref->get());
        require(!owner_lifetime.expired(), "actual owner weak witness");
        require(owned::enable(core(), "OwnedModel").code == frames::status::ready_integrity_only, "owner enable");
    }
    lattice::swift_lattice& core() { return *ref->get(); }
    void close() {
        core().close(); core().close_read_db(); ++counts.owner_closes;
    }
    void destroy() {
        ref.reset();
        require(owner_lifetime.expired(), "actual swift_lattice destruction while page retained");
        ++counts.owner_destructions;
    }
    ~fixture() noexcept {
        if (ref) {
            try { close(); destroy(); }
            catch (const std::exception& e) { fail(e.what()); }
            catch (...) { fail("unknown fixture destructor failure"); }
        }
    }
};
int64_t scalar(lattice::swift_lattice& core, const char* sql) {
    const auto rows = core.db().query(sql);
    require(rows.size() == 1 && rows[0].size() == 1, "scalar cardinality");
    return std::get<int64_t>(rows[0].begin()->second);
}
void commit(owned::transaction& tx) {
    const auto result = tx.commit();
    require(result.code == frames::outcome::committed && !result.transaction_open, "owned commit/cleanup");
    ++counts.commits;
}
void capture_expected(const replay::page& page) {
    require(page.frame_count == 1 && page.row_count == 2 && page.text_bytes <= 4096, "bounded real page dimensions");
    expected = expected_page{};
    expected.snapshot = page.snapshot; expected.frame = page.frames[0]; expected.text_bytes = page.text_bytes;
    require(replay::encode_cursor(page.next, expected.token) == replay::code::ready, "native token encoding");
    for (size_t row = 0; row != 2; ++row) {
        const auto& value = page.rows[row]; expected.audit_ids[row] = value.id;
        const std::array<replay::text_field, 5> fields{value.global_id, value.table_name, value.operation, value.global_row_id, value.changed_field_names};
        for (size_t field = 0; field != fields.size(); ++field) {
            expected.texts[row][field].is_null = fields[field].is_null;
            expected.texts[row][field].bytes = std::string(page.value(fields[field]));
        }
        expected.integers[row] = {value.row_id, value.is_from_remote, value.synthesized};
    }
}
}

Page make_page(const char* path, const Stop& stop) noexcept {
    try {
        require(stop.is_valid() && !stop.is_cancelled(), "live independent stop required");
        require(backing.expired(), "previous Swift backing must have been released");
        fixture owner(path);
        auto start = owned::capture(owner.core(), "OwnedModel"); ++counts.captures;
        require(start.barrier.result.status == replay::code::ready && start.barrier.result.cleanup_ok && start.barrier.has_cursor && start.row_count == 0, "empty real owner capture");
        int64_t id;
        { owned::transaction tx(owner.core(), "OwnedModel"); id = tx.insert(10); require(tx.set(id, 11) == 1, "owned update"); commit(tx); }
        const auto changes = owner.core().db().changes();
        const auto rowid = scalar(owner.core(), "SELECT last_insert_rowid()");
        auto native = owned::read_after(owner.core(), "OwnedModel", start.barrier.resume, {}, Bridge::stop(stop)); ++counts.real_reads;
        require(native.result.status == replay::code::ready && native.result.cleanup_ok && native.has_cursor && native.at_head, "real owned replay cleanup");
        require(native.frame_count == 1 && native.row_count == 2 && native.frames[0].row_count == 2, "one whole committed frame");
        require(native.rows[0].id == native.frames[0].first_audit_id && native.rows[1].id == native.frames[0].last_audit_id && native.rows[1].id > native.rows[0].id, "ordered audit identities");
        require(native.value(native.rows[0].operation) == "INSERT" && native.value(native.rows[1].operation) == "UPDATE", "real model operation order");
        require(native.rows[0].row_id.value == id && native.rows[1].row_id.value == id, "real model row identity");
        require(owner.core().db().changes() == changes && scalar(owner.core(), "SELECT last_insert_rowid()") == rowid, "writer result counters preserved");
        ++counts.writer_counters_preserved;
        capture_expected(native);
        auto page = Bridge::adopt(std::move(native));
        require(page.status_code() == 0 && page.result().cleanup_ok && page.has_cursor(), "adopt real page");
        backing = lattice::experimental_durable_page_test_access::weak(page);
        require(!backing.expired(), "weak backing observer attached");
        { owned::transaction tx(owner.core(), "OwnedModel"); require(tx.set(id, 12) == 1, "writer progress while page retained"); commit(tx); }
        const auto rows = owner.core().db().query("PRAGMA wal_checkpoint(TRUNCATE)");
        require(rows.size() == 1, "checkpoint cardinality");
        counts.checkpoint_busy = static_cast<int32_t>(std::get<int64_t>(rows[0].at("busy")));
        counts.checkpoint_log = static_cast<int32_t>(std::get<int64_t>(rows[0].at("log")));
        counts.checkpoint_done = static_cast<int32_t>(std::get<int64_t>(rows[0].at("checkpointed")));
        require(counts.checkpoint_busy == 0 && counts.checkpoint_log == 0 && counts.checkpoint_done == 0, "retained page must not pin WAL");
        require(!std::filesystem::exists(owner.path.string() + "-wal") || std::filesystem::file_size(owner.path.string() + "-wal") == 0, "physical WAL truncated");
        owner.close(); owner.destroy();
        require(!backing.expired() && page.row_count() == 2, "page backing survives destroyed owner");
        return page;
    } catch (const std::exception& e) { fail(e.what()); }
    catch (...) { fail("unknown make_page failure"); }
    return {};
}

Page pre_cancelled_read(const char* path, const Stop& stop) noexcept {
    try {
        require(stop.is_valid() && stop.is_cancelled(), "Swift-cancelled alias required");
        fixture owner(path);
        auto start = owned::capture(owner.core(), "OwnedModel"); ++counts.captures;
        require(start.barrier.result.status == replay::code::ready && start.barrier.has_cursor, "cancel fixture capture");
        owner.close();
        require(std::filesystem::remove(owner.path), "delete closed cancel fixture");
        std::filesystem::remove(owner.path.string() + "-wal");
        std::filesystem::remove(owner.path.string() + "-shm");
        auto page = owned::read_after(owner.core(), "OwnedModel", start.barrier.resume, {}, Bridge::stop(stop));
        ++counts.pre_cancel_reads;
        counts.pre_cancel_status = page.result.status == replay::code::cancelled ? 12 : -1;
        counts.pre_cancel_cleanup = page.result.cleanup_ok;
        counts.pre_cancel_file_absent = !std::filesystem::exists(owner.path);
        require(counts.pre_cancel_status == 12 && counts.pre_cancel_cleanup && counts.pre_cancel_file_absent && !page.has_cursor && !page.frames && !page.rows && !page.text && page.allocated_bytes == 0, "pre-cancelled read must skip closed owner and missing file admission");
        owner.destroy();
        return Bridge::adopt(std::move(page));
    } catch (const std::exception& e) { fail(e.what()); }
    catch (...) { fail("unknown pre_cancelled_read failure"); }
    return {};
}
counters statistics() noexcept { return counts; }
bool backing_expired() noexcept { return backing.expired(); }
int64_t expected_number(int32_t group, uint64_t row, int32_t field) noexcept {
    // Groups: snapshot=0, frame=1, audit id=2, text null/length=3/4,
    // integer null/value=5/6, total text arena bytes=7.
    if (group == 0 && field >= 0 && field < 3) {
        const int64_t values[]{expected.snapshot.audit_head, expected.snapshot.capture_started_after, expected.snapshot.pruned_through}; return values[field];
    }
    if (group == 1 && field >= 0 && field < 5) {
        const int64_t values[]{expected.frame.id, expected.frame.first_audit_id, expected.frame.last_audit_id, static_cast<int64_t>(expected.frame.row_offset), static_cast<int64_t>(expected.frame.row_count)}; return values[field];
    }
    if (group == 2 && row < 2) return expected.audit_ids[row];
    if ((group == 3 || group == 4) && row < 2 && field >= 0 && field < 5) {
        const auto& value = expected.texts[row][field]; return group == 3 ? value.is_null : static_cast<int64_t>(value.bytes.size());
    }
    if ((group == 5 || group == 6) && row < 2 && field >= 0 && field < 3) {
        const auto& value = expected.integers[row][field]; return group == 5 ? value.is_null : value.value;
    }
    if (group == 7) return static_cast<int64_t>(expected.text_bytes);
    fail("expected_number range"); return 0;
}
uint8_t expected_byte(int32_t group, uint64_t row, int32_t field, uint64_t byte) noexcept {
    if (group == 0 && byte < expected.token.size()) return static_cast<uint8_t>(expected.token[byte]);
    if (group == 1 && byte < 32 && (field == 0 || field == 1)) return static_cast<uint8_t>((field == 0 ? expected.snapshot.store_uuid : expected.snapshot.history_epoch)[byte]);
    if (group == 2 && byte < 32) return static_cast<uint8_t>(expected.frame.key[byte]);
    if (group == 3 && row < 2 && field >= 0 && field < 5 && byte < expected.texts[row][field].bytes.size()) return static_cast<uint8_t>(expected.texts[row][field].bytes[byte]);
    fail("expected_byte range"); return 0;
}
}

// Added owning-edge setup; every line above is the accepted six-case fixture.
#include "edge_fixture.hpp"
static_assert(LATTICE_EXPERIMENTAL_OWNED_READ == 1, "owning edge feature must match native archives and Swift importer");
namespace durable_runtime_fixture {
namespace {
edge_counters edge_counts;
std::weak_ptr<lattice::swift_lattice> edge_owner;
std::weak_ptr<const void> edge_backing;
std::filesystem::path edge_path;
replay::encoded_cursor edge_token{};
int64_t edge_row = 0;
void edge_fail(const char* reason) noexcept {
    ++edge_counts.failures;
    fail(reason);
}
void edge_commit(owned::transaction& tx) {
    const auto value = tx.commit();
    require(value.code == frames::outcome::committed && !value.transaction_open, "edge owned commit/cleanup");
    ++edge_counts.commits;
}
}
lattice::swift_lattice_ref* make_edge_owner(const char* name) noexcept {
    try {
        require(edge_owner.expired() && edge_backing.expired(), "previous edge owner and page must have been released");
        const char* root = std::getenv("DURABLE_RUNTIME_DATA_ROOT");
        require(root && name, "edge owned path required");
        const auto path = std::filesystem::path(name);
        require(path.is_absolute() && path.parent_path() == std::filesystem::path(root), "edge path must be directly inside owned root");
        require(path.filename() == "edge.sqlite" || path.filename() == "edge-stop.sqlite", "unexpected edge fixture filename");
        for (const auto* suffix : {"", "-wal", "-shm"})
            require(!std::filesystem::exists(path.string() + suffix), "fresh edge fixture required");
        auto ref = std::unique_ptr<lattice::swift_lattice_ref>(lattice::swift_lattice_ref::create(lattice::swift_configuration(path.string()), schema()));
        require(ref && ref->get(), "edge owner creation");
        auto& core = *ref->get();
        edge_owner = lattice::swift_lattice_ref::shared_for_lattice(&core);
        require(!edge_owner.expired(), "edge weak owner witness");
        require(owned::enable(core, "OwnedModel").code == frames::status::ready_integrity_only, "edge owner enable");
        const auto start = owned::capture(core, "OwnedModel");
        require(start.barrier.result.status == replay::code::ready && start.barrier.result.cleanup_ok && start.barrier.has_cursor && start.row_count == 0, "edge empty capture");
        ++edge_counts.captures;
        require(replay::encode_cursor(start.barrier.resume, edge_token) == replay::code::ready, "edge starting cursor encoding");
        { owned::transaction tx(core, "OwnedModel"); edge_row = tx.insert(10); require(tx.set(edge_row, 11) == 1, "edge update"); edge_commit(tx); }
        // Independent native oracle for raw values only, destroyed before the
        // owner is returned. The actual qualification read is called by Swift.
        auto oracle = owned::read_after(core, "OwnedModel", start.barrier.resume);
        require(oracle.result.status == replay::code::ready && oracle.result.cleanup_ok && oracle.has_cursor && oracle.at_head, "edge oracle read cleanup");
        capture_expected(oracle); ++edge_counts.oracle_reads;
        edge_path = path; ++edge_counts.owners;
        return ref.release();
    } catch (const std::exception& error) { edge_fail(error.what()); }
    catch (...) { edge_fail("unknown edge owner setup failure"); }
    return nullptr;
}
std::string edge_cursor() noexcept {
    try { return std::string(edge_token.data(), edge_token.size()); }
    catch (const std::exception& error) { edge_fail(error.what()); }
    catch (...) { edge_fail("unknown edge cursor failure"); }
    return {};
}
bool finish_edge_owner(const lattice::swift_lattice_ref& ref, const Page& page, bool remove_file) noexcept {
    try {
        auto parent = edge_owner.lock();
        require(parent && parent.get() == ref.get(), "same live edge owner");
        require(page.status_code() == 0 && page.result().cleanup_ok && page.has_cursor() && page.frame_count() == 1 && page.row_count() == 2, "actual Swift edge result");
        edge_backing = lattice::experimental_durable_page_test_access::weak(page);
        require(!edge_backing.expired(), "edge weak backing witness");
        { owned::transaction tx(*parent, "OwnedModel"); require(tx.set(edge_row, 12) == 1, "edge writer progress with retained page"); edge_commit(tx); }
        const auto rows = parent->db().query("PRAGMA wal_checkpoint(TRUNCATE)");
        require(rows.size() == 1, "edge checkpoint cardinality");
        edge_counts.checkpoint_busy = static_cast<int32_t>(std::get<int64_t>(rows[0].at("busy")));
        edge_counts.checkpoint_log = static_cast<int32_t>(std::get<int64_t>(rows[0].at("log")));
        edge_counts.checkpoint_done = static_cast<int32_t>(std::get<int64_t>(rows[0].at("checkpointed")));
        require(edge_counts.checkpoint_busy == 0 && edge_counts.checkpoint_log == 0 && edge_counts.checkpoint_done == 0, "edge retained page must not pin WAL");
        require(!std::filesystem::exists(edge_path.string() + "-wal") || std::filesystem::file_size(edge_path.string() + "-wal") == 0, "edge physical WAL truncated");
        parent->close(); parent->close_read_db(); ++edge_counts.closes;
        if (remove_file) {
            require(edge_path.filename() == "edge-stop.sqlite" && std::filesystem::remove(edge_path), "remove only closed stop fixture");
            std::filesystem::remove(edge_path.string() + "-wal");
            std::filesystem::remove(edge_path.string() + "-shm");
            ++edge_counts.removed_files;
        }
        return true;
    } catch (const std::exception& error) { edge_fail(error.what()); }
    catch (...) { edge_fail("unknown edge finish failure"); }
    return false;
}
edge_counters edge_statistics() noexcept { return edge_counts; }
bool edge_owner_expired() noexcept { return edge_owner.expired(); }
bool edge_backing_expired() noexcept { return edge_backing.expired(); }
}
