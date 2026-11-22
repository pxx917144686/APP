#include "fpcore.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <libkern/OSByteOrder.h>
#include <mach/mach.h>
#include <mach/machine.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <TargetConditionals.h>

#pragma mark - mremap_encrypted

typedef int (*mremap_encrypted_fn)(void *, size_t, uint32_t, uint32_t, uint32_t);

static int raw_mremap_encrypted(void *addr, size_t len, uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype) {
#if defined(__arm64__) && TARGET_OS_IPHONE
    register uint64_t x0 __asm__("x0") = (uint64_t)addr;
    register uint64_t x1 __asm__("x1") = (uint64_t)len;
    register uint64_t x2 __asm__("x2") = cryptid;
    register uint64_t x3 __asm__("x3") = cputype;
    register uint64_t x4 __asm__("x4") = cpusubtype;
    register uint64_t x16 __asm__("x16") = 489;
    uint64_t failed;
    __asm__ volatile("svc #0x80\n\tcset %[f], cs\n"
                     : "+r"(x0), "+r"(x1), [f] "=r"(failed)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    if (failed) { errno = (int)x0; return -1; }
    return (int)x0;
#else
    errno = ENOTSUP;
    return -1;
#endif
}

static int do_mremap_encrypted(void *addr, size_t len, uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype) {
    static mremap_encrypted_fn fn;
    static int resolved;
    if (!resolved) { fn = (mremap_encrypted_fn)dlsym(RTLD_DEFAULT, "mremap_encrypted"); resolved = 1; }
    if (fn) return fn(addr, len, cryptid, cputype, cpusubtype);
    return raw_mremap_encrypted(addr, len, cryptid, cputype, cpusubtype);
}

#pragma mark - helpers

static void logf_(fp_log_t log, void *ctx, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void logf_(fp_log_t log, void *ctx, const char *fmt, ...) {
    char buf[2048];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    if (log) log(ctx, buf); else fprintf(stderr, "%s\n", buf);
}

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static double entropy(const uint8_t *p, size_t n) {
    if (!n) return 0;
    uint64_t h[256] = {0};
    for (size_t i = 0; i < n; i++) h[p[i]]++;
    double e = 0;
    for (int i = 0; i < 256; i++) if (h[i]) { double q = (double)h[i] / n; e -= q * log2(q); }
    return e;
}

static double entropy_from(const uint64_t *h, size_t n) {
    if (!n) return 0;
    double e = 0;
    for (int i = 0; i < 256; i++) if (h[i]) { double q = (double)h[i] / n; e -= q * log2(q); }
    return e;
}

static uint32_t code_words(const uint8_t *p, size_t n) {
    uint32_t c = 0;
    for (size_t i = 0; i + 4 <= n; i += 4) {
        uint32_t w; memcpy(&w, p + i, 4);
        if (w == 0xd65f03c0 || w == 0xd503237f || w == 0xd65f0fff) c++;
    }
    return c;
}

static void analyze_pair(const uint8_t *orig, const uint8_t *dec, size_t n,
                         uint32_t *ret_orig, uint32_t *ret_dec,
                         double *ent_orig, double *ent_dec, bool *changed) {
    uint64_t ha[256] = {0};
    uint64_t hb[256] = {0};
    uint32_t wa = 0, wb = 0;
    bool diff = false;
    size_t i = 0;
    for (; i + 4 <= n; i += 4) {
        uint32_t x, y;
        memcpy(&x, orig + i, 4);
        memcpy(&y, dec + i, 4);
        if (x != y) diff = true;
        if (x == 0xd65f03c0 || x == 0xd503237f || x == 0xd65f0fff) wa++;
        if (y == 0xd65f03c0 || y == 0xd503237f || y == 0xd65f0fff) wb++;
        ha[orig[i]]++; ha[orig[i + 1]]++; ha[orig[i + 2]]++; ha[orig[i + 3]]++;
        hb[dec[i]]++; hb[dec[i + 1]]++; hb[dec[i + 2]]++; hb[dec[i + 3]]++;
    }
    for (; i < n; i++) {
        if (orig[i] != dec[i]) diff = true;
        ha[orig[i]]++;
        hb[dec[i]]++;
    }
    *ret_orig = wa; *ret_dec = wb;
    *ent_orig = entropy_from(ha, n); *ent_dec = entropy_from(hb, n);
    *changed = diff;
}

static bool pread_full(int fd, void *buf, size_t n, off_t off) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = pread(fd, p, n, off);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        p += r; n -= r; off += r;
    }
    return true;
}

static bool pwrite_full(int fd, const void *buf, size_t n, off_t off) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t r = pwrite(fd, p, n, off);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        p += r; n -= r; off += r;
    }
    return true;
}

const char *fp_mode_name(int mode) {
    switch (mode) {
        case FP_MODE_R_CID2:  return "R/cryptid2";
        case FP_MODE_RX_CID1: return "RX/cryptid1";
        case FP_MODE_R_CID1:  return "R/cryptid1";
    }
    return "?";
}

bool fp_is_macho(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    uint32_t m = 0;
    bool ok = pread(fd, &m, 4, 0) == 4;
    close(fd);
    if (!ok) return false;
    return m == MH_MAGIC_64 || m == MH_MAGIC || m == FAT_CIGAM || m == FAT_CIGAM_64;
}

#pragma mark - parsing

static int parse_thin(int fd, uint64_t off, uint64_t size, fp_slice_t *s, char *err, size_t errlen) {
    struct mach_header_64 mh;
    if (!pread_full(fd, &mh, sizeof mh, off)) { snprintf(err, errlen, "short read (header)"); return -1; }
    if (mh.magic != MH_MAGIC_64) { snprintf(err, errlen, "unsupported magic 0x%x", mh.magic); return -1; }
    memset(s, 0, sizeof *s);
    s->slice_off = off; s->slice_size = size;
    s->cputype = mh.cputype; s->cpusubtype = mh.cpusubtype; s->filetype = mh.filetype;
    if (mh.sizeofcmds > 16 * 1024 * 1024) { snprintf(err, errlen, "sizeofcmds too large"); return -1; }
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds || !pread_full(fd, cmds, mh.sizeofcmds, off + sizeof mh)) { free(cmds); snprintf(err, errlen, "short read (cmds)"); return -1; }
    uint32_t pos = 0;
    for (uint32_t i = 0; i < mh.ncmds && pos + 8 <= mh.sizeofcmds; i++) {
        struct load_command *lc = (struct load_command *)(cmds + pos);
        if (lc->cmdsize < 8 || pos + lc->cmdsize > mh.sizeofcmds) break;
        if (lc->cmd == LC_ENCRYPTION_INFO_64 || lc->cmd == LC_ENCRYPTION_INFO) {
            struct encryption_info_command *e = (void *)lc;
            s->has_enc = true;
            s->enc_lc_off = off + sizeof mh + pos;
            s->cryptoff = e->cryptoff; s->cryptsize = e->cryptsize; s->cryptid = e->cryptid;
        } else if (lc->cmd == LC_CODE_SIGNATURE) {
            struct linkedit_data_command *l = (void *)lc;
            s->cs_off = l->dataoff; s->cs_size = l->datasize;
        }
        pos += lc->cmdsize;
    }
    free(cmds);

    if (s->has_enc && s->cryptsize) {
        if ((uint64_t)s->cryptoff + s->cryptsize > s->slice_size) {
            snprintf(err, errlen, "crypt range 0x%x+0x%x exceeds slice 0x%llx",
                     s->cryptoff, s->cryptsize, (unsigned long long)s->slice_size);
            return -1;
        }
    }
    return 0;
}

int fp_parse(const char *path, fp_slice_t *slices, int max, int *count, char *err, size_t errlen) {
    *count = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { snprintf(err, errlen, "open: %s", strerror(errno)); return -1; }
    struct stat st; fstat(fd, &st);
    uint32_t magic = 0;
    if (!pread_full(fd, &magic, 4, 0)) { close(fd); snprintf(err, errlen, "short read"); return -1; }
    int rc = 0;
    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        bool is64 = magic == FAT_CIGAM_64;
        struct fat_header fh;
        if (!pread_full(fd, &fh, sizeof fh, 0)) { close(fd); snprintf(err, errlen, "short read"); return -1; }
        uint32_t n = OSSwapBigToHostInt32(fh.nfat_arch);
        uint64_t p = sizeof fh;
        for (uint32_t i = 0; i < n && *count < max; i++) {
            uint64_t o, sz; uint32_t ct;
            if (is64) {
                struct fat_arch_64 fa; if (!pread_full(fd, &fa, sizeof fa, p)) break; p += sizeof fa;
                o = OSSwapBigToHostInt64(fa.offset); sz = OSSwapBigToHostInt64(fa.size); ct = OSSwapBigToHostInt32(fa.cputype);
            } else {
                struct fat_arch fa; if (!pread_full(fd, &fa, sizeof fa, p)) break; p += sizeof fa;
                o = OSSwapBigToHostInt32(fa.offset); sz = OSSwapBigToHostInt32(fa.size); ct = OSSwapBigToHostInt32(fa.cputype);
            }
            if (ct != CPU_TYPE_ARM64) continue;
            if (o + sz > (uint64_t)st.st_size) {
                snprintf(err, errlen, "slice %u exceeds file", i);
                rc = -1;
                break;
            }
            char e2[128];
            if (parse_thin(fd, o, sz, &slices[*count], e2, sizeof e2) == 0) {
                (*count)++;
            } else {
                snprintf(err, errlen, "slice %u: %s", i, e2);
                rc = -1;
                break;
            }
        }
    } else if (magic == MH_MAGIC_64) {
        fp_slice_t parsed;
        rc = parse_thin(fd, 0, (uint64_t)st.st_size, &parsed, err, errlen);
        if (rc == 0) {
            if (parsed.cputype == CPU_TYPE_ARM64) {
                slices[0] = parsed;
                *count = 1;
            } else {
                rc = 0;
            }
        }
    } else if (magic == MH_MAGIC) {
        rc = 0;
    } else {
        snprintf(err, errlen, "not a 64-bit Mach-O (magic 0x%08x)", magic);
        rc = -1;
    }
    close(fd);
    return rc;
}

#pragma mark - attempt

int fp_attempt(const char *path, const fp_slice_t *s, int mode, bool addsigs, uint8_t *out, fp_attempt_t *res) {
    memset(res, 0, sizeof *res);
    res->mode = mode; res->addsigs = addsigs; res->mremap_ret = -1;
    double t0 = now_ms();
    const uint64_t pg = (uint64_t)getpagesize();
    if (!s->has_enc || s->cryptsize == 0) return -1;
    if ((uint64_t)s->cryptoff + s->cryptsize > s->slice_size) { res->mmap_errno = EINVAL; return -1; }
    if (s->slice_off % pg) { res->mmap_errno = EINVAL; return -1; }
    if (s->cryptoff % pg) { res->mremap_errno = EINVAL; return -1; }

    int fd = open(path, O_RDONLY);
    if (fd < 0) { res->mmap_errno = errno; return -1; }

    if (addsigs && s->cs_size) {
        size_t sig_len = (size_t)s->cs_size;
        void *sig = mmap(NULL, sig_len, PROT_READ, MAP_PRIVATE, fd, (off_t)(s->slice_off + s->cs_off));
        if (sig != MAP_FAILED) {
            fsignatures_t fs = { .fs_file_start = (off_t)s->slice_off, .fs_blob_start = sig, .fs_blob_size = s->cs_size };
            if (fcntl(fd, F_ADDFILESIGS_RETURN, &fs) == -1) res->sig_errno = errno;
            munmap(sig, sig_len);
        } else {
            res->sig_errno = errno;
        }
    }

    uint64_t map_len = ((uint64_t)s->cryptoff + s->cryptsize + pg - 1) & ~(pg - 1);
    int prot = PROT_READ | (mode == FP_MODE_RX_CID1 ? PROT_EXEC : 0);
    uint8_t *base = mmap(NULL, map_len, prot, MAP_PRIVATE, fd, (off_t)s->slice_off);
    if (base == MAP_FAILED) { res->mmap_errno = errno; close(fd); res->ms = now_ms() - t0; return -1; }

    uint8_t *orig = mmap(NULL, s->cryptsize, PROT_READ, MAP_PRIVATE, fd, (off_t)(s->slice_off + s->cryptoff));
    uint8_t *dec = out;
    bool dec_owned = false;
    if (orig == MAP_FAILED) {
        munmap(base, map_len); close(fd); res->mmap_errno = EIO; return -1;
    }
    if (!dec) {
        dec = malloc(s->cryptsize);
        dec_owned = true;
    }
    if (!dec) {
        munmap(orig, s->cryptsize); munmap(base, map_len); close(fd); res->mmap_errno = EIO; return -1;
    }

    uint32_t cid = (mode == FP_MODE_R_CID2) ? 2 : 1;
    errno = 0;
    res->mremap_ret = do_mremap_encrypted(base + s->cryptoff, s->cryptsize, cid, s->cputype, s->cpusubtype);
    res->mremap_errno = res->mremap_ret == 0 ? 0 : errno;

    if (res->mremap_ret == 0) {
        uint64_t total = (s->cryptsize + pg - 1) / pg;
        res->pages_total = total;
        for (uint64_t i = 0; i < total; i++) {
            uint64_t off = i * pg;
            uint64_t n = (off + pg <= s->cryptsize) ? pg : (s->cryptsize - off);
            vm_size_t got = 0;
            kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)(base + s->cryptoff + off), (vm_size_t)n,
                                                 (vm_address_t)(dec + off), &got);
            if (kr == KERN_SUCCESS && got == n) {
                res->pages_ok++;
            } else {
                if (!res->first_fail_kr) { res->first_fail_kr = kr ? kr : -1; res->first_fail_off = s->cryptoff + off; }
                memset(dec + off, 0, n);
            }
        }
        res->changed = false;
        analyze_pair(orig, dec, s->cryptsize,
                     &res->ret_before, &res->ret_after,
                     &res->ent_before, &res->ent_after, &res->changed);
    } else {
        res->ret_before = code_words(orig, s->cryptsize);
        res->ent_before = entropy(orig, s->cryptsize);
    }

    munmap(orig, s->cryptsize);
    if (dec_owned) free(dec);
    munmap(base, map_len);
    close(fd);
    res->ms = now_ms() - t0;
    return (res->mremap_ret == 0 && res->pages_ok == res->pages_total && res->changed) ? 0 : -1;
}

void fp_attempt_describe(const fp_attempt_t *a, char *buf, size_t len) {
    snprintf(buf, len,
             "%s%s: sig=%s mmap=%s mremap=%d(errno %d %s) pages=%llu/%llu firstfail=kr%d@0x%llx changed=%d "
             "code-words %u->%u entropy %.3f->%.3f (%.0f ms)",
             fp_mode_name(a->mode), a->addsigs ? "+sigs" : "",
             a->addsigs ? (a->sig_errno ? strerror(a->sig_errno) : "ok") : "-",
             a->mmap_errno ? strerror(a->mmap_errno) : "ok",
             a->mremap_ret, a->mremap_errno, a->mremap_errno ? strerror(a->mremap_errno) : "ok",
             (unsigned long long)a->pages_ok, (unsigned long long)a->pages_total,
             a->first_fail_kr, (unsigned long long)a->first_fail_off, a->changed,
             a->ret_before, a->ret_after, a->ent_before, a->ent_after, a->ms);
}

static bool attempt_looks_decrypted(const fp_attempt_t *a) {
    if (a->mremap_ret != 0 || a->pages_ok != a->pages_total || !a->changed) return false;
    if (a->ent_after <= 0.001) return false;
    if (a->ent_after < 7.5 && a->ret_after > a->ret_before) return true;
    return a->ent_before > 7.9 && a->ent_after < a->ent_before - 0.25;
}

int fp_probe_file(const char *path, const int *modes, int nmodes, fp_log_t log, void *ctx) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) { logf_(log, ctx, "  parse failed: %s", err); return -1; }
    int successes = 0;
    for (int i = 0; i < n; i++) {
        const fp_slice_t *s = &sl[i];
        logf_(log, ctx, "  slice[%d] cpu=0x%x/0x%x type=%u off=0x%llx enc=%d cryptoff=0x%x cryptsize=0x%x cryptid=%u cs=0x%x+0x%x",
              i, s->cputype, s->cpusubtype, s->filetype, (unsigned long long)s->slice_off, s->has_enc,
              s->cryptoff, s->cryptsize, s->cryptid, s->cs_off, s->cs_size);
        if (!s->has_enc || s->cryptid == 0) continue;
        for (int m = 0; m < nmodes; m++) {
            for (int sig = 0; sig < 2; sig++) {
                fp_attempt_t a; char d[512];
                fp_attempt(path, s, modes[m], sig, NULL, &a);
                fp_attempt_describe(&a, d, sizeof d);
                bool ok = attempt_looks_decrypted(&a);
                if (ok) successes++;
                logf_(log, ctx, "    %s %s", ok ? "[DECRYPTED]" : "[--]", d);
            }
        }
    }
    return successes;
}

#pragma mark - decrypt to file

static int copy_file(const char *src, const char *dst) {
    if (access(dst, F_OK) != 0 && clonefile(src, dst, 0) == 0) return 0;

    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    struct stat st; fstat(in, &st);
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, (st.st_mode & 0777) | 0600);
    if (out < 0) { close(in); return -1; }
    uint8_t *buf = malloc(1 << 20);
    if (!buf) { close(in); close(out); return -1; }
    ssize_t r; int rc = 0;
    while ((r = read(in, buf, 1 << 20)) > 0) if (write(out, buf, (size_t)r) != r) { rc = -1; break; }
    if (r < 0) rc = -1;
    free(buf); close(in); close(out);
    return rc;
}

int fp_decrypt_file(const char *in_path, const char *out_path, fp_log_t log,
                    bool (*should_cancel)(void *), void *ctx) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(in_path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) { logf_(log, ctx, "  parse failed: %s", err); return -1; }
    bool any = false;
    for (int i = 0; i < n; i++) if (sl[i].has_enc && sl[i].cryptid) any = true;
    if (!any) return 1;
    if (strcmp(in_path, out_path) != 0 && copy_file(in_path, out_path) != 0) { logf_(log, ctx, "  copy failed: %s", strerror(errno)); return -1; }

    int out = open(out_path, O_RDWR);
    if (out < 0) { logf_(log, ctx, "  open out: %s", strerror(errno)); return -1; }
    const int order[][2] = {
        {FP_MODE_R_CID2, 0}, {FP_MODE_R_CID2, 1},
        {FP_MODE_RX_CID1, 0}, {FP_MODE_RX_CID1, 1},
        {FP_MODE_R_CID1, 0}, {FP_MODE_R_CID1, 1},
    };
    int rc = 0;
    bool in_place = strcmp(in_path, out_path) == 0;
    for (int i = 0; i < n && rc == 0; i++) {
        const fp_slice_t *s = &sl[i];
        if (!s->has_enc || s->cryptid == 0) continue;

        logf_(log, ctx, "  slice[%d] cpu=0x%x/0x%x cryptoff=0x%x cryptsize=0x%x cryptid=%u cs=0x%x+0x%x",
              i, s->cputype, s->cpusubtype, s->cryptoff, s->cryptsize, s->cryptid, s->cs_off, s->cs_size);

        uint8_t *dec = NULL;
        bool dec_mapped = false;
        struct stat ost;
        bool out_big_enough = fstat(out, &ost) == 0 &&
            (uint64_t)ost.st_size >= (uint64_t)s->slice_off + s->cryptoff + s->cryptsize;
        if (!in_place && out_big_enough) {
            uint8_t *mapped = mmap(NULL, s->cryptsize, PROT_READ | PROT_WRITE, MAP_SHARED,
                                   out, (off_t)(s->slice_off + s->cryptoff));
            if (mapped != MAP_FAILED) { dec = mapped; dec_mapped = true; }
        }
        if (!dec) {
            dec = malloc(s->cryptsize);
            if (!dec) {
                logf_(log, ctx, "  out of memory for slice %d (%u bytes)", i, s->cryptsize);
                rc = -1;
                break;
            }
        }

        bool done = false;
        bool cancelled = false;
        for (size_t k = 0; k < sizeof order / sizeof order[0] && !done; k++) {
            if (should_cancel && should_cancel(ctx)) { cancelled = true; break; }
            fp_attempt_t a; char d[512];
            fp_attempt(in_path, s, order[k][0], order[k][1], dec, &a);
            fp_attempt_describe(&a, d, sizeof d);
            done = attempt_looks_decrypted(&a);
            logf_(log, ctx, "  slice[%d] %s %s", i, done ? "[DECRYPTED]" : "[--]", d);
        }
        if (cancelled) {
            if (dec_mapped) munmap(dec, s->cryptsize); else free(dec);
            rc = -2;
            break;
        }
        if (!done) {
            if (dec_mapped) munmap(dec, s->cryptsize); else free(dec);
            rc = -1;
            break;
        }
        uint32_t zero = 0;
        bool body_written = dec_mapped ||
            pwrite_full(out, dec, s->cryptsize, (off_t)(s->slice_off + s->cryptoff));
        if (!body_written ||
            !pwrite_full(out, &zero, 4, (off_t)(s->enc_lc_off + offsetof(struct encryption_info_command, cryptid)))) {
            logf_(log, ctx, "  write failed: %s", strerror(errno)); rc = -1;
        }
        if (dec_mapped) {
            if (rc == 0 && msync(dec, s->cryptsize, MS_SYNC) != 0) {
                logf_(log, ctx, "  msync failed: %s", strerror(errno));
                rc = -1;
            }
            munmap(dec, s->cryptsize);
        } else free(dec);
    }
    if (rc == 0 && fsync(out) != 0) { logf_(log, ctx, "  sync failed: %s", strerror(errno)); rc = -1; }
    close(out);
    return rc;
}
