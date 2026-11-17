#pragma once
#include <stddef.h>

int zip_extract_all(const char *zip_path, const char *dest_dir, char *err, size_t errlen);
int zip_create_from_dir(const char *src_dir, const char *zip_path, char *err, size_t errlen);
