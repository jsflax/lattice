#include "experimental_durable_page_native.hpp"
#include <error.hpp>
#include <limits>
#include <stdexcept>
#include <utility>

#if !defined(__EMSCRIPTEN__)
namespace lattice {
namespace {
namespace replay = observation_frames::replay;
int32_t mapped(replay::code code) noexcept {
    switch (code) {
    case replay::code::ready: return 0;
    case replay::code::invalid_context: return 1;
    case replay::code::invalid_limits: return 2;
    case replay::code::invalid_cursor: return 3;
    case replay::code::foreign_store: return 4;
    case replay::code::history_reset: return 5;
    case replay::code::history_pruned: return 6;
    case replay::code::coverage_unavailable: return 7;
    case replay::code::framing_unavailable: return 8;
    case replay::code::metadata_uncertain: return 9;
    case replay::code::frame_too_large: return 10;
    case replay::code::resource_limit: return 11;
    case replay::code::cancelled: return 12;
    case replay::code::deadline: return 13;
    case replay::code::work_limit: return 14;
    case replay::code::busy: return 15;
    case replay::code::database_error: return 16;
    case replay::code::rollback_failed: return 17;
    }
    return 16; // Unknown future native status must never become ready.
}
int32_t mapped(observation_metadata::status code) noexcept {
    using status = observation_metadata::status;
    switch (code) {
    case status::not_installed: return 0;
    case status::ready_integrity_only: return 1;
    case status::unsupported_format: return 2;
    case status::unsupported_audit_shape: return 3;
    case status::unsupported_trigger_inventory: return 4;
    case status::unsupported_foreign_key_inventory: return 5;
    case status::unsupported_temp_inventory: return 6;
    case status::triggers_disabled: return 7;
    case status::integrity_uncertain: return 8;
    case status::invalid_context: return 9;
    case status::database_error: return 10;
    case status::rollback_failed: return 11;
    }
    return 8;
}
experimental_durable_diagnostic translated(const replay::diagnostic& value) noexcept {
    return {mapped(value.status), value.sqlite_code, mapped(value.metadata_status),
            value.cleanup_ok, value.boundary_frame_id,
            value.boundary_first_audit_id, value.boundary_last_audit_id};
}
const char* message(int32_t code) noexcept {
    switch (code) {
    case 0: return "";
    case 1: return "durable replay invalid context";
    case 2: return "durable replay invalid limits";
    case 3: return "durable replay invalid cursor";
    case 4: return "durable replay foreign store";
    case 5: return "durable replay history reset";
    case 6: return "durable replay history pruned";
    case 7: return "durable replay coverage unavailable";
    case 8: return "durable replay framing unavailable";
    case 9: return "durable replay metadata uncertain";
    case 10: return "durable replay whole frame exceeds limit";
    case 11: return "durable replay resource limit";
    case 12: return "durable replay cancelled";
    case 13: return "durable replay deadline";
    case 14: return "durable replay work limit";
    case 15: return "durable replay busy";
    case 16: return "durable replay database error";
    case 17: return "durable replay rollback failed";
    }
    return "durable replay unknown status";
}
uint8_t raw_byte(char value) noexcept { return static_cast<uint8_t>(static_cast<unsigned char>(value)); }
}

struct experimental_durable_page::impl {
    const replay::page value;
    const replay::encoded_cursor token;
    const uint64_t backing_bytes;
    impl(replay::page&& page, const replay::encoded_cursor& cursor)
        : value(std::move(page)), token(cursor),
          backing_bytes(static_cast<uint64_t>(sizeof(impl)) + (value.allocated_bytes ? value.allocated_bytes - sizeof(replay::page) : 0)) {}
    const replay::frame_header& frame(uint64_t index) const {
        if (index >= value.frame_count || !value.frames) throw std::out_of_range("durable frame index out of range");
        const auto& frame = value.frames[index];
        if (frame.row_offset > value.row_count || frame.row_count > value.row_count - frame.row_offset)
            throw std::out_of_range("durable frame row range invalid");
        return frame;
    }
    const replay::audit_header& row(uint64_t index) const {
        if (index >= value.row_count || !value.rows) throw std::out_of_range("durable audit row index out of range");
        return value.rows[index];
    }
    replay::text_field text(uint64_t index, int32_t field) const {
        const auto& header = row(index);
        replay::text_field selected;
        switch (field) {
        case 0: selected = header.global_id; break;
        case 1: selected = header.table_name; break;
        case 2: selected = header.operation; break;
        case 3: selected = header.global_row_id; break;
        case 4: selected = header.changed_field_names; break;
        default: throw std::out_of_range("durable text field out of range");
        }
        if (!selected.is_null && (selected.offset > value.text_bytes ||
            selected.size > value.text_bytes - selected.offset || (selected.size && !value.text)))
            throw std::out_of_range("durable text byte range invalid");
        return selected;
    }
};

experimental_durable_page experimental_durable_bridge_access::adopt(replay::page value) noexcept {
    bool completed = false;
    int32_t failure = 11;
    const auto original_diagnostic = translated(value.result);
    const auto original_snapshot = value.snapshot;
    const auto preserve_snapshot = [&](experimental_durable_page& result) noexcept {
        result.fallback_snapshot_ = {original_snapshot.audit_head,
            original_snapshot.capture_started_after, original_snapshot.pruned_through};
        result.fallback_store_uuid_ = original_snapshot.store_uuid;
        result.fallback_history_epoch_ = original_snapshot.history_epoch;
    };
    auto wrapped = sealed([&] {
        // Failed results need no allocation and remain non-advancing. Keeping
        // diagnostics/snapshot inline preserves cleanup failures and known gap
        // positions during OOM without inventing snapshot validity.
        if (value.result.status != replay::code::ready || !value.result.cleanup_ok) {
            experimental_durable_page result;
            result.fallback_ = translated(value.result);
            preserve_snapshot(result);
            if (value.result.status == replay::code::ready) result.fallback_.status = 17;
            completed = true;
            return result;
        }
        replay::encoded_cursor token{};
        if (value.has_cursor && replay::encode_cursor(value.next, token) != replay::code::ready) {
            experimental_durable_page result;
            result.fallback_ = translated(value.result);
            preserve_snapshot(result);
            result.fallback_.status = 3;
            completed = true;
            return result;
        }
        failure = 1;
        if ((value.frame_count && !value.frames) || (value.row_count && !value.rows) ||
            (value.text_bytes && !value.text) ||
            (!value.allocated_bytes && (value.frames || value.rows || value.text)) ||
            (value.allocated_bytes && value.allocated_bytes < sizeof(replay::page)))
            throw std::invalid_argument("durable page allocation metadata invalid");
        failure = 11;
        if (value.allocated_bytes && value.allocated_bytes - sizeof(replay::page) >
            std::numeric_limits<uint64_t>::max() - sizeof(experimental_durable_page::impl))
            throw std::length_error("durable backing byte count overflow");
        experimental_durable_page result;
        result.impl_ = std::make_shared<const experimental_durable_page::impl>(std::move(value), token);
        completed = true;
        return result;
    });
    // A failed allocation must not depend on allocating the TLS error message.
    if (!completed) {
        wrapped.fallback_ = original_diagnostic;
        wrapped.fallback_.status = failure;
        preserve_snapshot(wrapped);
    }
    return wrapped;
}
experimental_durable_diagnostic experimental_durable_page::result() const noexcept {
    return impl_ ? translated(impl_->value.result) : fallback_;
}
int32_t experimental_durable_page::status_code() const noexcept { return result().status; }
std::string experimental_durable_page::error_message() const {
    return sealed([&] { return std::string(message(status_code())); });
}
bool experimental_durable_page::has_cursor() const noexcept { return impl_ && impl_->value.has_cursor; }
bool experimental_durable_page::at_head() const noexcept { return impl_ && impl_->value.at_head; }
uint64_t experimental_durable_page::frame_count() const noexcept { return impl_ ? impl_->value.frame_count : 0; }
uint64_t experimental_durable_page::row_count() const noexcept { return impl_ ? impl_->value.row_count : 0; }
uint64_t experimental_durable_page::text_bytes() const noexcept { return impl_ ? impl_->value.text_bytes : 0; }
uint64_t experimental_durable_page::allocated_backing_bytes() const noexcept { return impl_ ? impl_->backing_bytes : 0; }
bool experimental_durable_page::shares_backing(const experimental_durable_page& other) const noexcept {
    return impl_ && impl_ == other.impl_;
}
experimental_durable_snapshot experimental_durable_page::snapshot() const noexcept {
    if (!impl_) return fallback_snapshot_;
    const auto& value = impl_->value.snapshot;
    return {value.audit_head, value.capture_started_after, value.pruned_through};
}
experimental_durable_frame_header experimental_durable_page::frame(uint64_t index) const {
    return sealed([&]() -> experimental_durable_frame_header {
        if (!impl_) throw std::out_of_range("durable page has no backing");
        const auto& value = impl_->frame(index);
        return {value.id, value.first_audit_id, value.last_audit_id, value.row_offset, value.row_count};
    });
}
uint8_t experimental_durable_page::frame_key_byte(uint64_t index, uint64_t byte) const {
    return sealed([&]() -> uint8_t {
        if (!impl_ || byte >= 32) throw std::out_of_range("durable frame key byte out of range");
        return raw_byte(impl_->frame(index).key[byte]);
    });
}
int64_t experimental_durable_page::audit_id(uint64_t row) const {
    return sealed([&]() -> int64_t {
        if (!impl_) throw std::out_of_range("durable page has no backing");
        return impl_->row(row).id;
    });
}
experimental_durable_text_field experimental_durable_page::text_field(uint64_t row, int32_t field) const {
    return sealed([&]() -> experimental_durable_text_field {
        if (!impl_) throw std::out_of_range("durable page has no backing");
        const auto value = impl_->text(row, field);
        return {value.is_null ? 0u : value.size, value.is_null};
    });
}
uint8_t experimental_durable_page::text_byte(uint64_t row, int32_t field, uint64_t byte) const {
    return sealed([&]() -> uint8_t {
        if (!impl_) throw std::out_of_range("durable page has no backing");
        const auto value = impl_->text(row, field);
        if (value.is_null || byte >= value.size) throw std::out_of_range("durable text byte out of range");
        return raw_byte(impl_->value.text[value.offset + byte]);
    });
}
experimental_durable_integer_field experimental_durable_page::integer_field(uint64_t row, int32_t field) const {
    return sealed([&]() -> experimental_durable_integer_field {
        if (!impl_) throw std::out_of_range("durable page has no backing");
        const auto& value = impl_->row(row);
        replay::integer_field selected;
        switch (field) {
        case 0: selected = value.row_id; break;
        case 1: selected = value.is_from_remote; break;
        case 2: selected = value.synthesized; break;
        default: throw std::out_of_range("durable integer field out of range");
        }
        return {selected.value, selected.is_null};
    });
}
uint8_t experimental_durable_page::snapshot_identity_byte(int32_t identity, uint64_t byte) const {
    return sealed([&]() -> uint8_t {
        if (byte >= 32 || (identity != 0 && identity != 1))
            throw std::out_of_range("durable snapshot identity byte out of range");
        if (!impl_) return raw_byte((identity == 0 ? fallback_store_uuid_ : fallback_history_epoch_)[byte]);
        return raw_byte((identity == 0 ? impl_->value.snapshot.store_uuid : impl_->value.snapshot.history_epoch)[byte]);
    });
}
uint64_t experimental_durable_page::cursor_byte_count() const noexcept { return has_cursor() ? replay::encoded_cursor_size : 0; }
uint8_t experimental_durable_page::cursor_byte(uint64_t byte) const {
    return sealed([&]() -> uint8_t {
        if (!has_cursor() || byte >= replay::encoded_cursor_size) throw std::out_of_range("durable cursor byte out of range");
        return raw_byte(impl_->token[byte]);
    });
}

struct experimental_durable_stop_control::impl {
    // Native callers receive an aliasing shared_ptr to this one fixed flag.
    // Retaining that alias performs no allocation and retains no parent.
    replay::stop_control stop;
};
experimental_durable_stop_control experimental_durable_stop_control::make() {
    return sealed([] {
        experimental_durable_stop_control result;
        result.impl_ = std::make_shared<impl>();
        return result;
    });
}
bool experimental_durable_stop_control::is_valid() const noexcept { return static_cast<bool>(impl_); }
bool experimental_durable_stop_control::is_cancelled() const noexcept {
    return impl_ && impl_->stop.cancelled.load(std::memory_order_acquire);
}
bool experimental_durable_stop_control::same_operation(const experimental_durable_stop_control& other) const noexcept {
    return impl_ && impl_ == other.impl_;
}
void experimental_durable_stop_control::cancel() const noexcept {
    if (impl_) impl_->stop.cancelled.store(true, std::memory_order_release);
}
std::shared_ptr<replay::stop_control> experimental_durable_bridge_access::stop(
    const experimental_durable_stop_control& value) noexcept {
    return value.impl_ ? std::shared_ptr<replay::stop_control>(value.impl_, &value.impl_->stop)
                       : std::shared_ptr<replay::stop_control>{};
}
} // namespace lattice
#endif

#if defined(LATTICE_EXPERIMENTAL_OWNED_READ) && LATTICE_EXPERIMENTAL_OWNED_READ && !defined(__EMSCRIPTEN__)
#include <experimental_owned_read.hpp>
#include <lattice.hpp>
#include "observation_owner.hpp"

namespace lattice {
// No public raw-owner getter, weak-cache lookup, or stored operation lifetime.
struct experimental_owned_read_access {
    static std::shared_ptr<swift_lattice> retain(const swift_lattice_ref& owner) noexcept {
        return owner.impl_;
    }
};
namespace {
namespace owned_replay = observation_frames::replay;
bool owned_read_model_valid(const std::string& model) noexcept {
    if (model.empty() || model.size() > 64 || model.front() == '_') return false;
    for (unsigned char byte : model) {
        if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
              (byte >= '0' && byte <= '9') || byte == '_')) return false;
    }
    return true;
}
bool owned_read_limits_valid(const experimental_owned_read_limits& value) noexcept {
    // Bound before conversion or multiplication. These are the existing
    // read_frames limits, including its fixed-array admission requirement.
    if (value.max_frames == 0 || value.max_frames > 256 ||
        value.max_rows == 0 || value.max_rows > 4096 ||
        value.max_bytes < sizeof(owned_replay::page) || value.max_bytes > 8 * 1024 * 1024 ||
        value.max_vm_steps < 128 || value.max_vm_steps > 50000000 ||
        value.timeout_ms <= 0 || value.timeout_ms > 30000 ||
        value.max_frames > std::numeric_limits<size_t>::max() ||
        value.max_rows > std::numeric_limits<size_t>::max() ||
        value.max_bytes > std::numeric_limits<size_t>::max()) return false;
    const uint64_t fixed = sizeof(owned_replay::page) +
        value.max_frames * sizeof(owned_replay::frame_header) +
        value.max_rows * sizeof(owned_replay::audit_header);
    return fixed <= value.max_bytes;
}
experimental_durable_page owned_read_failure(owned_replay::code status) noexcept {
    owned_replay::page page;
    page.result.status = status;
    return experimental_durable_bridge_access::adopt(std::move(page));
}
} // namespace

experimental_durable_page experimental_owned_read(
    const swift_lattice_ref& owner, const std::string& model, const std::string& cursor,
    const experimental_owned_read_limits& limits,
    const experimental_durable_stop_control& stop) noexcept {
    return sealed([&] {
        auto signal = experimental_durable_bridge_access::stop(stop);
        if (!signal || !owned_read_model_valid(model))
            return owned_read_failure(owned_replay::code::invalid_context);
        if (!owned_read_limits_valid(limits))
            return owned_read_failure(owned_replay::code::invalid_limits);
        owned_replay::cursor decoded;
        if (owned_replay::decode_cursor(cursor, decoded) != owned_replay::code::ready)
            return owned_read_failure(owned_replay::code::invalid_cursor);
        if (signal->cancelled.load(std::memory_order_acquire))
            return owned_read_failure(owned_replay::code::cancelled);
        auto retained = experimental_owned_read_access::retain(owner);
        if (!retained) return owned_read_failure(owned_replay::code::invalid_context);
        const owned_replay::limits bounds{
            static_cast<size_t>(limits.max_frames), static_cast<size_t>(limits.max_rows),
            static_cast<size_t>(limits.max_bytes), limits.max_vm_steps,
            static_cast<int>(limits.timeout_ms)};
        return experimental_durable_bridge_access::adopt(observation_owned::read_after(
            *retained, model, decoded, bounds, std::move(signal)));
    });
}
} // namespace lattice
#endif
