/*
 * In-process libFuzzer harness for HapCUT2's extractHAIRS VCF-record parser.
 *
 * WHY a harness (not the raw `--vcf @@` file CLI): extractHAIRS is a one-shot batch CLI whose VCF
 * reader performs unchecked reads on malformed input. Without sanitizers those are silent UB (the
 * historical raw file-input Mayhem runs stayed alive and reached ~9k edges). WITH the required
 * halting ASan they abort on nearly ANY trivial input, so Mayhem's file-input sanity probe ("must
 * complete on basic inputs like 'A'") fails and the run records 0 edges. Per the porting skill, when
 * halting sanitizers make a raw file-input target unfuzzable due to an upstream bug we can't patch,
 * convert it to an in-process libFuzzer harness over the SAME code path.
 *
 * WHAT it drives: the fuzzed bytes are exactly what `@@` fed `--vcf`. count_variants() (the line
 * counter) is exercised over the whole input, then each non-header line is handed to parse_variant()
 * in hairs-src/readvariant.c — the substantive record parser (column split, genotype validation,
 * allele reduction). This is the meaningful VCF parsing logic and where the deep memory-safety
 * questions live.
 *
 * We deliberately do NOT route lines through read_variantfile(): that wrapper contains a separate,
 * shallow upstream crash (readvariant.c:213 dereferences varlist[i].chrom, which parse_variant
 * leaves NULL when it rejects a <10-column record — the real `--vcf` CLI SIGSEGVs identically, e.g.
 * `extractHAIRS --vcf <one-word-line>`). That garbage-in null-deref fires on essentially the first
 * malformed byte and would mask everything else; it is recorded as a finding rather than fuzzed in a
 * loop. Driving parse_variant() directly keeps the harness robust on trivial inputs (it returns a
 * status, never crashes on short lines) so the fuzzer can reach the interesting parser states.
 *
 * The parser is designed to exit()/assert() on bad genotypes; those are the CLI's normal control
 * flow, not the memory bugs we hunt. We (a) build with -DNDEBUG so assert() is the standard release
 * no-op, and (b) link with -Wl,--wrap=exit so the parser's exit() unwinds back here via longjmp
 * instead of killing the long-lived fuzzer. Real memory-safety faults still abort under ASan/UBSan
 * and surface as libFuzzer/Mayhem defects. detect_leaks=0 (baked via the linked
 * __asan_default_options): the upstream parser's allocation discipline is loose on error paths — we
 * hunt spatial memory-safety + UB here, not leaks.
 */
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "hashtable.h"
#include "readvariant.h"

/* Globals declared `extern` in readvariant.h but defined in extracthairs.c (which owns main() and
 * cannot be linked here). Reproduce their default values from extracthairs.c. */
int BSIZE = 500;
int TRI_ALLELIC = 0;
int PRINT_FRAGMENTS = 0;
FILE* fragment_file = NULL;

static jmp_buf g_exit_jmp;
static int g_in_run = 0;

/* Intercept the parser's exit() (bad-genotype path) so a single malformed record does not kill the
 * long-lived fuzzer process. Outside a run, behave like the real exit(). */
void __wrap_exit(int code) {
    if (g_in_run) longjmp(g_exit_jmp, 1);
    _exit(code);
}

static void free_variant(VARIANT* v) {
    free(v->chrom);
    free(v->RA);
    free(v->AA);
    free(v->genotype);
    free(v->allele1);
    free(v->allele2);
    free(v->id);
    free(v->GLL);
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    /* extracthairs.c defaults: a single-sample VCF, sample column 10. count_variants() does not
     * modify samplecol; it only counts lines (and updates it solely from a #CHROM header, which we
     * mirror by letting count_variants see the same bytes). */
    char sampleid[2] = {'-', '\0'};
    int samplecol = 10;

    /* 1) Exercise the line counter over the exact input, via a temp file (its only interface). */
    char path[] = "/tmp/hapcut2_vcf_XXXXXX";
    int fd = mkstemp(path);
    if (fd >= 0) {
        if (size == 0 || write(fd, data, size) == (ssize_t)size) {
            close(fd);
            (void)count_variants(path, sampleid, &samplecol);
        } else {
            close(fd);
        }
        unlink(path);
    }

    /* 2) Drive the record parser on each non-header line. splitString() (called by parse_variant)
     * treats '\n' and '\0' as terminators, so a pointer into a NUL-terminated copy is enough. */
    char* buf = (char*)malloc(size + 1);
    if (buf == NULL) return 0;
    memcpy(buf, data, size);
    buf[size] = '\0';

    char* p = buf;
    while (*p != '\0') {
        char* line = p;
        while (*p != '\0' && *p != '\n') p++;
        if (*p == '\n') p++;   /* advance past the newline for the next iteration */

        if (*line == '#' || *line == '\n' || *line == '\0') continue;

        VARIANT v;
        memset(&v, 0, sizeof(v));
        g_in_run = 1;
        if (setjmp(g_exit_jmp) == 0) {
            (void)parse_variant(&v, line, samplecol);
        }
        g_in_run = 0;
        free_variant(&v);
    }

    free(buf);
    return 0;
}
