#ifndef APPLE_AUTH_CLIENT_C_API_H
#define APPLE_AUTH_CLIENT_C_API_H

#include <apple_auth/c_api.h>
#include <apple_auth/client_export.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct aauth_client aauth_client;
typedef struct aauth_account_session aauth_account_session;

// Device identity selectors, separate from ADI provisioning platform IDs.
typedef enum aauth_device_platform {
    AAUTH_DEVICE_AUTOMATIC = 0,
    AAUTH_DEVICE_WINDOWS = 1,
    AAUTH_DEVICE_MAC = 2,
    AAUTH_DEVICE_IPHONE = 3,
    AAUTH_DEVICE_ANDROID = 4
} aauth_device_platform;

typedef struct aauth_client_buffer {
    uint8_t* data;
    size_t size;
} aauth_client_buffer;

typedef struct aauth_http_request {
    const char* url;
    const char* method;
    const char* headers_json;
    const uint8_t* body;
    size_t body_size;
} aauth_http_request;

// Response headers preserve duplicates, including Set-Cookie.
typedef struct aauth_http_response {
    long status;
    aauth_client_buffer body;
    aauth_client_buffer headers_json; // JSON array of [name, value] pairs; allocate like body.
} aauth_http_response;

// All callbacks are synchronous. Request pointers are valid for the callback only.
// A custom transport allocates its response with aauth_client_buffer_alloc;
// the library takes ownership, including when the callback returns an error.
typedef int (*aauth_transport_callback)(void* context,
                                        const aauth_http_request* request,
                                        aauth_http_response* response);
typedef void (*aauth_http_observer)(
    void* context, const char* method, const char* url, long status, double seconds);
typedef int64_t (*aauth_clock_callback)(void* context);
typedef int (*aauth_two_factor_callback)(void* context,
                                         char* output,
                                         size_t capacity,
                                         size_t* written);

typedef struct aauth_client_options {
    aauth_transport_callback transport; // NULL selects the built-in HTTPS transport.
    aauth_http_observer observer;       // Metadata only: no headers or response bodies.
    aauth_clock_callback clock;         // NULL selects the system clock.
    void* context;
} aauth_client_options;

typedef struct aauth_mac_device {
    // NULL or empty fields reuse saved values, or defaults for a new Mac identity.
    const char* model;
    const char* macos_version;
    const char* macos_build;
} aauth_mac_device;

typedef struct aauth_iphone_device {
    const char* model;
    const char* ios_version;
    const char* ios_build;
} aauth_iphone_device;

typedef struct aauth_device_headers {
    // Device-profile shortcuts. Protocol-specific requests may replace these.
    // Use headers_json for explicit global overrides after protocol defaults.
    const char* user_agent;
    const char* client_info;
} aauth_device_headers;

// Zero-initialize. All strings, metadata and state bytes are copied during create.
// NULL directory selects RAM; state restores a snapshot into RAM and cannot be
// combined with a directory. NULL config creates a new in-memory Windows identity.
typedef struct aauth_client_config {
    const char* directory;
    const aauth_client_options* options;
    aauth_device_platform platform;
    const aauth_mac_device* mac_device;
    const aauth_iphone_device* iphone_device;
    const char* serial_number; // NULL reuses the saved serial; empty/"0" means absent.
    const aauth_device_headers* headers;
    const char* headers_json; // Optional JSON object of string header overrides.
    const uint8_t* state;
    size_t state_size;
} aauth_client_config;

typedef enum aauth_session_kind {
    AAUTH_SESSION_ACCOUNT = 0,
    AAUTH_SESSION_STORE = 1
} aauth_session_kind;

typedef enum aauth_verification_method {
    AAUTH_VERIFY_AUTOMATIC = 0,
    AAUTH_VERIFY_TRUSTED_DEVICE = 1,
    AAUTH_VERIFY_SMS = 2
} aauth_verification_method;

// phones_json is an array of {id, display_number}; return a listed ID, or cancel with nonzero.
typedef int (*aauth_phone_selection_callback)(void* context,
                                              const char* phones_json,
                                              int64_t* selected);

typedef struct aauth_verification_options {
    aauth_verification_method method;
    int64_t phone_number_id; // 0 discovers the account's trusted numbers.
    aauth_two_factor_callback code;
    aauth_phone_selection_callback select_phone;
    void* context;
} aauth_verification_options;

// Paths and strings use UTF-8. Serialize calls on each client instance.
// Handle/buffer outputs are assigned only on success; caller releases returned objects.
APPLE_AUTH_CLIENT_EXPORT const char* aauth_client_version(void);
APPLE_AUTH_CLIENT_EXPORT const char* aauth_client_last_error(void);
// New identities use a random binding without collecting host hardware identifiers.
// AUTOMATIC restores the saved platform, defaulting to Windows for new identities.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_create(const aauth_client_config* config,
                                                          aauth_client** output);
// Snapshot of identity, ADI, Store provisioning and saved session bytes. No HTTP.
// Plaintext by default; optional encryption uses aauth_client_encrypt/decrypt_session.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_state(const aauth_client* client,
                                                         aauth_client_buffer* output);
// Opaque session bytes (plain or encrypted); an empty output means no saved session.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_session_data(const aauth_client* client,
    aauth_session_kind kind, aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_set_session_data(aauth_client* client,
    aauth_session_kind kind, const uint8_t* data, size_t size);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_device_platform(const aauth_client* client,
                                                                   aauth_device_platform* output);
// UTF-8 JSON object with model/macos_version/macos_build, or null for another platform.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_mac_device(const aauth_client* client,
                                                              aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT void aauth_client_free(aauth_client* client);
// JSON metadata: platform, optional Mac/iPhone fields, serial_number (null when absent). No HTTP.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_device_info(const aauth_client* client,
                                                               aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_provision(aauth_client* client);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_headers(aauth_client* client,
                                                           aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT void aauth_account_session_free(aauth_account_session* session);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_account_session_from_plist(const uint8_t* data, size_t size, aauth_account_session** output);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_client_login(aauth_client* client,
                      const char* email,
                      const char* password,
                      const aauth_verification_options* verification,
                      aauth_account_session** output);
// JSON: account_id, token, expires_at_ms. The account must retain its authenticated sk/c fields.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_developer_session(
    aauth_client* client, const aauth_account_session* account, aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_developer_headers(aauth_client* client,
                                                                     const char* account_id,
                                                                     const char* token,
                                                                     int64_t expires_at_ms,
                                                                     aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_account_session_save(const aauth_account_session* session, const char* filename);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_account_session_plist(const aauth_account_session* session, aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_buffer_alloc(size_t size,
                                                                aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT void aauth_client_buffer_free(aauth_client_buffer* buffer);

// Optional storage helpers; buffers use aauth_client_buffer_free. No login or network.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_generate_session_key(aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_encrypt_session(const uint8_t* data, size_t size,
    const uint8_t* key, size_t key_size, aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_decrypt_session(const uint8_t* data, size_t size,
    const uint8_t* key, size_t key_size, aauth_client_buffer* output);
// Atomically store already-serialized bytes with the existing private-file permissions.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_save_session(const char* filename,
    const uint8_t* data, size_t size);

typedef struct aauth_store_session aauth_store_session;
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_store_provision(aauth_client* client);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_store_headers(aauth_client* client,
                                                                 aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_store_login(aauth_client* client,
                                                               const char* email,
                                                               const char* password,
                                                               aauth_two_factor_callback callback,
                                                               void* context,
                                                               aauth_store_session** output);
APPLE_AUTH_CLIENT_EXPORT void aauth_store_session_free(aauth_store_session* session);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_load(const char* filename,
                                                               aauth_store_session** output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_from_plist(const uint8_t* data,
                                                                     size_t size,
                                                                     aauth_store_session** output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_save(const aauth_store_session* session,
                                                               const char* filename);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_plist(const aauth_store_session* session,
                                                                aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_info(const aauth_store_session* session,
                                                               aauth_client_buffer* output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_headers(
    const aauth_store_session* session, const char* url, aauth_client_buffer* output);
// Response JSON: status, body (base64), headers (pairs). Session cookies are updated.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_store_request(aauth_client* client,
                                                                 aauth_store_session* session,
                                                                 const aauth_http_request* request,
                                                                 aauth_client_buffer* output);

typedef enum aauth_store_protocol {
    AAUTH_STORE_ANDROID_MUSIC = 0,
    AAUTH_STORE_MACOS_ACCOUNTS = 1,
    AAUTH_STORE_CONFIGURATOR = 2
} aauth_store_protocol;
typedef struct aauth_store_client aauth_store_client;
typedef struct aauth_testflight_client aauth_testflight_client;
typedef struct aauth_appstore_ios_client aauth_appstore_ios_client;
typedef struct aauth_appstore_mac_client aauth_appstore_mac_client;

// JSON feature flags, including "downloads". Download symbols are always present;
// builds without APPLE_AUTH_WITH_TESTFLIGHT return AAUTH_UNSUPPORTED.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_features(aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_client_create(
    const char *directory, aauth_store_protocol protocol, const aauth_client_options *options,
    const aauth_device_headers *headers, const char *headers_json, aauth_store_client **output);
APPLE_AUTH_CLIENT_EXPORT void aauth_store_client_free(aauth_store_client *client);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_client_provision(aauth_store_client *client);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_client_headers(aauth_store_client *client,
                                                                 aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_client_login(
    aauth_store_client *client, const char *email, const char *password,
    aauth_two_factor_callback callback, void *context, aauth_store_session **output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_client_store_login_with_pet(
    aauth_client *client, const char *email, const aauth_account_session *account,
    aauth_store_session **output);
// device supplies fresh GrandSlam headers; all handles remain caller-owned.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_client_login_with_pet(
    aauth_store_client *client, const char *email, const aauth_account_session *account,
    aauth_client *device, aauth_store_session **output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_client_request(aauth_store_client *client,
                                                                 aauth_store_session *session,
                                                                 const aauth_http_request *request,
                                                                 aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_ios_context(
    const aauth_store_session *session, const char *country, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_store_session_testflight_context(
    const aauth_store_session *session, const uint8_t *hardware20, size_t hardware_size,
    const char *headers_json, aauth_client_buffer *output);

// JSON inputs use explicit lengths. options_json for TestFlight is an optional object
// with headers (string map), deviceModel and deviceName. Returned query buffers contain
// the original JSON/plist bytes; download results are JSON metadata, never archive bytes.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_testflight_client_create(
    const uint8_t *session_json, size_t size, const aauth_client_options *transport,
    const char *options_json, aauth_testflight_client **output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_testflight_client_from_store_cookies(
    const uint8_t *context_json, size_t size, const aauth_client_options *transport,
    const char *options_json, aauth_testflight_client **output);
APPLE_AUTH_CLIENT_EXPORT void aauth_testflight_client_free(aauth_testflight_client *client);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_testflight_client_save(const aauth_testflight_client *client, const char *path);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_testflight_client_serialize(const aauth_testflight_client *client, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_testflight_client_catalog(aauth_testflight_client *client, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_testflight_client_install_metadata(
    aauth_testflight_client *client, const char *bundle, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status
// include_sinf: 1 copies Apple-provided SINF records; 0 leaves the IPA unpersonalized.
aauth_testflight_client_download_ipa(aauth_testflight_client *client, const char *bundle,
                                 const char *path, int include_sinf, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_ios_client_create(
    const uint8_t *context_json, size_t size, const aauth_client_options *transport,
    const char *headers_json, aauth_appstore_ios_client **output);
APPLE_AUTH_CLIENT_EXPORT void aauth_appstore_ios_client_free(aauth_appstore_ios_client *client);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_ios_client_catalog(
    aauth_appstore_ios_client *client, uint64_t app_id, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_ios_client_metadata(
    aauth_appstore_ios_client *client, uint64_t app_id, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_ios_client_offer(
    aauth_appstore_ios_client *client, uint64_t app_id, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_ios_client_acquire_free(
    aauth_appstore_ios_client *client, uint64_t app_id, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_appstore_ios_client_download_ipa(aauth_appstore_ios_client *client, uint64_t app_id,
                                   const char *path, int include_sinf, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_mac_client_create(
    const aauth_store_session *session, const char *store_directory, const char *country,
    const aauth_client_options *options, const aauth_device_headers *headers,
    const char *headers_json, aauth_appstore_mac_client **output);
APPLE_AUTH_CLIENT_EXPORT void aauth_appstore_mac_client_free(aauth_appstore_mac_client *client);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_mac_client_catalog(
    aauth_appstore_mac_client *client, uint64_t app_id, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_mac_client_metadata(
    aauth_appstore_mac_client *client, uint64_t app_id, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_appstore_mac_client_offer(
    aauth_appstore_mac_client *client, uint64_t app_id, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status
aauth_appstore_mac_client_download(aauth_appstore_mac_client *client, uint64_t app_id,
                                   const char *path, int package, aauth_client_buffer *output);
// Offline helpers; hardware must match the original download metadata.
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_generate_kbsync(uint64_t dsid, const uint8_t *hardware,
                                                            size_t hardware_size,
                                                            const uint8_t *entropy,
                                                            size_t entropy_size,
                                                            aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_unwrap_testflight_transport(
    const char *source, const char *destination, const uint8_t *hardware20, size_t hardware_size,
    const uint8_t *dp_info, size_t dp_info_size, aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_normalize_testflight_ipa(const char *source,
                                                                     const char *destination,
                                                                     const char *expected_bundle,
                                                                     aauth_client_buffer *output);
APPLE_AUTH_CLIENT_EXPORT aauth_status aauth_unwrap_appstore_mac_package(
    const char *source, const char *destination, const uint8_t *hardware6, size_t hardware_size,
    const uint8_t *dp_info, size_t dp_info_size, aauth_client_buffer *output);

#ifdef __cplusplus
}
#endif
#endif
