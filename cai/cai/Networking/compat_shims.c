/*
 * compat_shims.c — C runtime functions missing on iOS 6, provided statically.
 *
 * memset_s (C11 Annex K) is declared in the iOS SDK as __IPHONE_7_0. It does
 * NOT exist in iOS 6's libSystem. libssh2 / OpenSSL 3.4.x call it to securely
 * wipe Diffie-Hellman / curve25519 secrets after key exchange, so the compiled
 * static libs contain an undefined external "_memset_s". On iOS 7+ dyld binds
 * it to libSystem; on the iOS 6 device there is no such symbol, so its lazy
 * stub binds to garbage and the process traps (SIGTRAP) mid-handshake — exactly
 * the crash seen inside diffie_hellman_sha_algo / curve25519_sha256.
 *
 * Defining it here makes the linker resolve "_memset_s" internally (the symbol
 * is no longer an undefined external), so nothing is bound at runtime on iOS 6.
 *
 * Signature matches the SDK's C11 Annex K declaration
 *   errno_t memset_s(void *s, rsize_t smax, int c, rsize_t n)
 * using the underlying types (errno_t == int, rsize_t == size_t) so the ABI is
 * identical. We don't include the SDK's guarded declaration (it's behind
 * __STDC_WANT_LIB_EXT1__, which we leave undefined) to avoid a redefinition.
 */
#include <string.h>
#include <errno.h>

int memset_s(void *s, size_t smax, int c, size_t n) {
    if (s == NULL) {
        return EINVAL;
    }
    /* Runtime-constraint violation: n larger than the destination. Wipe what
     * we safely can (smax bytes) and report the error, per Annex K. */
    if (n > smax) {
        memset(s, c, smax);
        return ERANGE;
    }
    memset(s, c, n);
    return 0;
}
