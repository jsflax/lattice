#include "LatticeDebugBridge.hpp"
#include <list.hpp>
#include <geo_bounds.hpp>
#include <stdexcept>
#include <limits>

namespace lattice_debug {

bool set_generation_query_gap_for_testing(const lattice::swift_lattice_ref& reference,
                                          void* context,
                                          void (*callback)(void*),
                                          void (*destroy)(void*)) {
    lattice::last_bridge_error().clear();
    try {
        // Own the callback context on every path, including an invalid handle.
        auto shared_ctx = std::shared_ptr<void>(context, destroy ? destroy : [](void*){});
        if (!reference.valid()) throw std::runtime_error("Invalid test reader handle");
        // The reference wrapper is shallow-const, just like its existing const
        // generation forwarders: the pointed-to instance remains mutable.
        auto* reader = const_cast<lattice::swift_lattice*>(reference.get());
        if (!callback) {
            reader->test_hook_generation_query_gap_ = nullptr;
            return true;
        }
        reader->test_hook_generation_query_gap_ = [shared_ctx, callback] {
            callback(shared_ctx.get());
        };
        return true;
    } catch (const std::exception& error) {
        lattice::last_bridge_error() = error.what();
    } catch (...) {
        lattice::last_bridge_error() = "Unknown exception installing test generation hook";
    }
    return false;
}
namespace {
std::string identifier(const std::string& name) {
    std::string quoted = "\"";
    for (char character : name) {
        if (character == '"') quoted += '"';
        quoted += character;
    }
    return quoted + "\"";
}

size_t count_memberships(lattice::database& database, const std::string& table,
                         const std::string& parent_column, const std::string& parent_id) {
    const auto rows = database.query("SELECT COUNT(*) AS n FROM " + identifier(table) +
        " WHERE " + identifier(parent_column) + " = ? COLLATE NOCASE", {parent_id});
    if (rows.size() != 1) throw std::runtime_error("Diagnostic count returned no result");
    const auto value = rows.front().find("n");
    if (value == rows.front().end() || !std::holds_alternative<int64_t>(value->second) ||
        std::get<int64_t>(value->second) < 0) throw std::runtime_error("Invalid diagnostic count");
    return static_cast<size_t>(std::get<int64_t>(value->second));
}

std::string text_column(const lattice::database::row_t& row, const std::string& name) {
    const auto value = row.find(name);
    if (value == row.end() || !std::holds_alternative<std::string>(value->second) ||
        std::get<std::string>(value->second).empty()) throw std::runtime_error("Invalid diagnostic relationship membership");
    return std::get<std::string>(value->second);
}

// model_base exposes its identity to subclasses. Build a temporary parent
// binding from public dynamic-object getters; no private-layout access and no
// change to Core's existing Swift-facing/hot-path relationship accessors.
struct diagnostic_parent final : lattice::model_base {
    explicit diagnostic_parent(const lattice::dynamic_object& object) {
        if (!object.lattice) throw std::runtime_error("Diagnostic list requires a managed parent");
        db_ = &object.lattice->db();
        lattice_ = object.lattice.get();
        table_name_ = object.get_table_name();
        id_ = object.get_int("id");
        global_id_ = object.get_string("globalId");
        if (global_id_.empty()) throw std::runtime_error("Diagnostic parent object is unavailable");
    }
};

using managed_list = lattice::managed<std::vector<lattice::swift_dynamic_object*>>;
managed_list bind_list(const lattice::dynamic_object_ref& parent, const std::string& name) {
    const auto* object = parent.get();
    if (!object || !object->lattice) throw std::runtime_error("Diagnostic list requires a managed parent");
    const auto* schema = object->lattice->get_properties_for_table(object->get_table_name());
    if (!schema) throw std::runtime_error("Diagnostic parent schema is unavailable");
    const auto property = schema->find(name);
    if (property == schema->end() || (property->second.kind != lattice::property_kind::list &&
                                     property->second.kind != lattice::property_kind::virtual_list)) {
        throw std::runtime_error("Diagnostic property is not a relationship list");
    }
    diagnostic_parent identity(*object);
    managed_list list;
    list.bind_to_parent(&identity, property->second);
    if (list.link_table_.empty() || !list.db->table_exists(list.link_table_)) {
        throw std::runtime_error("Diagnostic relationship table is unavailable");
    }
    return list;
}
}

#if LATTICE_HAS_FRT
lattice::dynamic_object_ref* get_object(const lattice::dynamic_object_ref& parent, const std::string& name) {
#else
lattice::dynamic_object_ref get_object(const lattice::dynamic_object_ref& parent, const std::string& name) {
#endif
    lattice::last_bridge_error().clear();
    try {
        if (!parent.valid()) throw std::runtime_error("Invalid diagnostic object handle");
        return parent.get_object(name);
    } catch (const std::exception& error) {
        lattice::last_bridge_error() = error.what();
    } catch (...) {
        lattice::last_bridge_error() = "Unknown exception during diagnostic relationship read";
    }
#if LATTICE_HAS_FRT
    return nullptr;
#else
    return lattice::dynamic_object_ref::_make(nullptr);
#endif
}

size_t list_count(const lattice::dynamic_object_ref& parent, const std::string& name) {
    lattice::last_bridge_error().clear();
    try {
        const auto* object = parent.get();
        if (!object || !object->lattice) throw std::runtime_error("Diagnostic list requires a managed parent");
        const auto* schema = object->lattice->get_properties_for_table(object->get_table_name());
        if (!schema) throw std::runtime_error("Diagnostic parent schema is unavailable");
        const auto property = schema->find(name);
        if (property != schema->end() && property->second.is_geo_bounds) {
            diagnostic_parent identity(*object);
            lattice::managed<std::vector<lattice::geo_bounds*>> list;
            list.bind_to_parent(&identity, property->second);
            return count_memberships(*list.db, list.list_table_, "parent_id", list.parent_global_id_);
        }
        auto list = bind_list(parent, name);
        return count_memberships(*list.db, list.link_table_, "lhs", list.parent_global_id_);
    } catch (const std::exception& error) {
        lattice::last_bridge_error() = error.what();
    } catch (...) {
        lattice::last_bridge_error() = "Unknown exception during diagnostic relationship count";
    }
    return 0;
}

#if LATTICE_HAS_FRT
lattice::dynamic_object_ref* list_object(const lattice::dynamic_object_ref& parent, const std::string& name, size_t index) {
#else
lattice::dynamic_object_ref list_object(const lattice::dynamic_object_ref& parent, const std::string& name, size_t index) {
#endif
    lattice::last_bridge_error().clear();
    try {
        const auto list = bind_list(parent, name);
        if (index > static_cast<size_t>(std::numeric_limits<int64_t>::max())) {
            throw std::out_of_range("Diagnostic list index is out of range");
        }
        // Read one membership. Never invoke the ORM list's size/subscript:
        // those hydrate the entire list even when only a count was requested.
        const std::string columns = list.is_virtual_ ? "\"rhs\", \"rhs_type\"" : "\"rhs\"";
        const auto memberships = list.db->query("SELECT " + columns + " FROM " + identifier(list.link_table_) +
            " WHERE \"lhs\" = ? COLLATE NOCASE ORDER BY rowid LIMIT 1 OFFSET ?",
            {list.parent_global_id_, static_cast<int64_t>(index)});
        if (memberships.empty()) throw std::out_of_range("Diagnostic list index is out of range");
        const auto global_id = text_column(memberships.front(), "rhs");
        const auto target = list.is_virtual_ ? text_column(memberships.front(), "rhs_type") : list.target_table_;
        const auto* schema = parent.get()->lattice->get_properties_for_table(target);
        if (!schema) throw std::runtime_error("Diagnostic relationship target schema is unavailable");
        // find_by_global_id interpolates the table identifier. Quote it here,
        // then restore the raw model name on the hydrated handle below.
        auto selected = parent.get()->lattice->find_by_global_id<lattice::swift_dynamic_object>(global_id, identifier(target));
        if (!selected) throw std::runtime_error("Diagnostic relationship points to a missing object");
        auto object = std::move(*selected);
        std::vector<std::string> names;
        std::unordered_map<std::string, lattice::column_type> types;
        for (const auto& [name, property] : *schema) {
            object.properties_[name] = property;
            types[name] = property.type;
            names.push_back(name);
        }
        object.set_schema(target, std::move(names), std::move(types));
        object.source.table_name = target;
        object.source.properties = *schema;
        return lattice::dynamic_object_ref::wrap(lattice::dynamic_object(object).make_shared());
    } catch (const std::exception& error) {
        lattice::last_bridge_error() = error.what();
    } catch (...) {
        lattice::last_bridge_error() = "Unknown exception during diagnostic relationship element read";
    }
#if LATTICE_HAS_FRT
    return nullptr;
#else
    return lattice::dynamic_object_ref::_make(nullptr);
#endif
}
}
