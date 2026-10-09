#ifndef TORRENT_CORE_H
#define TORRENT_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tc_session tc_session;

typedef enum {
    TC_STATE_CHECKING = 0,
    TC_STATE_METADATA,
    TC_STATE_DOWNLOADING,
    TC_STATE_FINISHED,
    TC_STATE_SEEDING,
    TC_STATE_PAUSED,
    TC_STATE_ERROR,
    TC_STATE_QUEUED,
} tc_state;

// Strings are only valid for the duration of the callback.
typedef struct {
    const char *id;
    const char *name;
    const char *save_path;
    const char *error;
    tc_state state;
    double progress;
    long long total_wanted;
    long long total_wanted_done;
    long long total_uploaded;
    long long total_downloaded;
    int download_rate;
    int upload_rate;
    int num_peers;
    int num_seeds;
    int has_metadata;
    int sequential;
    long long added_time;
    long long seeding_seconds;
} tc_torrent_status;

typedef struct {
    int index;
    const char *path;
    long long size;
    long long downloaded;
    int priority; // 0 = skip, 1..7
} tc_file_info;

typedef enum {
    TC_EVENT_FINISHED = 0,
    TC_EVENT_ERROR,
    TC_EVENT_METADATA,
} tc_event_kind;

typedef void (*tc_status_cb)(void *ctx, const tc_torrent_status *status);
typedef void (*tc_file_cb)(void *ctx, const tc_file_info *file);
typedef void (*tc_event_cb)(void *ctx, tc_event_kind kind, const char *id, const char *message);

// state_dir holds session state and per-torrent resume data.
tc_session *tc_session_create(const char *state_dir);
// Saves resume data for all torrents (bounded wait) and shuts the session down.
void tc_session_destroy(tc_session *s);

// Return 0 on success; on failure write a message into err.
int tc_add_torrent_file(tc_session *s, const char *path, const char *save_path, char *err, int err_len);
int tc_add_magnet(tc_session *s, const char *uri, const char *save_path, char *err, int err_len);

void tc_pause(tc_session *s, const char *id);
void tc_resume(tc_session *s, const char *id);
void tc_remove(tc_session *s, const char *id, int delete_files);
void tc_force_recheck(tc_session *s, const char *id);
// Download pieces in order (useful for watching a video while it downloads).
void tc_set_sequential(tc_session *s, const char *id, int enabled);

// Drains alerts (emitting events) and reports the status of every torrent.
void tc_poll(tc_session *s, void *ctx, tc_status_cb status_cb, tc_event_cb event_cb);

void tc_list_files(tc_session *s, const char *id, void *ctx, tc_file_cb cb);
void tc_set_file_priority(tc_session *s, const char *id, int file_index, int priority);

// Bytes per second; 0 = unlimited.
void tc_set_rate_limits(tc_session *s, int download_limit, int upload_limit);

#ifdef __cplusplus
}
#endif

#endif
