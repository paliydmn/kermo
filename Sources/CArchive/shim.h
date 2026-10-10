// Minimal declarations for the system libarchive (/usr/lib/libarchive.2.dylib).
// The macOS SDK ships the library but not its headers; these read-side calls have had a
// stable ABI since libarchive 3.0.
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF   1
#define ARCHIVE_OK    0
#define ARCHIVE_WARN  (-20)
#define ARCHIVE_FATAL (-30)

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_empty(struct archive *);
int archive_read_set_options(struct archive *, const char *options);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
const char *archive_filter_name(struct archive *, int);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
