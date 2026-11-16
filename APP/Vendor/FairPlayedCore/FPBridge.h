#ifndef FPBridge_h
#define FPBridge_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Progress callback. status: 0 = decrypted, 1 = not encrypted, <0 = failed.
typedef void (*fp_progress_cb)(void *ctx, const char *relativePath, int status);

/// Diagnostic line callback (mirrors FairPlayed's console output).
typedef void (*fp_line_cb)(void *ctx, const char *line);

/// Polled between files. Return true to abort the walk.
typedef bool (*fp_cancel_cb)(void *ctx);

/// Extract an IPA into destDir. Returns 0 on success.
int fp_zip_unpack(const char *ipaPath, const char *destDir, char *err, int errlen);

/// Create a zip of srcDir at outPath. Returns 0 on success.
int fp_zip_pack(const char *srcDir, const char *outPath, char *err, int errlen);

/// Decrypt every encrypted Mach-O under appDir in place.
/// Returns the number decrypted; *failed receives the failure count.
/// `line` receives the per-slice diagnostic output when non-NULL.
/// Returns the number decrypted, -1 on error, -2 when cancelled.
int fp_decrypt_tree(const char *appDir,
                    fp_progress_cb cb,
                    fp_line_cb line,
                    fp_cancel_cb shouldCancel,
                    void *ctx,
                    int *failed,
                    int *skipped,
                    char *err,
                    int errlen);

/// Probe one Mach-O: >0 decryptable, 1 = not encrypted, <=0 not decryptable.
int fp_probe_one(const char *path);

#ifdef __cplusplus
}
#endif

#endif
