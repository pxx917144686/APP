#ifndef APPLE_AUTH_C_API_H
#define APPLE_AUTH_C_API_H

#include <apple_auth/export.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct aauth_profile aauth_profile;
typedef struct aauth_provisioning aauth_provisioning;
typedef struct aauth_srp aauth_srp;
typedef struct aauth_srp_proof aauth_srp_proof;

enum {
    AAUTH_HARDWARE_ID_SIZE = 20,
    AAUTH_MACHINE_ID_SIZE = 60,
    AAUTH_OTP_SIZE = 16,
    AAUTH_BODY_ENTROPY_SIZE = 84
};

typedef enum aauth_profile_type {
    AAUTH_PROFILE_STORE = -1,
    AAUTH_PROFILE_GRANDSLAM = -2
} aauth_profile_type;

typedef enum aauth_status {
    AAUTH_OK = 0,
    AAUTH_INVALID_ARGUMENT = 1,
    AAUTH_INVALID_DATA = 2,
    AAUTH_BUFFER_TOO_SMALL = 3,
    AAUTH_NETWORK_ERROR = 4,
    AAUTH_AUTHENTICATION_ERROR = 5,
    AAUTH_INTERNAL_ERROR = 6,
    AAUTH_UNSUPPORTED = 7
} aauth_status;

// Error text is thread-local, valid until the next API call on that thread.
APPLE_AUTH_EXPORT const char* aauth_last_error(void);
APPLE_AUTH_EXPORT const char* aauth_version(void);
// Optional AES-256-GCM storage helpers. Keys are exactly 32 raw bytes.
// Size query: output=NULL, capacity=0, written!=NULL. Failed decrypts never copy plaintext.
APPLE_AUTH_EXPORT aauth_status aauth_session_key_generate(uint8_t* output, size_t capacity);
APPLE_AUTH_EXPORT aauth_status aauth_session_encrypt(const uint8_t* data, size_t size,
    const uint8_t* key, size_t key_size, uint8_t* output, size_t capacity, size_t* written);
APPLE_AUTH_EXPORT aauth_status aauth_session_decrypt(const uint8_t* data, size_t size,
    const uint8_t* key, size_t key_size, uint8_t* output, size_t capacity, size_t* written);
APPLE_AUTH_EXPORT aauth_status aauth_local_hardware_id(uint8_t* output, size_t capacity);
APPLE_AUTH_EXPORT aauth_status aauth_time_counter(int64_t unix_seconds, uint32_t* output);

// A handle output is assigned only on success. Caller destroys every returned handle.
APPLE_AUTH_EXPORT aauth_status aauth_profile_import(const uint8_t* file,
                                                    size_t file_size,
                                                    const uint8_t hardware[20],
                                                    const char* filename,
                                                    aauth_profile** output);
APPLE_AUTH_EXPORT void aauth_profile_free(aauth_profile* profile);
APPLE_AUTH_EXPORT aauth_status aauth_profile_kind(const aauth_profile* profile, int* output);
APPLE_AUTH_EXPORT aauth_status aauth_profile_machine_id(const aauth_profile* profile,
                                                        uint8_t* output,
                                                        size_t capacity);
APPLE_AUTH_EXPORT aauth_status aauth_profile_otp(const aauth_profile* profile,
                                                 uint32_t counter,
                                                 uint8_t* output,
                                                 size_t capacity);

// Size query: output=NULL, capacity=0. On insufficient capacity only *written changes.
// Prefix and IV are caller-supplied per-file randomness; never reuse an IV with one key.
APPLE_AUTH_EXPORT aauth_status aauth_profile_export(const aauth_profile* profile,
                                                    const uint8_t hardware[20],
                                                    const char* filename,
                                                    uint32_t version,
                                                    const uint8_t* prefix,
                                                    size_t prefix_size,
                                                    const uint8_t iv[16],
                                                    uint8_t* output,
                                                    size_t capacity,
                                                    size_t* written);

// Optional deterministic entropy for protocol tests. All byte arrays have fixed lengths.
// Pass NULL for all three entropy pointers to use the secure random generator.
APPLE_AUTH_EXPORT aauth_status aauth_provisioning_begin(const uint8_t* challenge,
                                                        size_t challenge_size,
                                                        const uint8_t hardware[20],
                                                        uint32_t unix_seconds,
                                                        const uint8_t* selector,
                                                        size_t selector_size,
                                                        const uint8_t body_entropy[84],
                                                        const uint8_t nonce[16],
                                                        aauth_provisioning** output);
APPLE_AUTH_EXPORT aauth_status aauth_provisioning_request(const aauth_provisioning* session,
                                                          uint8_t* output,
                                                          size_t capacity,
                                                          size_t* written);
APPLE_AUTH_EXPORT aauth_status aauth_provisioning_finish(aauth_provisioning* session,
                                                         const uint8_t* ptm,
                                                         size_t ptm_size,
                                                         const uint8_t trust_key[16],
                                                         aauth_profile** output);
APPLE_AUTH_EXPORT void aauth_provisioning_free(aauth_provisioning* session);

// NULL secret selects secure randomness. Explicit secrets are for protocol tests.
APPLE_AUTH_EXPORT aauth_status aauth_srp_create(const uint8_t* secret, size_t secret_size,
                                               aauth_srp** output);
APPLE_AUTH_EXPORT void aauth_srp_free(aauth_srp* session);
APPLE_AUTH_EXPORT aauth_status aauth_srp_public_key(const aauth_srp* session, uint8_t* output,
                                                   size_t capacity, size_t* written);
APPLE_AUTH_EXPORT aauth_status aauth_srp_complete(const aauth_srp* session,
                                                 const char* user, const char* password,
                                                 const uint8_t* salt, size_t salt_size,
                                                 const uint8_t* server, size_t server_size,
                                                 int iterations, const char* protocol,
                                                 aauth_srp_proof** output);
APPLE_AUTH_EXPORT void aauth_srp_proof_free(aauth_srp_proof* proof);
APPLE_AUTH_EXPORT aauth_status aauth_srp_client_proof(const aauth_srp_proof* proof, uint8_t* output,
                                                     size_t capacity, size_t* written);
// Verify M2 before decrypting SPD. Output is authenticated plist data, possibly a dict fragment.
APPLE_AUTH_EXPORT aauth_status aauth_srp_verify_session(const aauth_srp_proof* proof,
                                                       const uint8_t* server_proof, size_t proof_size,
                                                       const uint8_t* encrypted, size_t encrypted_size,
                                                       uint8_t* output, size_t capacity, size_t* written);

#ifdef __cplusplus
}
#endif
#endif
