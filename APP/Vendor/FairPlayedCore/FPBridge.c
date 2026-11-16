#include "FPBridge.h"
#include "fpcore.h"
#include "zipio.h"

#include <errno.h>
#include <fts.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void fp_quiet_log(void *ctx, const char *msg) {
    (void)ctx;
    (void)msg;
}

int fp_zip_unpack(const char *ipaPath, const char *destDir, char *err, int errlen) {
    if (!ipaPath || !destDir) {
        if (err && errlen > 0) snprintf(err, (size_t)errlen, "missing argument");
        return -1;
    }
    return zip_extract_all(ipaPath, destDir, err, errlen);
}

int fp_zip_pack(const char *srcDir, const char *outPath, char *err, int errlen) {
    if (!srcDir || !outPath) {
        if (err && errlen > 0) snprintf(err, (size_t)errlen, "missing argument");
        return -1;
    }
    return zip_create_from_dir(srcDir, outPath, err, errlen);
}

int fp_probe_one(const char *path) {
    if (!path) return -1;
    int modes[] = { FP_MODE_R_CID2 };
    return fp_probe_file(path, modes, 1, fp_quiet_log, NULL);
}

typedef struct {
    fp_progress_cb entry_cb;
    fp_line_cb line_cb;
    fp_cancel_cb cancel_cb;
    void *user;
} fp_tree_ctx_t;

static void tree_log(void *ctx, const char *msg) {
    fp_tree_ctx_t *c = (fp_tree_ctx_t *)ctx;
    if (c && c->line_cb && msg) c->line_cb(c->user, msg);
}

int fp_decrypt_tree(const char *appDir,
                    fp_progress_cb cb,
                    fp_line_cb line,
                    fp_cancel_cb shouldCancel,
                    void *ctx,
                    int *failed,
                    int *skipped,
                    char *err,
                    int errlen) {
    if (failed) *failed = 0;
    if (skipped) *skipped = 0;
    if (!appDir) {
        if (err && errlen > 0) snprintf(err, (size_t)errlen, "missing app dir");
        return -1;
    }

    fp_tree_ctx_t tree = { cb, line, shouldCancel, ctx };

    char *paths[2] = { (char *)appDir, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) {
        if (err && errlen > 0) snprintf(err, (size_t)errlen, "fts_open: %s", strerror(errno));
        return -1;
    }

    size_t baseLen = strlen(appDir);
    int done = 0, fail = 0, skip = 0;
    FTSENT *entry;

    while ((entry = fts_read(fts)) != NULL) {
        if (shouldCancel && shouldCancel(ctx)) { done = -2; break; }
        if (entry->fts_info != FTS_F) continue;
        if (!fp_is_macho(entry->fts_path)) continue;

        const char *rel = entry->fts_path + baseLen;
        while (*rel == '/') rel++;

        if (line) line(ctx, rel);

        char tmp[PATH_MAX];
        int n = snprintf(tmp, sizeof tmp, "%s.fpdec", entry->fts_path);
        if (n <= 0 || (size_t)n >= sizeof tmp) {
            fail++;
            if (cb) cb(ctx, rel, -1);
            continue;
        }

        int r = fp_decrypt_file(entry->fts_path, tmp, tree_log, &tree);
        if (r == 0) {
            if (rename(tmp, entry->fts_path) == 0) done++;
            else { unlink(tmp); fail++; if (cb) cb(ctx, rel, -1); continue; }
            if (cb) cb(ctx, rel, 0);
        } else {
            unlink(tmp);
            if (r == 1) { skip++; if (cb) cb(ctx, rel, 1); }
            else { fail++; if (cb) cb(ctx, rel, -1); }
        }
    }

    fts_close(fts);
    if (failed) *failed = fail;
    if (skipped) *skipped = skip;
    if (done == -2) return -2;
    return done;
}
