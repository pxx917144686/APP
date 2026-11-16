// Minimal ZIP reader/writer (deflate via zlib, ZIP64 offsets) for IPA handling.
#pragma once
#include <stddef.h>

// Extracts every entry of zip_path below dest_dir. Rejects absolute paths and "..".
int zip_extract_all(const char *zip_path, const char *dest_dir, char *err, size_t errlen);
// Creates zip_path from the contents of src_dir (paths stored relative to src_dir).
int zip_create_from_dir(const char *src_dir, const char *zip_path, char *err, size_t errlen);
