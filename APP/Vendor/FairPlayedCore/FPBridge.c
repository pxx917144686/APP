#include "FPBridge.h"

#include <sys/mman.h>
#include <errno.h>
#include "fpcore.h"
#include "zipio.h"

#include <errno.h>
#include <fts.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
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

static bool tree_cancel(void *ctx) {
    fp_tree_ctx_t *c = (fp_tree_ctx_t *)ctx;
    if (c && c->cancel_cb) return c->cancel_cb(c->user);
    return false;
}

static bool skip_subtree(FTS *fts, FTSENT *entry) {
    if (entry->fts_info != FTS_D) return false;
    if (entry->fts_level == 1 && strcmp(entry->fts_name, "Watch") == 0) {
        fts_set(fts, entry, FTS_SKIP);
    }
    return true;
}

int fp_count_targets(const char *appDir, int64_t *bytes) {
    if (bytes) *bytes = 0;
    if (!appDir) return 0;

    char *paths[2] = { (char *)appDir, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) return 0;

    int count = 0;
    int64_t total = 0;
    FTSENT *entry;
    while ((entry = fts_read(fts)) != NULL) {
        if (skip_subtree(fts, entry)) continue;
        if (entry->fts_info != FTS_F) continue;
        if (!fp_is_macho(entry->fts_path)) continue;
        count++;
        if (entry->fts_statp) total += (int64_t)entry->fts_statp->st_size;
    }
    fts_close(fts);
    if (bytes) *bytes = total;
    return count;
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
        if (skip_subtree(fts, entry)) continue;
        if (entry->fts_info != FTS_F) continue;
        if (!fp_is_macho(entry->fts_path)) continue;

        const char *rel = entry->fts_path + baseLen;
        while (*rel == '/') rel++;

        int64_t size = entry->fts_statp ? (int64_t)entry->fts_statp->st_size : 0;

        if (line) line(ctx, rel);

        char tmp[PATH_MAX];
        int n = snprintf(tmp, sizeof tmp, "%s.fpdec", entry->fts_path);
        if (n <= 0 || (size_t)n >= sizeof tmp) {
            fail++;
            if (cb) cb(ctx, rel, -1, size);
            continue;
        }

        int r = fp_decrypt_file(entry->fts_path, tmp, tree_log, tree_cancel, &tree);
        if (r == 0) {
            if (rename(tmp, entry->fts_path) == 0) done++;
            else { unlink(tmp); fail++; if (cb) cb(ctx, rel, -1, size); continue; }
            if (cb) cb(ctx, rel, 0, size);
        } else if (r == -2) {
            unlink(tmp);
            done = -2;
            break;
        } else {
            unlink(tmp);
            if (r == 1) { skip++; if (cb) cb(ctx, rel, 1, size); }
            else { fail++; if (cb) cb(ctx, rel, -1, size); }
        }
    }

    fts_close(fts);
    if (failed) *failed = fail;
    if (skipped) *skipped = skip;
    if (done == -2) return -2;
    return done;
}

// 探针：能申请到可执行匿名内存，说明签名带 dynamic-codesigning / JIT 权限。
// mremap_encrypted 需要的正是同一个权限，缺了它就只会返回 ENOMEM。
int fp_exec_memory_available(void) {
    void *p = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p != MAP_FAILED) { munmap(p, 0x4000); return 1; }
    p = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC,
             MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p != MAP_FAILED) { munmap(p, 0x4000); return 1; }
    return 0;
}
