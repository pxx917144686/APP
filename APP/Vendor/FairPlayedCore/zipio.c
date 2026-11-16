// Minimal ZIP reader/writer (deflate via zlib, ZIP64 offsets) for IPA handling.
#include "zipio.h"

#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#define CHUNK (256 * 1024)

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }

static bool pread_full(int fd, void *buf, size_t n, off_t off) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = pread(fd, p, n, off);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        p += r; n -= (size_t)r; off += r;
    }
    return true;
}

static int mkdirs(const char *path) {
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1; *p = '/'; }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static bool name_is_safe(const char *n) {
    if (!*n || n[0] == '/') return false;
    const char *p = n;
    while (*p) {
        const char *s = strchr(p, '/');
        size_t len = s ? (size_t)(s - p) : strlen(p);
        if (len == 2 && p[0] == '.' && p[1] == '.') return false;
        if (!s) break;
        p = s + 1;
    }
    return true;
}

static bool link_target_is_safe(const char *t) {
    return t[0] != '/' && strstr(t, "..") == NULL;
}

int zip_extract_all(const char *zip_path, const char *dest_dir, char *err, size_t errlen) {
    int fd = open(zip_path, O_RDONLY);
    if (fd < 0) { snprintf(err, errlen, "open zip: %s", strerror(errno)); return -1; }
    struct stat st; fstat(fd, &st);
    uint64_t fsize = (uint64_t)st.st_size;
    size_t tail = fsize < 65557 + 22 ? (size_t)fsize : 65557 + 22;
    uint8_t *tb = malloc(tail);
    if (!pread_full(fd, tb, tail, (off_t)(fsize - tail))) { free(tb); close(fd); snprintf(err, errlen, "read tail"); return -1; }
    long eo = -1;
    for (long i = (long)tail - 22; i >= 0; i--) if (rd32(tb + i) == 0x06054b50) { eo = i; break; }
    if (eo < 0) { free(tb); close(fd); snprintf(err, errlen, "no EOCD (not a zip?)"); return -1; }
    uint64_t entries = rd16(tb + eo + 10), cd_size = rd32(tb + eo + 12), cd_off = rd32(tb + eo + 16);
    uint64_t eocd_abs = fsize - tail + (uint64_t)eo;
    if (eocd_abs >= 20) {
        uint8_t loc[20];
        if (pread_full(fd, loc, 20, (off_t)(eocd_abs - 20)) && rd32(loc) == 0x07064b50) {
            uint8_t z[56];
            if (pread_full(fd, z, 56, (off_t)rd64(loc + 8)) && rd32(z) == 0x06064b50) {
                entries = rd64(z + 32); cd_size = rd64(z + 40); cd_off = rd64(z + 48);
            }
        }
    }
    free(tb);
    if (cd_size > (512ull << 20) || cd_off + cd_size > fsize) { close(fd); snprintf(err, errlen, "bad central directory"); return -1; }
    uint8_t *cd = malloc(cd_size);
    if (!pread_full(fd, cd, cd_size, (off_t)cd_off)) { free(cd); close(fd); snprintf(err, errlen, "read CD"); return -1; }

    uint8_t *in = malloc(CHUNK), *outb = malloc(CHUNK);
    int rc = 0;
    uint64_t p = 0;
    for (uint64_t i = 0; i < entries && rc == 0; i++) {
        if (p + 46 > cd_size || rd32(cd + p) != 0x02014b50) { snprintf(err, errlen, "bad CD entry %llu", i); rc = -1; break; }
        const uint8_t *e = cd + p;
        uint16_t made_by = rd16(e + 4), method = rd16(e + 10);
        uint32_t crc = rd32(e + 16);
        uint64_t csize = rd32(e + 20), usize = rd32(e + 24);
        uint16_t nlen = rd16(e + 28), xlen = rd16(e + 30), clen = rd16(e + 32);
        uint32_t ext = rd32(e + 38);
        uint64_t loff = rd32(e + 42);
        if (p + 46 + nlen + xlen + clen > cd_size) { snprintf(err, errlen, "truncated CD"); rc = -1; break; }
        char name[4096];
        if (nlen >= sizeof name) { snprintf(err, errlen, "name too long"); rc = -1; break; }
        memcpy(name, e + 46, nlen); name[nlen] = 0;
        const uint8_t *x = e + 46 + nlen, *xe = x + xlen;
        while (x + 4 <= xe) {
            uint16_t id = rd16(x), sz = rd16(x + 2);
            if (x + 4 + sz > xe) break;
            if (id == 0x0001) {
                const uint8_t *q = x + 4, *qe = q + sz;
                if (usize == 0xFFFFFFFF && q + 8 <= qe) { usize = rd64(q); q += 8; }
                if (csize == 0xFFFFFFFF && q + 8 <= qe) { csize = rd64(q); q += 8; }
                if (loff == 0xFFFFFFFF && q + 8 <= qe) { loff = rd64(q); q += 8; }
            }
            x += 4 + sz;
        }
        p += 46 + nlen + xlen + clen;

        if (!name_is_safe(name)) { snprintf(err, errlen, "unsafe entry name: %s", name); rc = -1; break; }
        if (strncmp(name, "__MACOSX/", 9) == 0) continue;
        char out[8192];
        snprintf(out, sizeof out, "%s/%s", dest_dir, name);
        size_t ol = strlen(out);
        if (out[ol - 1] == '/') { out[ol - 1] = 0; if (mkdirs(out) != 0) { snprintf(err, errlen, "mkdir %s: %s", out, strerror(errno)); rc = -1; } continue; }
        char parent[8192]; snprintf(parent, sizeof parent, "%s", out);
        char *slash = strrchr(parent, '/'); if (slash) { *slash = 0; mkdirs(parent); }

        uint8_t lh[30];
        if (!pread_full(fd, lh, 30, (off_t)loff) || rd32(lh) != 0x04034b50) { snprintf(err, errlen, "bad local header: %s", name); rc = -1; break; }
        uint64_t data = loff + 30 + rd16(lh + 26) + rd16(lh + 28);
        bool is_unix = (made_by >> 8) == 3;
        mode_t mode = is_unix ? (mode_t)((ext >> 16) & 07777) : 0644;
        bool is_link = is_unix && (((ext >> 16) & S_IFMT) == S_IFLNK);
        if (method != 0 && method != 8) { snprintf(err, errlen, "unsupported method %u: %s", method, name); rc = -1; break; }

        if (is_link) {
            if (usize > 1024 || method != 0) { snprintf(err, errlen, "odd symlink %s", name); rc = -1; break; }
            char tgt[1025] = {0};
            if (!pread_full(fd, tgt, (size_t)usize, (off_t)data)) { rc = -1; break; }
            if (!link_target_is_safe(tgt)) { snprintf(err, errlen, "unsafe symlink %s -> %s", name, tgt); rc = -1; break; }
            unlink(out);
            if (symlink(tgt, out) != 0) { snprintf(err, errlen, "symlink %s: %s", name, strerror(errno)); rc = -1; }
            continue;
        }

        int ofd = open(out, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, (mode & 0777) | 0600);
        if (ofd < 0) { snprintf(err, errlen, "create %s: %s", out, strerror(errno)); rc = -1; break; }
        uLong c = crc32(0, Z_NULL, 0);
        uint64_t remaining = csize, pos = data, written = 0;
        if (method == 0) {
            while (remaining) {
                size_t n = remaining > CHUNK ? CHUNK : (size_t)remaining;
                if (!pread_full(fd, in, n, (off_t)pos)) { rc = -1; break; }
                c = crc32(c, in, (uInt)n);
                if (write(ofd, in, n) != (ssize_t)n) { rc = -1; break; }
                remaining -= n; pos += n; written += n;
            }
        } else {
            z_stream zs; memset(&zs, 0, sizeof zs);
            inflateInit2(&zs, -MAX_WBITS);
            int zr = Z_OK;
            while (zr != Z_STREAM_END && rc == 0) {
                if (zs.avail_in == 0) {
                    if (!remaining) { rc = -1; break; }
                    size_t n = remaining > CHUNK ? CHUNK : (size_t)remaining;
                    if (!pread_full(fd, in, n, (off_t)pos)) { rc = -1; break; }
                    zs.next_in = in; zs.avail_in = (uInt)n; remaining -= n; pos += n;
                }
                zs.next_out = outb; zs.avail_out = CHUNK;
                zr = inflate(&zs, Z_NO_FLUSH);
                if (zr != Z_OK && zr != Z_STREAM_END) { rc = -1; break; }
                size_t have = CHUNK - zs.avail_out;
                c = crc32(c, outb, (uInt)have);
                if (have && write(ofd, outb, have) != (ssize_t)have) { rc = -1; break; }
                written += have;
            }
            inflateEnd(&zs);
        }
        close(ofd);
        if (rc == 0 && (written != usize || c != crc)) { snprintf(err, errlen, "crc/size mismatch: %s", name); rc = -1; }
        else if (rc != 0) snprintf(err, errlen, "extract failed: %s", name);
        chmod(out, (mode & 0777) | 0600);
    }
    free(in); free(outb); free(cd); close(fd);
    return rc;
}

#pragma mark - writer

typedef struct {
    char *name;
    uint32_t crc, ext;
    uint64_t csize, usize, off;
    uint16_t method, dtime, ddate;
} went_t;

static void wr16(FILE *f, uint16_t v) { uint8_t b[2] = { v & 0xff, v >> 8 }; fwrite(b, 1, 2, f); }
static void wr32(FILE *f, uint32_t v) { uint8_t b[4] = { v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24 }; fwrite(b, 1, 4, f); }
static void wr64(FILE *f, uint64_t v) { wr32(f, (uint32_t)v); wr32(f, (uint32_t)(v >> 32)); }

static void dos_time(time_t t, uint16_t *dt, uint16_t *dd) {
    struct tm tm; localtime_r(&t, &tm);
    if (tm.tm_year < 80) { *dt = 0; *dd = (1 << 5) | 1; return; }
    *dt = (uint16_t)((tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2));
    *dd = (uint16_t)(((tm.tm_year - 80) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday);
}

static int fts_cmp(const FTSENT **a, const FTSENT **b) { return strcmp((*a)->fts_name, (*b)->fts_name); }

static void write_local(FILE *f, went_t *w) {
    w->off = (uint64_t)ftello(f);
    size_t nlen = strlen(w->name);
    wr32(f, 0x04034b50); wr16(f, 20); wr16(f, 0x0800); wr16(f, w->method);
    wr16(f, w->dtime); wr16(f, w->ddate);
    wr32(f, w->crc); wr32(f, (uint32_t)w->csize); wr32(f, (uint32_t)w->usize);
    wr16(f, (uint16_t)nlen); wr16(f, 0);
    fwrite(w->name, 1, nlen, f);
}

int zip_create_from_dir(const char *src_dir, const char *zip_path, char *err, size_t errlen) {
    FILE *f = fopen(zip_path, "wb");
    if (!f) { snprintf(err, errlen, "create zip: %s", strerror(errno)); return -1; }
    setvbuf(f, NULL, _IOFBF, 1 << 20);
    size_t cap = 1024, cnt = 0;
    went_t *ents = calloc(cap, sizeof *ents);
    char *const roots[] = { (char *)src_dir, NULL };
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, fts_cmp);
    if (!fts) { fclose(f); free(ents); snprintf(err, errlen, "fts_open: %s", strerror(errno)); return -1; }
    size_t rootlen = strlen(src_dir);
    uint8_t *in = malloc(CHUNK), *outb = malloc(CHUNK);
    int rc = 0;
    FTSENT *e;
    while ((e = fts_read(fts)) && rc == 0) {
        if (e->fts_info == FTS_DP || e->fts_level == 0) continue;
        if (e->fts_info != FTS_D && e->fts_info != FTS_F && e->fts_info != FTS_SL) continue;
        const char *rel = e->fts_path + rootlen + 1;
        if (cnt == cap) { cap *= 2; ents = realloc(ents, cap * sizeof *ents); }
        went_t *w = &ents[cnt]; memset(w, 0, sizeof *w);
        struct stat *st = e->fts_statp;
        dos_time(st->st_mtime, &w->dtime, &w->ddate);
        w->ext = (uint32_t)st->st_mode << 16;
        if (e->fts_info == FTS_D) {
            size_t l = strlen(rel);
            w->name = malloc(l + 2); memcpy(w->name, rel, l); w->name[l] = '/'; w->name[l + 1] = 0;
            w->ext |= 0x10;
            w->crc = 0; w->method = 0;
            write_local(f, w);
            cnt++;
            continue;
        }
        w->name = strdup(rel);
        if (e->fts_info == FTS_SL) {
            char tgt[1024]; ssize_t n = readlink(e->fts_path, tgt, sizeof tgt);
            if (n < 0) { rc = -1; snprintf(err, errlen, "readlink %s", rel); break; }
            w->method = 0; w->usize = w->csize = (uint64_t)n; w->crc = (uint32_t)crc32(0, (const Bytef *)tgt, (uInt)n);
            write_local(f, w); fwrite(tgt, 1, (size_t)n, f);
            cnt++;
            continue;
        }
        if ((uint64_t)st->st_size >= 0xFFF00000ull) { rc = -1; snprintf(err, errlen, "file too large for non-zip64 entry: %s", rel); break; }
        int ifd = open(e->fts_path, O_RDONLY);
        if (ifd < 0) { rc = -1; snprintf(err, errlen, "open %s: %s", rel, strerror(errno)); break; }
        w->method = 8;
        write_local(f, w);
        uint64_t data_start = (uint64_t)ftello(f);
        z_stream zs; memset(&zs, 0, sizeof zs);
        deflateInit2(&zs, 6, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
        uLong c = crc32(0, Z_NULL, 0);
        ssize_t r; int flush = Z_NO_FLUSH;
        do {
            r = read(ifd, in, CHUNK);
            if (r < 0) { rc = -1; break; }
            c = crc32(c, in, (uInt)r);
            w->usize += (uint64_t)r;
            zs.next_in = in; zs.avail_in = (uInt)r;
            flush = r == 0 ? Z_FINISH : Z_NO_FLUSH;
            do {
                zs.next_out = outb; zs.avail_out = CHUNK;
                deflate(&zs, flush);
                fwrite(outb, 1, CHUNK - zs.avail_out, f);
            } while (zs.avail_out == 0);
        } while (flush != Z_FINISH);
        deflateEnd(&zs);
        close(ifd);
        w->crc = (uint32_t)c;
        w->csize = (uint64_t)ftello(f) - data_start;
        off_t endpos = ftello(f);
        fseeko(f, (off_t)w->off + 14, SEEK_SET);
        wr32(f, w->crc); wr32(f, (uint32_t)w->csize); wr32(f, (uint32_t)w->usize);
        fseeko(f, endpos, SEEK_SET);
        cnt++;
    }
    fts_close(fts);
    free(in); free(outb);

    if (rc == 0) {
        uint64_t cd_off = (uint64_t)ftello(f);
        for (size_t i = 0; i < cnt; i++) {
            went_t *w = &ents[i];
            bool z64 = w->off >= 0xFFFFFFFFull;
            size_t nlen = strlen(w->name);
            wr32(f, 0x02014b50); wr16(f, (3 << 8) | 45); wr16(f, z64 ? 45 : 20); wr16(f, 0x0800); wr16(f, w->method);
            wr16(f, w->dtime); wr16(f, w->ddate);
            wr32(f, w->crc); wr32(f, (uint32_t)w->csize); wr32(f, (uint32_t)w->usize);
            wr16(f, (uint16_t)nlen); wr16(f, z64 ? 12 : 0); wr16(f, 0); wr16(f, 0); wr16(f, 0);
            wr32(f, w->ext); wr32(f, z64 ? 0xFFFFFFFF : (uint32_t)w->off);
            fwrite(w->name, 1, nlen, f);
            if (z64) { wr16(f, 0x0001); wr16(f, 8); wr64(f, w->off); }
        }
        uint64_t cd_end = (uint64_t)ftello(f), cd_size = cd_end - cd_off;
        bool z64 = cnt >= 0xFFFF || cd_off >= 0xFFFFFFFFull || cd_size >= 0xFFFFFFFFull;
        if (z64) {
            wr32(f, 0x06064b50); wr64(f, 44); wr16(f, (3 << 8) | 45); wr16(f, 45); wr32(f, 0); wr32(f, 0);
            wr64(f, cnt); wr64(f, cnt); wr64(f, cd_size); wr64(f, cd_off);
            wr32(f, 0x07064b50); wr32(f, 0); wr64(f, cd_end); wr32(f, 1);
        }
        wr32(f, 0x06054b50); wr16(f, 0); wr16(f, 0);
        wr16(f, z64 ? 0xFFFF : (uint16_t)cnt); wr16(f, z64 ? 0xFFFF : (uint16_t)cnt);
        wr32(f, z64 ? 0xFFFFFFFF : (uint32_t)cd_size); wr32(f, z64 ? 0xFFFFFFFF : (uint32_t)cd_off); wr16(f, 0);
    }
    if (fclose(f) != 0 && rc == 0) { rc = -1; snprintf(err, errlen, "close: %s", strerror(errno)); }
    for (size_t i = 0; i < cnt; i++) free(ents[i].name);
    free(ents);
    return rc;
}
