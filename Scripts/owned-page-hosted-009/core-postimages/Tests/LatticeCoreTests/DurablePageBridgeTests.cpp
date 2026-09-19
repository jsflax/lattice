#include <gtest/gtest.h>
#include <experimental_durable_page.hpp>
#include "../../Sources/LatticeSwiftCppBridge/src/experimental_durable_page_native.hpp"
#include <error.hpp>
#include <array>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>

#if !defined(__EMSCRIPTEN__)
// These mechanics tests construct synthetic native pages; they do not open a
// database, drive owner replay, qualify cancellation cleanup, or run Swift.
namespace lattice {
struct experimental_durable_page_test_access {
    static std::weak_ptr<const void> weak(const experimental_durable_page& value) {
        return std::shared_ptr<const void>(value.impl_);
    }
};
}
namespace {
namespace replay = lattice::observation_frames::replay;
namespace metadata = lattice::observation_metadata;
using Page = lattice::experimental_durable_page;
using Stop = lattice::experimental_durable_stop_control;
using Native = lattice::experimental_durable_bridge_access;
static_assert(std::is_nothrow_copy_constructible_v<Page>);
static_assert(std::is_nothrow_copy_assignable_v<Page>);
static_assert(std::is_nothrow_copy_constructible_v<Stop>);
static_assert(std::is_nothrow_copy_assignable_v<Stop>);
replay::identity identity(char byte) { replay::identity result; result.fill(byte); return result; }
replay::cursor cursor(replay::cursor_kind kind = replay::cursor_kind::frame) {
    replay::cursor value;
    value.store_uuid = identity('1'); value.history_epoch = identity('2'); value.kind = kind;
    if (kind != replay::cursor_kind::origin) {
        value.frame_id = 7; value.after_audit_id = 29; value.frame_key = identity('a');
    }
    return value;
}
replay::page page() {
    replay::page value;
    value.result = {replay::code::ready, 0, metadata::status::ready_integrity_only};
    value.snapshot = {identity('1'), identity('2'), 29, 4, 9};
    value.next = cursor(); value.has_cursor = true; value.at_head = true;
    // Deliberately reserve more than used, so bytes must include capacity.
    value.frames = std::make_unique<replay::frame_header[]>(2);
    value.rows = std::make_unique<replay::audit_header[]>(3);
    value.text = std::make_unique<char[]>(32);
    value.frame_count = 1; value.row_count = 1; value.text_bytes = 6;
    value.allocated_bytes = sizeof(replay::page) + 2 * sizeof(replay::frame_header) +
                            3 * sizeof(replay::audit_header) + 32;
    value.frames[0] = {identity('a'), 7, 29, 29, 0, 1};
    const unsigned char bytes[] = {'a', 0, 'b', 0xff, 'x', 'y'};
    std::memcpy(value.text.get(), bytes, sizeof(bytes));
    auto& row = value.rows[0]; row.id = 29;
    row.global_id = {};                         // SQL NULL
    row.table_name = {0, 0, false};             // non-NULL empty bytes
    row.operation = {0, 4, false};              // embedded NUL / non-UTF8
    row.global_row_id = {4, 1, false};
    row.changed_field_names = {5, 1, false};
    row.row_id = {-7, false}; row.is_from_remote = {0, false}; row.synthesized = {};
    return value;
}
// C++ uses the original names; SWIFT_NAME only changes the imported spelling.
std::string native_token(const Page& page) {
    std::string result;
    for (uint64_t index = 0; index < page.cursor_byte_count(); ++index) result.push_back(static_cast<char>(page.cursor_byte(index)));
    return result;
}
void expect_snapshot(const Page& page, const replay::snapshot_state& expected) {
    const auto actual = page.snapshot();
    EXPECT_EQ(actual.audit_head, expected.audit_head);
    EXPECT_EQ(actual.capture_started_after, expected.capture_started_after);
    EXPECT_EQ(actual.pruned_through, expected.pruned_through);
    for (uint64_t byte = 0; byte < 32; ++byte) {
        EXPECT_EQ(page.snapshot_identity_byte(0, byte), static_cast<uint8_t>(expected.store_uuid[byte]));
        EXPECT_EQ(page.snapshot_identity_byte(1, byte), static_cast<uint8_t>(expected.history_epoch[byte]));
    }
    EXPECT_TRUE(lattice::last_bridge_error().empty());
}
}

TEST(DurablePageBridge, CopiesRetainOneImmutableBackingUntilLastHandleDies) {
    Page survivor;
    std::weak_ptr<const void> lifetime;
    uint64_t bytes = 0;
    {
        auto original = Native::adopt(page());
        ASSERT_EQ(original.status_code(), 0);
        lifetime = lattice::experimental_durable_page_test_access::weak(original);
        survivor = original;
        const auto copy = survivor;
        EXPECT_TRUE(copy.shares_backing(original));
        bytes = original.allocated_backing_bytes();
        EXPECT_EQ(copy.allocated_backing_bytes(), bytes);
    }
    ASSERT_FALSE(lifetime.expired());
    EXPECT_EQ(survivor.audit_id(0), 29);
    EXPECT_EQ(survivor.text_byte(0, 2, 1), 0);
    EXPECT_EQ(survivor.allocated_backing_bytes(), bytes);
    survivor = Page{};
    EXPECT_TRUE(lifetime.expired());
    EXPECT_EQ(survivor.allocated_backing_bytes(), 0);
    EXPECT_FALSE(survivor.shares_backing(Page{}));
}

TEST(DurablePageBridge, PreservesNullEmptyRawBytesIntegerNullsAndSnapshot) {
    const auto wrapped = Native::adopt(page());
    ASSERT_EQ(wrapped.frame_count(), 1); ASSERT_EQ(wrapped.row_count(), 1);
    EXPECT_EQ(wrapped.text_bytes(), 6);
    EXPECT_TRUE(wrapped.text_field(0, 0).is_null);
    EXPECT_EQ(wrapped.text_field(0, 0).byte_count, 0);
    EXPECT_FALSE(wrapped.text_field(0, 1).is_null);
    EXPECT_EQ(wrapped.text_field(0, 1).byte_count, 0);
    EXPECT_EQ(wrapped.text_field(0, 2).byte_count, 4);
    EXPECT_EQ(wrapped.text_byte(0, 2, 0), 'a');
    EXPECT_EQ(wrapped.text_byte(0, 2, 1), 0);
    EXPECT_EQ(wrapped.text_byte(0, 2, 2), 'b');
    EXPECT_EQ(wrapped.text_byte(0, 2, 3), 255);
    EXPECT_EQ(wrapped.text_byte(0, 3, 0), 'x');
    EXPECT_EQ(wrapped.text_byte(0, 4, 0), 'y');
    EXPECT_EQ(wrapped.integer_field(0, 0).value, -7);
    EXPECT_FALSE(wrapped.integer_field(0, 0).is_null);
    EXPECT_EQ(wrapped.integer_field(0, 1).value, 0);
    EXPECT_FALSE(wrapped.integer_field(0, 1).is_null);
    EXPECT_TRUE(wrapped.integer_field(0, 2).is_null);
    const auto frame = wrapped.frame(0);
    EXPECT_EQ(frame.id, 7); EXPECT_EQ(frame.first_audit_id, 29); EXPECT_EQ(frame.last_audit_id, 29);
    EXPECT_EQ(frame.row_offset, 0); EXPECT_EQ(frame.row_count, 1);
    EXPECT_EQ(wrapped.frame_key_byte(0, 31), 'a');
    EXPECT_EQ(wrapped.snapshot_identity_byte(0, 31), '1');
    EXPECT_EQ(wrapped.snapshot_identity_byte(1, 0), '2');
    const auto snapshot = wrapped.snapshot();
    EXPECT_EQ(snapshot.audit_head, 29); EXPECT_EQ(snapshot.capture_started_after, 4); EXPECT_EQ(snapshot.pruned_through, 9);
}

TEST(DurablePageBridge, BackingByteAccountingIncludesReservedCapacityAndToken) {
    replay::page empty; empty.result.status = replay::code::ready;
    empty.has_cursor = true; empty.next = cursor(replay::cursor_kind::origin);
    const auto fixed = Native::adopt(std::move(empty));
    const auto wrapped = Native::adopt(page());
    const uint64_t capacity = 2 * sizeof(replay::frame_header) + 3 * sizeof(replay::audit_header) + 32;
    EXPECT_GE(fixed.allocated_backing_bytes(), sizeof(replay::page) + replay::encoded_cursor_size);
    EXPECT_EQ(wrapped.allocated_backing_bytes() - fixed.allocated_backing_bytes(), capacity);
    auto copy = wrapped;
    EXPECT_EQ(copy.allocated_backing_bytes(), wrapped.allocated_backing_bytes());
    EXPECT_TRUE(copy.shares_backing(wrapped));
}

TEST(DurablePageBridge, ExplicitStatusAndMetadataMappingPreservesFailureDiagnostics) {
    const std::array codes = {replay::code::ready, replay::code::invalid_context, replay::code::invalid_limits,
        replay::code::invalid_cursor, replay::code::foreign_store, replay::code::history_reset,
        replay::code::history_pruned, replay::code::coverage_unavailable, replay::code::framing_unavailable,
        replay::code::metadata_uncertain, replay::code::frame_too_large, replay::code::resource_limit,
        replay::code::cancelled, replay::code::deadline, replay::code::work_limit, replay::code::busy,
        replay::code::database_error, replay::code::rollback_failed};
    for (size_t index = 0; index < codes.size(); ++index) {
        auto source = page();
        source.result = {codes[index], 517, metadata::status::integrity_uncertain, index == 0, 7, 29, 31};
        if (index) source.snapshot = {identity('c'), identity('d'),
            901 + static_cast<int64_t>(index), 57 + static_cast<int64_t>(index), 23 + static_cast<int64_t>(index)};
        const auto expected_snapshot = source.snapshot;
        const auto wrapped = Native::adopt(std::move(source));
        const auto result = wrapped.result();
        EXPECT_EQ(result.status, static_cast<int32_t>(index));
        EXPECT_EQ(result.sqlite_code, 517); EXPECT_EQ(result.metadata_status, 8);
        EXPECT_EQ(result.cleanup_ok, index == 0);
        EXPECT_EQ(result.boundary_frame_id, 7); EXPECT_EQ(result.boundary_first_audit_id, 29); EXPECT_EQ(result.boundary_last_audit_id, 31);
        EXPECT_EQ(wrapped.error_message().empty(), index == 0);
        expect_snapshot(wrapped, expected_snapshot);
        if (index) {
            EXPECT_FALSE(wrapped.has_cursor()); EXPECT_FALSE(wrapped.at_head());
            EXPECT_EQ(wrapped.frame_count(), 0); EXPECT_EQ(wrapped.row_count(), 0); EXPECT_EQ(wrapped.cursor_byte_count(), 0);
            EXPECT_EQ(wrapped.allocated_backing_bytes(), 0); // Failed diagnostics need no backing allocation.
        }
    }
    const std::array metadata_codes = {metadata::status::not_installed, metadata::status::ready_integrity_only,
        metadata::status::unsupported_format, metadata::status::unsupported_audit_shape,
        metadata::status::unsupported_trigger_inventory, metadata::status::unsupported_foreign_key_inventory,
        metadata::status::unsupported_temp_inventory, metadata::status::triggers_disabled,
        metadata::status::integrity_uncertain, metadata::status::invalid_context,
        metadata::status::database_error, metadata::status::rollback_failed};
    for (size_t index = 0; index < metadata_codes.size(); ++index) {
        replay::page source;
        source.result.metadata_status = metadata_codes[index];
        EXPECT_EQ(Native::adopt(std::move(source)).result().metadata_status, static_cast<int32_t>(index));
    }
    // Unknown/default native snapshot bytes remain zero, with no validity claim.
    expect_snapshot(Page{}, replay::snapshot_state{});
    expect_snapshot(Native::adopt(replay::page{}), replay::snapshot_state{});
}

TEST(DurablePageBridge, InvalidBoundsAreSealedAndValidCallClearsTheError) {
    const auto wrapped = Native::adopt(page());
    EXPECT_EQ(wrapped.audit_id(1), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.audit_id(0), 29); EXPECT_TRUE(lattice::last_bridge_error().empty());
    EXPECT_TRUE(wrapped.text_field(0, 99).is_null); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_TRUE(wrapped.integer_field(0, -1).is_null); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.text_byte(0, 0, 0), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.text_byte(0, 1, 0), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.text_byte(0, 2, 4), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.frame_key_byte(0, 32), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.snapshot_identity_byte(2, 0), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.cursor_byte(139), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.text_byte(0, 2, 0), 'a'); EXPECT_TRUE(lattice::last_bridge_error().empty());
    EXPECT_EQ(wrapped.status_code(), 0); // An accessor failure cannot mutate shared page state.
    auto source = page(); source.rows[0].operation = {5, 2, false};
    const auto malformed = Native::adopt(std::move(source));
    EXPECT_TRUE(malformed.text_field(0, 2).is_null); EXPECT_FALSE(lattice::last_bridge_error().empty());
    EXPECT_EQ(malformed.text_byte(0, 2, 0), 0); EXPECT_FALSE(lattice::last_bridge_error().empty());
}

TEST(DurablePageBridge, CursorUsesUnchangedCanonical139ByteCodecForEveryKind) {
    for (const auto kind : {replay::cursor_kind::origin, replay::cursor_kind::frame, replay::cursor_kind::snapshot_barrier}) {
        auto source = page(); source.next = cursor(kind);
        replay::encoded_cursor expected{};
        ASSERT_EQ(replay::encode_cursor(source.next, expected), replay::code::ready);
        const auto wrapped = Native::adopt(std::move(source));
        ASSERT_EQ(wrapped.cursor_byte_count(), 139);
        const auto bytes = native_token(wrapped);
        EXPECT_EQ(bytes, std::string(expected.data(), expected.size()));
        replay::cursor decoded;
        ASSERT_EQ(replay::decode_cursor(bytes, decoded), replay::code::ready);
        EXPECT_EQ(decoded.kind, kind); EXPECT_EQ(decoded.store_uuid, identity('1'));
        EXPECT_EQ(decoded.frame_id, kind == replay::cursor_kind::origin ? 0 : 7);
        EXPECT_EQ(decoded.after_audit_id, kind == replay::cursor_kind::origin ? 0 : 29);
        auto changed = bytes; changed[3] = '2';
        EXPECT_EQ(replay::decode_cursor(changed, decoded), replay::code::invalid_cursor);
    }
}

TEST(DurablePageBridge, MalformedTokenAndUncleanSuccessCannotPublishCursorOrRows) {
    auto source = page(); source.next.store_uuid[0] = 'G';
    const auto expected_snapshot = source.snapshot;
    const auto invalid = Native::adopt(std::move(source));
    EXPECT_EQ(invalid.status_code(), 3); EXPECT_FALSE(invalid.has_cursor()); EXPECT_EQ(invalid.row_count(), 0);
    expect_snapshot(invalid, expected_snapshot);
    source = page(); source.result.cleanup_ok = false;
    const auto unclean = Native::adopt(std::move(source));
    EXPECT_EQ(unclean.status_code(), 17); EXPECT_FALSE(unclean.result().cleanup_ok);
    EXPECT_FALSE(unclean.has_cursor()); EXPECT_EQ(unclean.frame_count(), 0);
    expect_snapshot(unclean, expected_snapshot);
    source = page(); source.allocated_bytes = 1;
    const auto malformed = Native::adopt(std::move(source));
    EXPECT_EQ(malformed.status_code(), 1); EXPECT_FALSE(malformed.has_cursor()); EXPECT_EQ(malformed.allocated_backing_bytes(), 0);
    EXPECT_FALSE(lattice::last_bridge_error().empty());
    expect_snapshot(malformed, expected_snapshot);
    if constexpr (sizeof(size_t) == sizeof(uint64_t)) {
        // Deterministically exercise the resource-error sealed fallback also
        // used by make_shared failure, without allocating an oversized page.
        source = page(); source.allocated_bytes = std::numeric_limits<size_t>::max();
        const auto resource = Native::adopt(std::move(source));
        EXPECT_EQ(resource.status_code(), 11); EXPECT_FALSE(resource.has_cursor());
        EXPECT_EQ(resource.allocated_backing_bytes(), 0);
        EXPECT_FALSE(lattice::last_bridge_error().empty());
        expect_snapshot(resource, expected_snapshot);
    }
}

TEST(DurablePageBridge, StopCopiesShareOnlyTheirOwnOperationFlagAndNativeAlias) {
    auto stop = Stop::make();
    ASSERT_TRUE(stop.is_valid()); ASSERT_TRUE(lattice::last_bridge_error().empty());
    const auto copy = stop;
    const auto unrelated = Stop::make();
    EXPECT_TRUE(copy.same_operation(stop)); EXPECT_FALSE(copy.same_operation(unrelated));
    auto native = Native::stop(stop);
    ASSERT_TRUE(native); EXPECT_EQ(native, Native::stop(copy));
    EXPECT_FALSE(native->cancelled.load(std::memory_order_acquire));
    std::jthread canceller([copy] { copy.cancel(); }); canceller.join();
    EXPECT_TRUE(stop.is_cancelled()); EXPECT_TRUE(native->cancelled.load(std::memory_order_acquire));
    EXPECT_FALSE(unrelated.is_cancelled());
    lattice::last_bridge_error() = "prior diagnostic";
    copy.cancel();
    EXPECT_EQ(lattice::last_bridge_error(), "prior diagnostic");
    Stop empty; EXPECT_FALSE(empty.is_valid()); EXPECT_FALSE(empty.is_cancelled());
    EXPECT_FALSE(empty.same_operation(Stop{})); EXPECT_FALSE(Native::stop(empty));
    empty.cancel(); EXPECT_EQ(lattice::last_bridge_error(), "prior diagnostic");
}

TEST(DurablePageBridge, NativeStopAliasOutlivesBridgeCopiesWithoutParentRetention) {
    std::shared_ptr<replay::stop_control> native;
    std::weak_ptr<replay::stop_control> lifetime;
    {
        const auto stop = Stop::make(); const auto copy = stop;
        native = Native::stop(copy); lifetime = native;
        EXPECT_FALSE(native->cancelled.load(std::memory_order_acquire));
    }
    ASSERT_FALSE(lifetime.expired());
    native->cancelled.store(true, std::memory_order_release);
    EXPECT_TRUE(native->cancelled.load(std::memory_order_acquire));
    native.reset(); EXPECT_TRUE(lifetime.expired());
}
#endif
