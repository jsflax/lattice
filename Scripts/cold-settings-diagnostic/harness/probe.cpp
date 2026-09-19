#include <lattice/lattice.hpp>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

struct ColdKeeperRow { int64_t rank=0; std::string title; double rating=0; };
LATTICE_SCHEMA(ColdKeeperRow, rank, title, rating);
namespace {
using Clock=std::chrono::steady_clock;
void require(bool ok,const char* text) { if(!ok)throw std::runtime_error(text); }
lattice::configuration config(const std::string& path) {
    lattice::configuration result(path);result.audit_retention_seconds=0;return result;
}
void sample(lattice::lattice_db& owner,const char* label,bool cold) {
#if defined(LATTICE_COLD_KEEPER_TIMING) && LATTICE_COLD_KEEPER_TIMING
    namespace timing=lattice::detail::cold_keeper_timing;
    require(timing::arm(&owner),"diagnostic already armed");
#endif
    uint64_t generation=0;
    struct Release {
        lattice::lattice_db& owner;uint64_t& id;
        ~Release(){if(id)owner.release_read_generation(id);}
    } release{owner,generation};
    const auto statements_before=lattice::database::thread_statement_count();
    const auto begin=Clock::now();
    generation=owner.acquire_read_generation();
    // The same builder and keeper query used by Core page consumers. Neither
    // source construction nor actual SQL is moved outside this timed interval.
    const auto sql=lattice::lattice_db::build_query_rows_sql(
        "ColdKeeperRow",std::nullopt,std::string("rank ASC"),int64_t{100});
    auto rows=owner.query_at_generation(generation,sql);
    const auto end=Clock::now();
    const auto statements=lattice::database::thread_statement_count()-statements_before;
#if defined(LATTICE_COLD_KEEPER_TIMING) && LATTICE_COLD_KEEPER_TIMING
    const auto timing_snapshot=timing::finish();
#endif
    require(generation!=0&&rows&&rows->size()==100,"actual keeper/page unavailable");
    for(int64_t i=0;i<100;++i) {
        const auto& row=rows->at(static_cast<size_t>(i));
        require(std::get<int64_t>(row.at("rank"))==i,"page ordering/value mismatch");
        require(std::get<std::string>(row.at("title"))=="keeper-"+std::to_string(i),"page string mismatch");
        require(std::get<double>(row.at("rating"))==static_cast<double>(i)+0.25,"page double mismatch");
    }
#if defined(LATTICE_COLD_KEEPER_TIMING) && LATTICE_COLD_KEEPER_TIMING
    const auto& t=timing_snapshot;
    require(!t.invalid&&t.acquired&&t.queried&&t.acquire_success&&t.page_success&&t.size<=27,
            "incomplete/overflow/reentrant diagnostic sample");
    std::array<unsigned,32> occurrences{};
    for(size_t i=0;i<t.size;++i) {
        const auto tag=static_cast<size_t>(t.records[i].tag);
        require(tag>0&&tag<occurrences.size(),"unknown diagnostic phase");++occurrences[tag];
        if(i)require(t.records[i].ns>=t.records[i-1].ns,"nonmonotonic diagnostic clock");
    }
    for(const auto tag:{timing::phase::acquire_enter,timing::phase::eviction_done,
        timing::phase::pool_selected,timing::phase::begin_begin,timing::phase::begin_end,
        timing::phase::pin_begin,timing::phase::pin_end,timing::phase::publication_begin,
        timing::phase::publication_end,timing::phase::acquire_exit,timing::phase::page_enter,
        timing::phase::page_admitted,timing::phase::sql_begin,timing::phase::sql_end,timing::phase::page_exit})
        require(occurrences[static_cast<size_t>(tag)]==1,"required phase missing/duplicated");
    for(const auto tag:{timing::phase::constructor_begin,timing::phase::constructor_end,
        timing::phase::open_begin,timing::phase::open_end,
        timing::phase::settings_end,timing::phase::vector_end,
        timing::phase::busy_begin,timing::phase::busy_end,timing::phase::foreign_keys_end,
        timing::phase::cache_end_setting,timing::phase::mmap_end,timing::phase::temp_end})
        require(occurrences[static_cast<size_t>(tag)]==(cold?1U:0U),"unexpected pool/constructor branch");
    require(occurrences[static_cast<size_t>(timing::phase::cache_begin)]==0&&
            occurrences[static_cast<size_t>(timing::phase::cache_end)]==0,"obsolete cache-clamp phase");
    require(occurrences[static_cast<size_t>(timing::phase::victim_begin)]==0&&
            occurrences[static_cast<size_t>(timing::phase::victim_end)]==0,"unexpected victim retirement");
#endif
    // All formatting is outside the measured interval and recorder lifetime.
    std::cout<<"{\"sample\":\""<<label<<"\",\"cppScopeOnly\":true,\"rows\":100,\"sql\":"<<statements
             <<",\"totalNs\":"<<std::chrono::duration_cast<std::chrono::nanoseconds>(end-begin).count();
#if defined(LATTICE_COLD_KEEPER_TIMING) && LATTICE_COLD_KEEPER_TIMING
    std::cout<<",\"instrumented\":true,\"records\":[";
    for(size_t i=0;i<t.size;++i) {
        if(i)std::cout<<',';
        std::cout<<"{\"tag\":"<<static_cast<unsigned>(t.records[i].tag)
                 <<",\"offsetNs\":"<<t.records[i].ns-t.records[0].ns
                 <<",\"fact\":"<<t.records[i].fact<<'}';
    }
    std::cout<<']';
#else
    (void)cold;std::cout<<",\"instrumented\":false";
#endif
    std::cout<<"}\n";
}
}
int main(int argc,char** argv) {
    try {
        require(argc==2,"one fresh owned SQLite path required");
        // Identity collection is outside both cold and warm intervals.
        std::cout<<"{\"sqliteVersion\":\""<<sqlite3_libversion()
                 <<"\",\"sqliteSourceId\":\""<<sqlite3_sourceid()<<"\"}\n";
        const std::filesystem::path path(argv[1]);
        require(path.is_absolute()&&std::filesystem::is_directory(path.parent_path()),"existing absolute owned parent required");
        for(const auto& suffix:{"","-wal","-shm"})
            require(!std::filesystem::exists(path.string()+suffix),"fixture must be fresh; existing stores are never replaced");
        {
            lattice::lattice_db seed(config(path.string()));
            for(int64_t i=0;i<100;++i)seed.add(ColdKeeperRow{i,"keeper-"+std::to_string(i),static_cast<double>(i)+0.25});
        }
        // Opening ordinary and cross-process readers remains before sampling.
        lattice::lattice_db owner(config(path.string()));
        require(owner.idle_read_pool_size()==0,"fresh owner has no warm keeper");
        sample(owner,"cold",true);
        require(owner.idle_read_pool_size()==1,"released keeper available for separate warm control");
        sample(owner,"warm",false);
        // Owner and store are retained through all samples. Parent verifies
        // process-group cleanup before any successful-fixture removal.
        return 0;
    }catch(const std::exception& error){std::cerr<<"keeper_probe_failure: "<<error.what()<<'\n';return 1;}
}
