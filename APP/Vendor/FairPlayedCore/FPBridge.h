#ifndef FPBridge_h
#define FPBridge_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*fp_progress_cb)(void *ctx, const char *relativePath, int status, int64_t size);

typedef void (*fp_line_cb)(void *ctx, const char *line);

typedef bool (*fp_cancel_cb)(void *ctx);

int fp_zip_unpack(const char *ipaPath, const char *destDir, char *err, int errlen);

int fp_zip_pack(const char *srcDir, const char *outPath, char *err, int errlen);

int fp_count_targets(const char *appDir, int64_t *bytes);

/// 1 = 能创建可执行内存（签名带 dynamic-codesigning），0 = 不能
int fp_exec_memory_available(void);

int fp_decrypt_tree(const char *appDir,
                    fp_progress_cb cb,
                    fp_line_cb line,
                    fp_cancel_cb shouldCancel,
                    void *ctx,
                    int *failed,
                    int *skipped,
                    char *err,
                    int errlen);

int fp_probe_one(const char *path);

#ifdef __cplusplus
}
#endif

#endif
