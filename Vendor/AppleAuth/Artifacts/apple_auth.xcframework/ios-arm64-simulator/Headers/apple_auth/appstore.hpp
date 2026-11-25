#pragma once
#include <apple_auth/client.hpp>

namespace apple_auth {

struct AppStoreIosOffer {
    std::uint64_t app_id = 0;
    std::string bundle, version, external_version_id;
};

struct AppStoreIosDownload {
    AppStoreIosOffer offer;
    std::filesystem::path path, material_directory;
    std::uint64_t bytes = 0, members = 0;
    std::string sha256;
    std::vector<std::uint32_t> main_cryptids;
    std::vector<std::string> version_ids;
};

// saved_context is the JSON returned by StoreSession::ios_context().
class AppStoreIosClient {
  public:
    APPLE_AUTH_CLIENT_EXPORT explicit AppStoreIosClient(ByteView saved_context,
                                                        Transport transport = {});
    APPLE_AUTH_CLIENT_EXPORT
    AppStoreIosClient(ByteView saved_context, Transport transport, Headers headers);
    APPLE_AUTH_CLIENT_EXPORT AppStoreIosClient(const StoreSession& session,
                                               const std::string& country,
                                               Transport transport = {});
    APPLE_AUTH_CLIENT_EXPORT AppStoreIosClient(const StoreSession& session,
                                               const std::string& country,
                                               Transport transport,
                                               Headers headers);
    APPLE_AUTH_CLIENT_EXPORT ~AppStoreIosClient();
    APPLE_AUTH_CLIENT_EXPORT AppStoreIosClient(AppStoreIosClient&&) noexcept;
    APPLE_AUTH_CLIENT_EXPORT AppStoreIosClient& operator=(AppStoreIosClient&&) noexcept;
    AppStoreIosClient(const AppStoreIosClient&) = delete;
    AppStoreIosClient& operator=(const AppStoreIosClient&) = delete;

    APPLE_AUTH_CLIENT_EXPORT Bytes catalog(std::uint64_t app_id);
    APPLE_AUTH_CLIENT_EXPORT AppStoreIosOffer offer(std::uint64_t app_id);

    APPLE_AUTH_CLIENT_EXPORT Bytes metadata(std::uint64_t app_id);

    // Makes one purchase request after verifying that the offer is free.
    APPLE_AUTH_CLIENT_EXPORT Bytes acquire_free(std::uint64_t app_id);

    // Copies Apple's SINF records into SC_Info by default; false keeps original CDN bytes.
    APPLE_AUTH_CLIENT_EXPORT AppStoreIosDownload download(std::uint64_t app_id,
                                                          const std::filesystem::path& destination,
                                                          bool include_sinf = true);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

struct AppStoreMacOffer {
    std::uint64_t app_id = 0;
    std::string bundle, external_version_id;
};

struct AppStoreMacPackageInfo {
    std::uint64_t bytes = 0, members = 0;
    std::string sha256;
};

APPLE_AUTH_CLIENT_EXPORT AppStoreMacPackageInfo
unwrap_appstore_mac_package(const std::filesystem::path& source,
                            const std::filesystem::path& destination,
                            ByteView hardware6,
                            ByteView dp_info88);

struct AppStoreMacDownload {
    AppStoreMacOffer offer;
    std::filesystem::path path, material_directory, original_path;
    std::uint64_t bytes = 0;
    std::string version, sha256;
    std::vector<std::string> version_ids;

    bool transport_wrapped = false;
    bool package_validated = false;
    std::uint64_t members = 0;
};

// Requires a saved macOS Store session and matching Store ADI state.
class AppStoreMacClient {
  public:
    APPLE_AUTH_CLIENT_EXPORT AppStoreMacClient(const StoreSession& session,
                                               std::filesystem::path store_directory,
                                               std::string country,
                                               ClientOptions options = {});
    APPLE_AUTH_CLIENT_EXPORT ~AppStoreMacClient();
    APPLE_AUTH_CLIENT_EXPORT AppStoreMacClient(AppStoreMacClient&&) noexcept;
    APPLE_AUTH_CLIENT_EXPORT AppStoreMacClient& operator=(AppStoreMacClient&&) noexcept;
    AppStoreMacClient(const AppStoreMacClient&) = delete;
    AppStoreMacClient& operator=(const AppStoreMacClient&) = delete;

    APPLE_AUTH_CLIENT_EXPORT Bytes catalog(std::uint64_t app_id);
    APPLE_AUTH_CLIENT_EXPORT AppStoreMacOffer offer(std::uint64_t app_id);

    APPLE_AUTH_CLIENT_EXPORT Bytes metadata(std::uint64_t app_id);

    APPLE_AUTH_CLIENT_EXPORT AppStoreMacDownload download(std::uint64_t app_id,
                                                          const std::filesystem::path& destination);

    // Validates and unwraps XAR; download() preserves the original asset.
    APPLE_AUTH_CLIENT_EXPORT AppStoreMacDownload
    download_package(std::uint64_t app_id, const std::filesystem::path& destination);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace apple_auth
