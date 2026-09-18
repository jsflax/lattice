// Owned diagnostic only. Exact7b11 Core remains unchanged.
#include <lattice/lattice.hpp>
#include <lattice/sync.hpp>
#include <lattice/log.hpp>
#include <nlohmann/json.hpp>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>
#include "phase_trace.hpp"

struct RetentionStream { std::string body; int64_t revision = 0; };
LATTICE_SCHEMA(RetentionStream, body, revision);
namespace {
using namespace lattice;
using json = nlohmann::json;
using clock_type = std::chrono::steady_clock;
void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
int64_t ns() { return std::chrono::duration_cast<std::chrono::nanoseconds>(clock_type::now().time_since_epoch()).count(); }
void emit(json value) { value["pid"] = getpid(); std::cout << value.dump() << '\n' << std::flush; }
void command() { char c = 0; require(::read(STDIN_FILENO, &c, 1) == 1 && c == 'G', "control pipe closed/invalid"); }
int64_t scalar(database& db, const std::string& sql) {
    const auto rows = db.query(sql); require(rows.size() == 1 && rows[0].size() == 1, "invalid scalar result");
    return std::get<int64_t>(rows[0].begin()->second);
}
std::string payload(int64_t revision, size_t bytes) {
    const auto prefix = std::to_string(revision) + ':';
    require(prefix.size() <= bytes, "payload overflow");
    return prefix + std::string(bytes - prefix.size(), static_cast<char>('a' + revision % 26));
}
configuration config(const std::string& path) {
    configuration c(path); c.busy_timeout_ms = 5000; c.audit_retention_seconds = 600; return c;
}
json checkpoint(database& db) {
    const auto r = db.wal_checkpoint(true, 250);
    return {{"rc", r.rc}, {"busy", r.busy}, {"logFrames", r.log_frames}, {"checkpointed", r.checkpointed}};
}
void identity(database& db) {
    Dl_info image{}; dladdr(reinterpret_cast<const void*>(&sqlite3_prepare_v2), &image);
    json options = json::array(); for (int n=0; const char* option=sqlite3_compileoption_get(n); ++n) options.push_back(option);
    json pragmas = json::object();
    for (const auto* name : {"journal_mode","synchronous","page_size","cache_size","mmap_size","temp_store","busy_timeout","wal_autocheckpoint","journal_size_limit"}) {
        const auto rows = db.query(std::string("PRAGMA ")+name); require(rows.size()==1 && rows[0].size()==1,"pragma shape");
        const auto& value=rows[0].begin()->second;
        if (const auto* number=std::get_if<int64_t>(&value)) pragmas[name]=*number;
        else if (const auto* text=std::get_if<std::string>(&value)) pragmas[name]=*text;
        else throw std::runtime_error("pragma type");
    }
    emit({{"kind","identity"},{"version",sqlite3_libversion()},{"sourceID",sqlite3_sourceid()},
          {"threadsafe",sqlite3_threadsafe()},{"image",image.dli_fname?image.dli_fname:""},
          {"compileOptions",options},{"pragmas",pragmas}});
}
void seed(const std::string& path) {
    require(!std::filesystem::exists(path), "seed file exists");
    lattice_db owner(config(path)); owner.stop_audit_maintenance(); auto& db=owner.db();
    owner.begin_transaction();
    for(int n=0;n<100;++n) owner.add(RetentionStream{payload(0,1024),0});
    owner.commit();
    for(int round=1;round<100;++round) {
        owner.begin_transaction();
        for(int64_t id=1;id<=100;++id)
            db.execute("UPDATE RetentionStream SET body=?,revision=? WHERE id=?", {payload(round,1024),int64_t(round),id});
        owner.commit();
    }
    require(scalar(db,"SELECT count(*) FROM AuditLog")==10000,"seed audit cardinality");
    require(scalar(db,"SELECT MAX(id) FROM AuditLog")==10000,"seed audit IDs");
    owner.record_audit_watermark(); owner.backdate_audit_watermarks(900);
    owner.begin_transaction();
    for(int n=0;n<10;++n) owner.add(RetentionStream{payload(0,256),0});
    owner.commit();
    identity(db);
    json definitions=json::array();
    for(const auto& row:db.query("SELECT type,name,sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY type,name"))
        definitions.push_back({{"type",std::get<std::string>(row.at("type"))},{"name",std::get<std::string>(row.at("name"))},{"sql",std::get<std::string>(row.at("sql"))}});
    const auto checkpoint_result=checkpoint(db);
    require(checkpoint_result.at("rc")==0 && checkpoint_result.at("busy")==0,"seed checkpoint busy/failed");
    emit({{"kind","seed"},{"oldMax",10000},{"auditRows",scalar(db,"SELECT count(*) FROM AuditLog")},
          {"sequence",scalar(db,"SELECT seq FROM sqlite_sequence WHERE name='AuditLog'")},
          {"auditPayloadBytes",scalar(db,"SELECT SUM(length(CAST(changedFields AS BLOB))+length(CAST(changedFieldsNames AS BLOB))) FROM AuditLog")},
          {"pageCount",scalar(db,"PRAGMA page_count")},{"freePages",scalar(db,"PRAGMA freelist_count")},
          {"definitions",definitions},{"checkpoint",checkpoint_result}});
}
struct write_sample { int64_t index,start,end; };
void writer(const std::string& path) {
    lattice_db owner(config(path)); owner.stop_audit_maintenance(); identity(owner.db());
    std::array<write_sample,1000> samples{};
    emit({{"kind","ready"},{"role","writer"}}); command();
    for(int64_t index=0;index<1000;++index) {
        if(index==200) { emit({{"kind","writerPaused"},{"completed",200}}); command(); }
        const auto body=payload(index+1,256); const int64_t id=101+index%10;
        auto& sample=samples[static_cast<size_t>(index)]; sample.index=index; sample.start=ns();
        owner.db().execute("UPDATE RetentionStream SET body=?,revision=? WHERE id=?",{body,index+1,id});
        sample.end=ns();
    }
    for(const auto& sample:samples) emit({{"kind","write"},{"index",sample.index},{"startNS",sample.start},{"endNS",sample.end}});
    const auto begin=ns(); owner.close();
    emit({{"kind","writerDone"},{"writes",1000},{"logicalCloseNS",ns()-begin}});
}
struct trace_state {
    int claims=0,prunes=0; bool barrier=false,failed=false;
    static int trace(unsigned event,void* context,void* statement,void*) noexcept {
        if(event!=SQLITE_TRACE_STMT)return 0;
        auto& s=*static_cast<trace_state*>(context); const char* sql=sqlite3_sql(static_cast<sqlite3_stmt*>(statement));
        if(!sql)return 0;
        if(std::strstr(sql,"SELECT MAX(CAST(value AS INTEGER)) AS m FROM _lattice_meta")==sql)++s.prunes;
        if(std::strstr(sql,"INSERT INTO _lattice_meta")==sql && std::strstr(sql,"'audit_prune_at'")) {
            ++s.claims;
            if(s.barrier) { // Diagnostic-only fixed tuple. No JSON/allocation/SQL in callback.
                constexpr char ready[]="{\"kind\":\"claimBarrier\"}\n"; char command=0;
                if(::write(STDOUT_FILENO,ready,sizeof(ready)-1)!=sizeof(ready)-1 ||
                   ::read(STDIN_FILENO,&command,1)!=1 || command!='G')s.failed=true;
            }
        }
        return 0;
    }
};
void maintenance(const std::string& path,const std::string& arm,bool traced,bool contender,bool phase_traced=false) {
    lattice_db owner(config(path)); owner.stop_audit_maintenance(); auto& db=owner.db();
    if(!contender) {
        // This is the sole intentional A/B fixture difference.
        db.execute("INSERT OR REPLACE INTO _lattice_meta(key,value) VALUES('audit_prune_at',?)",
          {arm=="B"?std::string("0"):std::to_string(owner.now_epoch_())});
    }
    identity(db); trace_state trace;trace.barrier=contender;
    if(traced)require(sqlite3_trace_v2(db.handle(),SQLITE_TRACE_STMT,trace_state::trace,&trace)==SQLITE_OK,"trace install");
    retention_phases::recorder phases;
    retention_phases::registration phase_hook(db.handle());
    require(!phase_traced || !traced,"separate diagnostic modes");
    if(phase_traced)require(phase_hook.install(phases)==SQLITE_OK,"phase trace install");
    emit({{"kind","ready"},{"role","maintenance"}});command();
    emit({{"kind","tickEntering"}}); const auto start=ns(); owner.run_audit_retention_tick(); const auto end=ns();
    if(traced)require(sqlite3_trace_v2(db.handle(),0,nullptr,nullptr)==SQLITE_OK,"trace remove");
    if(phase_traced)require(phase_hook.remove()==SQLITE_OK,"phase trace remove");
    // Hook removal precedes all allocation/formatting. This record contains no
    // SQL bodies, bound values, paths or statement addresses. PROFILE is an
    // approximate SQLite duration, not a return code or lock-acquisition event.
    if(phase_traced) {
        json records=json::array();
        for(size_t i=0;i<phases.count;++i) {
            const auto& row=phases.records[i];
            records.push_back({{"ordinal",i},{"phase",retention_phases::name(row.label)},
                {"startNS",row.start_ns},{"endNS",row.end_ns},{"finished",row.finished},
                {"sqliteProfileNS",row.sqlite_profile_ns}});
        }
        emit({{"kind","maintenancePhases"},{"schema","retention.phases/1"},
            {"capacity",phases.capacity},{"activeCapacity",phases.active_capacity},
            {"recordCount",phases.count},{"records",records},
            {"statementCallbacks",phases.statement_callbacks},{"profileCallbacks",phases.profile_callbacks},
            {"triggerCallbacks",phases.trigger_callbacks},{"duplicateStarts",phases.duplicate_starts},
            {"droppedRecords",phases.dropped_records},{"activeOverflow",phases.active_overflow},
            {"unmatchedProfiles",phases.unmatched_profiles},{"missingSQL",phases.missing_sql}});
    }
    require(!trace.failed,"claim callback handshake");
    emit({{"kind","tickDone"},{"startNS",start},{"endNS",end},{"claims",trace.claims},{"prunes",trace.prunes},{"instrumented",traced||phase_traced}});
    const auto begin=ns();owner.close();emit({{"kind","maintenanceClosed"},{"logicalCloseNS",ns()-begin}});
}
void reader(const std::string& path) {
    database db(path,database::open_mode::read_only,5000); sqlite3_stmt* raw=nullptr;
    require(sqlite3_prepare_v2(db.handle(),"SELECT id FROM AuditLog ORDER BY id",-1,&raw,nullptr)==SQLITE_OK,"reader prepare");
    std::unique_ptr<sqlite3_stmt,decltype(&sqlite3_finalize)> statement(raw,sqlite3_finalize);
    require(sqlite3_step(raw)==SQLITE_ROW && sqlite3_stmt_busy(raw),"reader snapshot missing");
    require(sqlite3_column_int64(raw,0)==1,"reader pre-prune snapshot mismatch");
    emit({{"kind","readerPinned"},{"firstID",1},{"startedNS",ns()}});command();
    int64_t rows=1;int rc;while((rc=sqlite3_step(raw))==SQLITE_ROW)++rows;
    require(rc==SQLITE_DONE && rows==10010,"held reader snapshot changed");statement.reset();
    emit({{"kind","readerReleased"},{"rows",rows},{"endedNS",ns()}});
}
void correctness(const std::string& path,const std::string& recipient_path) {
    require(!std::filesystem::exists(path) && !std::filesystem::exists(recipient_path),"correctness fixture exists");
    lattice_db owner(config(path));owner.stop_audit_maintenance();auto& db=owner.db();
    for(int n=0;n<10;++n)owner.add(RetentionStream{payload(n,256),n});
    const auto original=query_audit_log(db);require(original.size()==10,"original audit fixture");
    owner.record_audit_watermark();owner.backdate_audit_watermarks(900);
    register_replication_slot(db,"writer");register_replication_slot(db,"observer",true);
    std::vector<std::string> first;
    for(int n=0;n<5;++n)first.push_back(original[static_cast<size_t>(n)].global_id);
    mark_audit_entries_synced_for(owner,first,"writer",{"writer"});
    advance_upload_floor(db,"writer",5);
    // Declared diagnostic setup: confirmed can be holey; only floor is safe.
    db.execute("UPDATE _lattice_replication_slots SET confirmed_audit_id=10 WHERE sync_id='writer'");
    bool denied=false;
    struct authorizer_scope {
        sqlite3* handle;
        ~authorizer_scope(){sqlite3_set_authorizer(handle,nullptr,nullptr);}
    } authorization{db.handle()};
    require(sqlite3_set_authorizer(authorization.handle,
        [](void* context,int action,const char* table,const char*,const char*,const char*) noexcept {
            if(action==SQLITE_DELETE && table && std::strcmp(table,"AuditLog")==0){*static_cast<bool*>(context)=true;return SQLITE_DENY;}
            return SQLITE_OK;
        },&denied)==SQLITE_OK,"denial install");
    owner.run_audit_retention_tick();
    require(denied,"fault injection did not run");
    require(scalar(db,"SELECT count(*) FROM AuditLog")==10 && scalar(db,"SELECT disabled FROM _SyncControl WHERE id=1")==0,"failed prune did not roll back");
    require(scalar(db,"SELECT count(*) FROM _lattice_meta WHERE key='audit_prune_at'")==0,"failed claim not released");
    require(sqlite3_set_authorizer(authorization.handle,nullptr,nullptr)==SQLITE_OK,"denial remove");
    owner.run_audit_retention_tick();
    require(scalar(db,"SELECT count(*) FROM AuditLog")==5 && scalar(db,"SELECT MIN(id) FROM AuditLog")==6,"retry/floor bound");
    const auto pending=query_audit_log_for_sync(db,"writer",std::nullopt,read_upload_floor(db,"writer"),100);
    require(pending.size()==5,"partial ACK remainder lost");
    for(size_t n=0;n<5;++n)require(pending[n].global_id==original[n+5].global_id,"partial ACK ordering changed");
    lattice_db recipient(config(recipient_path));recipient.stop_audit_maintenance();
    require(apply_remote_changes(recipient,original).size()==10,"recipient initial state");
    std::vector<audit_log_entry> remote;
    for(int n=0;n<2;++n){auto e=original.back();e.id=0;e.global_id=n?"00000000-0000-4000-8000-000000000102":"00000000-0000-4000-8000-000000000101";
        e.operation="UPDATE";e.timestamp="1970-01-01T00:00:01.000Z";e.is_from_remote=true;
        e.changed_fields={{"body",std::string(n?"remote-b":"remote-a")},{"revision",int64_t(100+n)}};
        e.changed_fields_names={"body","revision"};remote.push_back(std::move(e));}
    // Cross-transport relay requires per-synchronizer receive bookkeeping.
    // Global/server apply marks an entry fully synchronized by design.
    require(apply_remote_changes_for(owner,remote,"ingress").size()==2,"late remote apply");
    require(query_audit_log_for_sync(db,"ingress",std::nullopt,0,100).size()==5,
            "ingress must exclude its two received entries while retaining five original pending rows");
    remove_replication_slot(db,"writer");
    require(owner.prune_audit_log(600)==5,"late remote old-range prune");
    require(scalar(db,"SELECT count(*) FROM AuditLog")==2 && scalar(db,"SELECT MIN(id) FROM AuditLog")==11,"ancient fresh arrivals removed");
    auto relay=query_audit_log_for_sync(db,"relay",std::nullopt,0,100);
    require(query_audit_log_for_sync(db,"ingress",std::nullopt,0,100).empty(),"received entries must not echo to ingress");
    require(relay.size()==2 && relay[0].global_id==remote[0].global_id &&
            relay[1].global_id==remote[1].global_id &&
            apply_remote_changes(recipient,relay).size()==2,"late remote final relay");
    auto body=recipient.db().query("SELECT body,revision FROM RetentionStream WHERE globalId=?",{original.back().global_row_id});
    require(body.size()==1 && std::get<std::string>(body[0].at("body"))=="remote-b" && std::get<int64_t>(body[0].at("revision"))==101,"final replicated value");
    emit({{"kind","correctness"},{"failedDeleteRolledBack",true},{"claimRetry",true},{"partialAckRemaining",5},
          {"observerFloorIgnored",true},{"ancientFreshArrivalsSurvive",2},{"finalRelayValue","remote-b"},
          {"scope","real Core apply/ACK/floor helpers; no network or complete cursor-gap protocol claim"}});
}

void validate(const std::string& path,const std::string& arm,bool foreground) {
    lattice_db owner(config(path));owner.stop_audit_maintenance();auto& db=owner.db();
    const int64_t expected=(arm=="B"?0:10000)+10+(foreground?1000:0);
    require(scalar(db,"SELECT count(*) FROM AuditLog")==expected,"audit survivor count");
    require(scalar(db,"SELECT count(*) FROM AuditLog WHERE id<=10000")== (arm=="B"?0:10000),"old audit survivor range");
    require(scalar(db,"SELECT seq FROM sqlite_sequence WHERE name='AuditLog'")==(foreground?11010:10010),"sequence changed");
    require(scalar(db,"SELECT disabled FROM _SyncControl WHERE id=1")==0,"sync disabled flag leaked");
    require(scalar(db,"SELECT count(*) FROM RetentionStream")==110,"live model count");
    const auto rows=db.query("SELECT id,body,revision FROM RetentionStream WHERE id>=101 ORDER BY id");require(rows.size()==10,"foreground final count");
    for(int64_t n=0;n<10;++n){const auto& row=rows[static_cast<size_t>(n)];int64_t revision=foreground?991+n:0;
        require(std::get<int64_t>(row.at("id"))==101+n && std::get<int64_t>(row.at("revision"))==revision &&
                std::get<std::string>(row.at("body"))==payload(revision,256),"foreground final value");}
    emit({{"kind","validated"},{"arm",arm},{"auditRows",expected},{"sequence",foreground?11010:10010}});
}
}
int main(int argc,char** argv) {
    try {
        require(argc>=3,"usage: probe ROLE PATH [ARM]");lattice::set_log_level(lattice::log_level::off);
        const std::string role=argv[1],path=argv[2],arm=argc>3?argv[3]:"";
        if(role=="seed")seed(path);
        else if(role=="writer")writer(path);
        else if(role=="correctness"){require(argc==4,"recipient path required");correctness(path,arm);}
        else if(role=="maintenance" || role=="claim" || role=="maintenance-phases"){
            require(arm=="A1"||arm=="A2"||arm=="B","arm");maintenance(path,arm,role=="claim",role=="claim",role=="maintenance-phases");
        } else if(role=="reader")reader(path);
        else if(role=="validate" || role=="validate-claim"){
            require(arm=="A1"||arm=="A2"||arm=="B","arm");validate(path,arm,role=="validate");
        } else if(role=="checkpoint") {database db(path);emit({{"kind","checkpoint"},{"result",checkpoint(db)}});}
        else throw std::runtime_error("unknown role");
        return 0;
    } catch(const std::exception& error){emit({{"kind","failure"},{"message",error.what()}});return 1;}
}
