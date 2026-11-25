#pragma once

#include <apple_auth/client_export.h>
#include <apple_auth/core.hpp>
#include <apple_auth/session_crypto.hpp>

#include <filesystem>
#include <functional>
#include <map>
#include <optional>

namespace apple_auth {
namespace netdetail { class StateStorage; }

using Headers = std::map<std::string, std::string>;

struct HttpRequest {
    std::string url;
    std::string method = "POST";
    Headers headers;
    Bytes body;
};

struct HttpResponse {
    long status = 0;
    Bytes body;
    // Preserve duplicates, particularly Set-Cookie.
    std::vector<std::pair<std::string, std::string>> headers{};
};

using Transport = std::function<HttpResponse(const HttpRequest&)>;
using TwoFactor = std::function<std::string()>;

enum class VerificationMethod {
    automatic,
    trusted_device,
    sms
};

struct TrustedPhoneNumber {
    std::int64_t id;
    std::string display_number;
};

struct VerificationOptions {
    TwoFactor code;
    VerificationMethod method = VerificationMethod::automatic;
    std::int64_t phone_number_id = 0;
    std::function<std::int64_t(const std::vector<TrustedPhoneNumber>&)> select_phone;
};

// Device identity platform, independent of the host OS.
enum class DevicePlatform {
    automatic = 0, // Reuse the saved platform; Windows for a new identity.
    windows = 1,
    mac = 2,
    iphone = 3,
    android = 4
};

struct MacDevice {
    // Empty fields reuse saved values, or defaults for a new Mac identity.
    // Reopen with a new version/build pair to update the OS, keeping the model.
    std::string model;
    std::string macos_version;
    std::string macos_build;

    bool operator==(const MacDevice&) const = default;
};

struct IPhoneDevice {
    // OS version/build can change on reopen; model and device identity stay fixed.
    std::string model;
    std::string ios_version;
    std::string ios_build;

    bool operator==(const IPhoneDevice&) const = default;
};

struct ClientOptions {
    // Empty selects the bundled curl HTTPS transport.
    Transport transport;
    std::function<std::int64_t()> clock;
    DevicePlatform device_platform = DevicePlatform::automatic;
    MacDevice mac_device{};
    // Unset reuses the saved serial; omitted for new identities. Empty or "0" means absent.
    std::optional<std::string> serial_number{};
    IPhoneDevice iphone_device{};
    // Optional SAP entropy source; empty uses the SDK CSPRNG.
    std::function<SapEntropy()> sap_entropy;
    // Device-profile shortcuts; empty values use the platform defaults.
    // Protocol-specific requests may replace them (e.g. User-Agent: Xcode).
    std::string user_agent;
    std::string client_info;
    // Explicit global overrides, applied after device and protocol defaults.
    Headers headers;
};

struct AccountSession {
    std::string account_id;
    std::string pet;
    Bytes plist;

    APPLE_AUTH_CLIENT_EXPORT static AccountSession from_plist(ByteView data);
    APPLE_AUTH_CLIENT_EXPORT static AccountSession load(const std::filesystem::path& file);
    APPLE_AUTH_CLIENT_EXPORT void save(const std::filesystem::path& file) const;
    APPLE_AUTH_CLIENT_EXPORT Bytes serialize(std::optional<ByteView> encryption_key = {}) const;
    APPLE_AUTH_CLIENT_EXPORT static AccountSession deserialize(ByteView data,
        std::optional<ByteView> encryption_key = {});
    APPLE_AUTH_CLIENT_EXPORT static AccountSession load(const std::filesystem::path& file, ByteView encryption_key);
    APPLE_AUTH_CLIENT_EXPORT void save(const std::filesystem::path& file, ByteView encryption_key) const;
};

struct DeveloperSession {
    // Opaque GrandSlam ADSID, preserved as returned by Apple (not necessarily numeric).
    std::string account_id;
    std::string token;
    std::int64_t expires_at_ms = 0;
    APPLE_AUTH_CLIENT_EXPORT Bytes serialize(std::optional<ByteView> encryption_key = {}) const;
    APPLE_AUTH_CLIENT_EXPORT static DeveloperSession deserialize(ByteView data,
        std::optional<ByteView> encryption_key = {});
    APPLE_AUTH_CLIENT_EXPORT static DeveloperSession load(const std::filesystem::path& file,
        std::optional<ByteView> encryption_key = {});
    APPLE_AUTH_CLIENT_EXPORT void save(const std::filesystem::path& file,
        std::optional<ByteView> encryption_key = {}) const;
};

enum class StoreProtocol {
    android_music,
    macos_accounts,
    configurator
};

enum class SessionKind { account, store };

class StoreSession {
  public:
    APPLE_AUTH_CLIENT_EXPORT static StoreSession from_plist(ByteView data);
    APPLE_AUTH_CLIENT_EXPORT static StoreSession load(const std::filesystem::path& file);
    APPLE_AUTH_CLIENT_EXPORT ~StoreSession();
    APPLE_AUTH_CLIENT_EXPORT StoreSession(StoreSession&&) noexcept;
    APPLE_AUTH_CLIENT_EXPORT StoreSession& operator=(StoreSession&&) noexcept;
    StoreSession(const StoreSession&) = delete;
    StoreSession& operator=(const StoreSession&) = delete;
    APPLE_AUTH_CLIENT_EXPORT std::string account_id() const;
    APPLE_AUTH_CLIENT_EXPORT std::string storefront() const;
    APPLE_AUTH_CLIENT_EXPORT StoreProtocol protocol() const;
    APPLE_AUTH_CLIENT_EXPORT Headers headers(const std::string& url) const;
    APPLE_AUTH_CLIENT_EXPORT Bytes plist() const;
    APPLE_AUTH_CLIENT_EXPORT void save(const std::filesystem::path& file) const;
    APPLE_AUTH_CLIENT_EXPORT Bytes serialize(std::optional<ByteView> encryption_key = {}) const;
    APPLE_AUTH_CLIENT_EXPORT static StoreSession deserialize(ByteView data,
        std::optional<ByteView> encryption_key = {});
    APPLE_AUTH_CLIENT_EXPORT static StoreSession load(const std::filesystem::path& file, ByteView encryption_key);
    APPLE_AUTH_CLIENT_EXPORT void save(const std::filesystem::path& file, ByteView encryption_key) const;
    // JSON contexts for AppStoreIosClient and TestFlightClient.
    APPLE_AUTH_CLIENT_EXPORT Bytes ios_context(const std::string& country) const;
    APPLE_AUTH_CLIENT_EXPORT Bytes testflight_context(ByteView hardware20,
                                                      Headers device_headers) const;
    APPLE_AUTH_CLIENT_EXPORT void save_ios_context(const std::filesystem::path& file,
                                                   const std::string& country) const;
    APPLE_AUTH_CLIENT_EXPORT void save_testflight_context(const std::filesystem::path& file,
                                                          ByteView hardware20,
                                                          Headers device_headers) const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    explicit StoreSession(std::unique_ptr<Impl> impl);
    friend class StoreClient;
};

// The default protocol is Android Music.
class StoreClient {
  public:
    APPLE_AUTH_CLIENT_EXPORT explicit StoreClient(std::filesystem::path directory,
                                                  ClientOptions options = {});
    APPLE_AUTH_CLIENT_EXPORT StoreClient(std::filesystem::path directory,
                                         StoreProtocol protocol,
                                         ClientOptions options = {});
    APPLE_AUTH_CLIENT_EXPORT ~StoreClient();
    APPLE_AUTH_CLIENT_EXPORT StoreClient(StoreClient&&) noexcept;
    APPLE_AUTH_CLIENT_EXPORT StoreClient& operator=(StoreClient&&) noexcept;
    StoreClient(const StoreClient&) = delete;
    StoreClient& operator=(const StoreClient&) = delete;
    APPLE_AUTH_CLIENT_EXPORT void provision();
    APPLE_AUTH_CLIENT_EXPORT Headers headers();
    APPLE_AUTH_CLIENT_EXPORT StoreSession login(const std::string& email,
                                                const std::string& password,
                                                const TwoFactor& two_factor);
    // macOS Accounts only. Does not obtain or refresh PET. Callback supplies
    // fresh Mac GrandSlam device headers; Store anisette remains separate.
    APPLE_AUTH_CLIENT_EXPORT StoreSession
    login_with_pet(const std::string& email,
                   const AccountSession& account,
                   const std::function<Headers()>& device_headers);
    // Adds fresh anisette, session authentication and SAP; updates session cookies.
    APPLE_AUTH_CLIENT_EXPORT HttpResponse request(StoreSession& session, HttpRequest request);

  private:
    StoreClient(netdetail::StateStorage storage, StoreProtocol protocol, ClientOptions options);
    friend class Client;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Local identity, provisioning and GrandSlam login, in memory or in private files.
// Serialize calls on each instance; independent file clients need separate directories.
class Client {
  public:
    // No directory or temporary files: identity and provisioning stay in RAM.
    APPLE_AUTH_CLIENT_EXPORT explicit Client(ClientOptions options = {});
    APPLE_AUTH_CLIENT_EXPORT explicit Client(std::filesystem::path directory,
                                             ClientOptions options = {});
    // Restore a snapshot into memory. Explicit encryption is optional.
    APPLE_AUTH_CLIENT_EXPORT Client(ByteView state, ClientOptions options = {},
                                    std::optional<ByteView> encryption_key = {});
    APPLE_AUTH_CLIENT_EXPORT Bytes serialize_state(std::optional<ByteView> encryption_key = {}) const;
    // Opaque serialized session bytes, used by higher-level automatic storage.
    APPLE_AUTH_CLIENT_EXPORT Bytes session_data(SessionKind kind = SessionKind::account) const;
    APPLE_AUTH_CLIENT_EXPORT void set_session_data(ByteView data, SessionKind kind = SessionKind::account);
    APPLE_AUTH_CLIENT_EXPORT ~Client();
    APPLE_AUTH_CLIENT_EXPORT Client(Client&&) noexcept;
    APPLE_AUTH_CLIENT_EXPORT Client& operator=(Client&&) noexcept;
    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;

    APPLE_AUTH_CLIENT_EXPORT void provision();
    APPLE_AUTH_CLIENT_EXPORT Headers headers();
    APPLE_AUTH_CLIENT_EXPORT DevicePlatform device_platform() const noexcept;
    // Resolved metadata; empty fields for another platform. No HTTP.
    APPLE_AUTH_CLIENT_EXPORT MacDevice mac_device() const;
    APPLE_AUTH_CLIENT_EXPORT IPhoneDevice iphone_device() const;
    APPLE_AUTH_CLIENT_EXPORT std::string serial_number() const;
    APPLE_AUTH_CLIENT_EXPORT AccountSession login(const std::string& email,
                                                  const std::string& password,
                                                  const TwoFactor& two_factor);
    APPLE_AUTH_CLIENT_EXPORT AccountSession
    login_with_options(const std::string& email,
                       const std::string& password,
                       const VerificationOptions& verification);
    APPLE_AUTH_CLIENT_EXPORT DeveloperSession developer_session(const AccountSession& account);
    APPLE_AUTH_CLIENT_EXPORT Headers developer_headers(const DeveloperSession& session);
    APPLE_AUTH_CLIENT_EXPORT void provision_store();
    APPLE_AUTH_CLIENT_EXPORT Headers store_headers();
    APPLE_AUTH_CLIENT_EXPORT StoreSession login_store(const std::string& email,
                                                      const std::string& password,
                                                      const TwoFactor& two_factor);
    // Requires a Mac Client and an existing Mac GSA/PET session.
    APPLE_AUTH_CLIENT_EXPORT StoreSession login_store_with_pet(const std::string& email,
                                                               const AccountSession& account);
    APPLE_AUTH_CLIENT_EXPORT HttpResponse store_request(StoreSession& session, HttpRequest request);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace apple_auth
