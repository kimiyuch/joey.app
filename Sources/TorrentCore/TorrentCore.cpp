#include "TorrentCore.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

struct tc_session {
    std::unique_ptr<lt::session> ses;
    fs::path state_dir;
    fs::path resume_dir;
    std::chrono::steady_clock::time_point last_save;
};

namespace {

std::string id_of(lt::info_hash_t const &ih) {
    std::ostringstream os;
    os << ih.get_best();
    return os.str();
}

std::string id_of(lt::torrent_handle const &h) { return id_of(h.info_hashes()); }

std::string name_of(lt::torrent_handle const &h) { return h.status(lt::torrent_handle::query_name).name; }

std::vector<char> read_file(fs::path const &p) {
    std::ifstream in(p, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

void write_file(fs::path const &p, std::vector<char> const &buf) {
    fs::path tmp = p;
    tmp += ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
    }
    std::error_code ec;
    fs::rename(tmp, p, ec);
}

void set_error(char *err, int err_len, std::string const &msg) {
    if (!err || err_len <= 0) return;
    std::snprintf(err, static_cast<size_t>(err_len), "%s", msg.c_str());
}

lt::torrent_handle find(tc_session *s, const char *id) {
    for (auto const &h : s->ses->get_torrents())
        if (id_of(h) == id) return h;
    return {};
}

int add(tc_session *s, lt::add_torrent_params atp, const char *save_path, char *err, int err_len) {
    atp.save_path = save_path;
    lt::error_code ec;
    lt::torrent_handle h = s->ses->add_torrent(std::move(atp), ec);
    if (ec) {
        set_error(err, err_len, ec.message());
        return 1;
    }
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    return 0;
}

tc_state map_state(lt::torrent_status const &st) {
    if (st.errc) return TC_STATE_ERROR;
    bool paused = bool(st.flags & lt::torrent_flags::paused);
    bool auto_managed = bool(st.flags & lt::torrent_flags::auto_managed);
    if (paused) return auto_managed ? TC_STATE_QUEUED : TC_STATE_PAUSED;
    switch (st.state) {
    case lt::torrent_status::checking_files:
    case lt::torrent_status::checking_resume_data:
        return TC_STATE_CHECKING;
    case lt::torrent_status::downloading_metadata:
        return TC_STATE_METADATA;
    case lt::torrent_status::downloading:
        return TC_STATE_DOWNLOADING;
    case lt::torrent_status::finished:
        return TC_STATE_FINISHED;
    case lt::torrent_status::seeding:
        return TC_STATE_SEEDING;
    default:
        return TC_STATE_DOWNLOADING;
    }
}

// Returns the number of save_resume_data alerts (success or failure) handled.
int handle_alerts(tc_session *s, void *ctx, tc_event_cb event_cb) {
    std::vector<lt::alert *> alerts;
    s->ses->pop_alerts(&alerts);
    int resume_alerts = 0;
    for (lt::alert *a : alerts) {
        if (auto *rd = lt::alert_cast<lt::save_resume_data_alert>(a)) {
            ++resume_alerts;
            auto buf = lt::write_resume_data_buf(rd->params);
            write_file(s->resume_dir / (id_of(rd->params.info_hashes) + ".resume"), buf);
        } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
            ++resume_alerts;
        } else if (auto *fa = lt::alert_cast<lt::torrent_finished_alert>(a)) {
            fa->handle.save_resume_data(lt::torrent_handle::save_info_dict);
            if (event_cb) event_cb(ctx, TC_EVENT_FINISHED, id_of(fa->handle).c_str(), name_of(fa->handle).c_str());
        } else if (auto *ma = lt::alert_cast<lt::metadata_received_alert>(a)) {
            ma->handle.save_resume_data(lt::torrent_handle::save_info_dict);
            if (event_cb) event_cb(ctx, TC_EVENT_METADATA, id_of(ma->handle).c_str(), name_of(ma->handle).c_str());
        } else if (auto *te = lt::alert_cast<lt::torrent_error_alert>(a)) {
            if (event_cb) event_cb(ctx, TC_EVENT_ERROR, id_of(te->handle).c_str(), te->message().c_str());
        } else if (auto *fe = lt::alert_cast<lt::file_error_alert>(a)) {
            if (event_cb) event_cb(ctx, TC_EVENT_ERROR, id_of(fe->handle).c_str(), fe->message().c_str());
        }
    }
    return resume_alerts;
}

} // namespace

extern "C" {

tc_session *tc_session_create(const char *state_dir) {
    auto *s = new tc_session;
    s->state_dir = state_dir;
    s->resume_dir = s->state_dir / "resume";
    fs::create_directories(s->resume_dir);

    lt::session_params params;
    fs::path session_file = s->state_dir / "session.state";
    if (fs::exists(session_file)) {
        auto buf = read_file(session_file);
        try {
            params = lt::read_session_params(buf, lt::session_handle::save_dht_state);
        } catch (...) {
        }
    }
    auto &sp = params.settings;
    sp.set_str(lt::settings_pack::user_agent, "Joey/0.1 libtorrent/" LIBTORRENT_VERSION);
    sp.set_int(lt::settings_pack::alert_mask,
               lt::alert_category::status | lt::alert_category::error | lt::alert_category::storage);
    sp.set_bool(lt::settings_pack::enable_dht, true);
    sp.set_bool(lt::settings_pack::enable_lsd, true);
    sp.set_bool(lt::settings_pack::enable_upnp, true);
    sp.set_bool(lt::settings_pack::enable_natpmp, true);
    s->ses = std::make_unique<lt::session>(std::move(params));

    for (auto const &entry : fs::directory_iterator(s->resume_dir)) {
        if (entry.path().extension() != ".resume") continue;
        auto buf = read_file(entry.path());
        lt::error_code ec;
        lt::add_torrent_params atp = lt::read_resume_data(buf, ec);
        if (ec) continue;
        s->ses->async_add_torrent(std::move(atp));
    }
    s->last_save = std::chrono::steady_clock::now();
    return s;
}

void tc_session_destroy(tc_session *s) {
    if (!s) return;
    s->ses->pause();
    int outstanding = 0;
    for (auto const &h : s->ses->get_torrents()) {
        if (!h.is_valid()) continue;
        h.save_resume_data(lt::torrent_handle::save_info_dict);
        ++outstanding;
    }
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (outstanding > 0 && std::chrono::steady_clock::now() < deadline) {
        if (!s->ses->wait_for_alert(std::chrono::milliseconds(200))) continue;
        outstanding -= handle_alerts(s, nullptr, nullptr);
    }
    write_file(s->state_dir / "session.state", lt::write_session_params_buf(s->ses->session_state()));
    s->ses.reset();
    delete s;
}

int tc_add_torrent_file(tc_session *s, const char *path, const char *save_path, char *err, int err_len) {
    lt::add_torrent_params atp;
    try {
        atp = lt::load_torrent_file(path);
    } catch (std::exception const &e) {
        set_error(err, err_len, e.what());
        return 1;
    }
    return add(s, std::move(atp), save_path, err, err_len);
}

int tc_add_magnet(tc_session *s, const char *uri, const char *save_path, char *err, int err_len) {
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(uri, ec);
    if (ec) {
        set_error(err, err_len, ec.message());
        return 1;
    }
    return add(s, std::move(atp), save_path, err, err_len);
}

void tc_pause(tc_session *s, const char *id) {
    auto h = find(s, id);
    if (!h.is_valid()) return;
    h.unset_flags(lt::torrent_flags::auto_managed);
    h.pause(lt::torrent_handle::graceful_pause);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
}

void tc_resume(tc_session *s, const char *id) {
    auto h = find(s, id);
    if (!h.is_valid()) return;
    h.clear_error();
    h.set_flags(lt::torrent_flags::auto_managed);
    h.resume();
    h.save_resume_data(lt::torrent_handle::save_info_dict);
}

void tc_remove(tc_session *s, const char *id, int delete_files) {
    auto h = find(s, id);
    if (!h.is_valid()) return;
    std::string key = id_of(h);
    s->ses->remove_torrent(h, delete_files ? lt::session::delete_files : lt::remove_flags_t{});
    std::error_code ec;
    fs::remove(s->resume_dir / (key + ".resume"), ec);
}

void tc_force_recheck(tc_session *s, const char *id) {
    auto h = find(s, id);
    if (h.is_valid()) h.force_recheck();
}

void tc_set_sequential(tc_session *s, const char *id, int enabled) {
    auto h = find(s, id);
    if (!h.is_valid()) return;
    if (enabled)
        h.set_flags(lt::torrent_flags::sequential_download);
    else
        h.unset_flags(lt::torrent_flags::sequential_download);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
}

void tc_poll(tc_session *s, void *ctx, tc_status_cb status_cb, tc_event_cb event_cb) {
    handle_alerts(s, ctx, event_cb);

    bool save_due = std::chrono::steady_clock::now() - s->last_save > std::chrono::seconds(30);
    if (save_due) s->last_save = std::chrono::steady_clock::now();

    for (auto const &h : s->ses->get_torrents()) {
        lt::torrent_status st = h.status(lt::torrent_handle::query_name | lt::torrent_handle::query_save_path);
        if (save_due && h.need_save_resume_data()) h.save_resume_data(lt::torrent_handle::save_info_dict);

        std::string id = id_of(st.info_hashes);
        std::string error = st.errc ? st.errc.message() : std::string();
        tc_torrent_status out{};
        out.id = id.c_str();
        out.name = st.name.c_str();
        out.save_path = st.save_path.c_str();
        out.error = error.c_str();
        out.state = map_state(st);
        out.progress = st.progress;
        out.total_wanted = st.total_wanted;
        out.total_wanted_done = st.total_wanted_done;
        out.total_uploaded = st.all_time_upload;
        out.total_downloaded = st.all_time_download;
        out.download_rate = st.download_payload_rate;
        out.upload_rate = st.upload_payload_rate;
        out.num_peers = st.num_peers;
        out.num_seeds = st.num_seeds;
        out.has_metadata = st.has_metadata ? 1 : 0;
        out.sequential = (st.flags & lt::torrent_flags::sequential_download) ? 1 : 0;
        out.added_time = static_cast<long long>(st.added_time);
        out.seeding_seconds = st.seeding_duration.count();
        status_cb(ctx, &out);
    }
}

void tc_list_files(tc_session *s, const char *id, void *ctx, tc_file_cb cb) {
    auto h = find(s, id);
    if (!h.is_valid()) return;
    auto ti = h.torrent_file();
    if (!ti) return;
    auto const &fstore = ti->layout();
    std::vector<std::int64_t> progress;
    h.file_progress(progress, lt::torrent_handle::piece_granularity);
    auto priorities = h.get_file_priorities();
    for (lt::file_index_t i : fstore.file_range()) {
        if (fstore.pad_file_at(i)) continue;
        int idx = static_cast<int>(i);
        std::string path = fstore.file_path(i);
        tc_file_info info{};
        info.index = idx;
        info.path = path.c_str();
        info.size = fstore.file_size(i);
        info.downloaded = idx < int(progress.size()) ? progress[idx] : 0;
        info.priority = idx < int(priorities.size()) ? static_cast<int>(static_cast<std::uint8_t>(priorities[idx])) : 4;
        cb(ctx, &info);
    }
}

void tc_set_file_priority(tc_session *s, const char *id, int file_index, int priority) {
    auto h = find(s, id);
    if (!h.is_valid()) return;
    h.file_priority(lt::file_index_t{file_index}, lt::download_priority_t{static_cast<std::uint8_t>(priority)});
    h.save_resume_data(lt::torrent_handle::save_info_dict);
}

void tc_set_rate_limits(tc_session *s, int download_limit, int upload_limit) {
    lt::settings_pack pack;
    pack.set_int(lt::settings_pack::download_rate_limit, download_limit);
    pack.set_int(lt::settings_pack::upload_rate_limit, upload_limit);
    s->ses->apply_settings(std::move(pack));
}

} // extern "C"
