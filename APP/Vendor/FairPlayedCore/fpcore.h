// FairPlayed — FairPlay decryption research tool.
// Core: Mach-O parsing + mremap_encrypted experiments.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define FP_MAX_SLICES 8

typedef void (*fp_log_t)(void *ctx, const char *msg);

enum {
    FP_MODE_R_CID2  = 1,  // PROT_READ mapping, cryptid=2 (CRYPTID_MODEL_ENCRYPTION: VM layer skips the PROT_EXEC requirement)
    FP_MODE_RX_CID1 = 2,  // PROT_READ|PROT_EXEC mapping, cryptid=1 (what dyld does)
    FP_MODE_R_CID1  = 3,  // PROT_READ mapping, cryptid=1 (control: VM layer should reject)
};

typedef struct {
    uint64_t slice_off, slice_size;
    uint32_t cputype, cpusubtype;
    uint32_t filetype;
    uint64_t enc_lc_off;          // absolute file offset of LC_ENCRYPTION_INFO(_64)
    uint32_t cryptoff, cryptsize, cryptid;
    uint32_t cs_off, cs_size;     // LC_CODE_SIGNATURE (slice-relative)
    bool     has_enc;
} fp_slice_t;

typedef struct {
    int      mode;
    bool     addsigs;
    int      sig_errno;           // 0 = F_ADDFILESIGS_RETURN ok (or not requested)
    int      mmap_errno;
    int      mremap_ret, mremap_errno;
    uint64_t pages_total, pages_ok;
    int      first_fail_kr;
    uint64_t first_fail_off;
    bool     changed;             // decrypted bytes differ from on-disk bytes
    uint32_t ret_before, ret_after;   // count of arm64 RET/PACIBSP words (code heuristic)
    double   ent_before, ent_after;   // Shannon entropy, bits/byte
    double   ms;
} fp_attempt_t;

const char *fp_mode_name(int mode);
int  fp_parse(const char *path, fp_slice_t *slices, int max, int *count, char *err, size_t errlen);
// Runs one attempt. If out != NULL (size >= s->cryptsize) receives the bytes read from the remapped range.
int  fp_attempt(const char *path, const fp_slice_t *s, int mode, bool addsigs, uint8_t *out, fp_attempt_t *res);
void fp_attempt_describe(const fp_attempt_t *a, char *buf, size_t len);
// Probe all modes on every encrypted slice of a file (no output written).
int  fp_probe_file(const char *path, const int *modes, int nmodes, fp_log_t log, void *ctx);
// Decrypt in_path -> out_path. Returns 0 on success, 1 if file was not encrypted (copied as-is), -1 on failure.
int  fp_decrypt_file(const char *in_path, const char *out_path, fp_log_t log, void *ctx);
bool fp_is_macho(const char *path);
