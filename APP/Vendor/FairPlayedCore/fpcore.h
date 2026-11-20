#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define FP_MAX_SLICES 8

typedef void (*fp_log_t)(void *ctx, const char *msg);

enum {
    FP_MODE_R_CID2  = 1,
    FP_MODE_RX_CID1 = 2,
    FP_MODE_R_CID1  = 3,
};

typedef struct {
    uint64_t slice_off, slice_size;
    uint32_t cputype, cpusubtype;
    uint32_t filetype;
    uint64_t enc_lc_off;
    uint32_t cryptoff, cryptsize, cryptid;
    uint32_t cs_off, cs_size;
    bool     has_enc;
} fp_slice_t;

typedef struct {
    int      mode;
    bool     addsigs;
    int      sig_errno;
    int      mmap_errno;
    int      mremap_ret, mremap_errno;
    uint64_t pages_total, pages_ok;
    int      first_fail_kr;
    uint64_t first_fail_off;
    bool     changed;
    uint32_t ret_before, ret_after;
    double   ent_before, ent_after;
    double   ms;
} fp_attempt_t;

const char *fp_mode_name(int mode);
int  fp_parse(const char *path, fp_slice_t *slices, int max, int *count, char *err, size_t errlen);
int  fp_attempt(const char *path, const fp_slice_t *s, int mode, bool addsigs, uint8_t *out, fp_attempt_t *res);
void fp_attempt_describe(const fp_attempt_t *a, char *buf, size_t len);
int  fp_probe_file(const char *path, const int *modes, int nmodes, fp_log_t log, void *ctx);
int  fp_decrypt_file(const char *in_path, const char *out_path, fp_log_t log,
                     bool (*should_cancel)(void *), void *ctx);
bool fp_is_macho(const char *path);
