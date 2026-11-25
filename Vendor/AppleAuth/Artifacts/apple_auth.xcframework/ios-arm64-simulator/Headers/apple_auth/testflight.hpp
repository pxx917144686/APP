#pragma once
#include <apple_auth/client.hpp>
#include <apple_auth/store_core.hpp>

namespace apple_auth {

struct TestFlightArchiveInfo {
    std::string bundle;
    std::size_t members{}, encrypted_images{}, clear_images{};
};

struct TestFlightDownload {
    TestFlightArchiveInfo archive;
    std::uint64_t downloaded_bytes{};
    std::filesystem::path artifacts;
};

struct TestFlightOptions {
    Headers headers;
    std::string device_model;
    std::string device_name;
};

class TestFlightClient {
  public:
    APPLE_AUTH_CLIENT_EXPORT explicit TestFlightClient(ByteView saved_session_json,
                                                       Transport transport = {});
    APPLE_AUTH_CLIENT_EXPORT
    TestFlightClient(ByteView saved_session_json, Transport transport, TestFlightOptions options);
    // Creates a TestFlight session from saved Store cookies.
    APPLE_AUTH_CLIENT_EXPORT static TestFlightClient
    from_store_cookies(ByteView saved_store_context_json, Transport transport = {});
    APPLE_AUTH_CLIENT_EXPORT static TestFlightClient from_store_cookies(
        ByteView saved_store_context_json, Transport transport, TestFlightOptions options);
    APPLE_AUTH_CLIENT_EXPORT static TestFlightClient from_store_session(const StoreSession& session,
                                                                        ByteView hardware20,
                                                                        Headers mac_device_headers,
                                                                        Transport transport = {});
    APPLE_AUTH_CLIENT_EXPORT static TestFlightClient from_store_session(const StoreSession& session,
                                                                        ByteView hardware20,
                                                                        Headers mac_device_headers,
                                                                        Transport transport,
                                                                        TestFlightOptions options);
    APPLE_AUTH_CLIENT_EXPORT ~TestFlightClient();
    APPLE_AUTH_CLIENT_EXPORT TestFlightClient(TestFlightClient&&) noexcept;
    APPLE_AUTH_CLIENT_EXPORT TestFlightClient& operator=(TestFlightClient&&) noexcept;
    TestFlightClient(const TestFlightClient&) = delete;
    TestFlightClient& operator=(const TestFlightClient&) = delete;
    APPLE_AUTH_CLIENT_EXPORT void save(const std::filesystem::path& session_file) const;
    APPLE_AUTH_CLIENT_EXPORT Bytes serialize(std::optional<ByteView> encryption_key = {}) const;
    APPLE_AUTH_CLIENT_EXPORT static TestFlightClient deserialize(ByteView data,
        std::optional<ByteView> encryption_key = {}, Transport transport = {}, TestFlightOptions options = {});
    APPLE_AUTH_CLIENT_EXPORT static TestFlightClient load(const std::filesystem::path& session_file,
        std::optional<ByteView> encryption_key = {}, Transport transport = {}, TestFlightOptions options = {});
    APPLE_AUTH_CLIENT_EXPORT void save(const std::filesystem::path& session_file, ByteView encryption_key) const;
    APPLE_AUTH_CLIENT_EXPORT Bytes catalog();
    APPLE_AUTH_CLIENT_EXPORT Bytes install_metadata(const std::string& bundle);
    APPLE_AUTH_CLIENT_EXPORT void save_catalog(const std::filesystem::path& file);
    APPLE_AUTH_CLIENT_EXPORT void save_install_metadata(const std::string& bundle,
                                                        const std::filesystem::path& file);
    // Copies Apple's SINF records into SC_Info by default; content remains encrypted.
    APPLE_AUTH_CLIENT_EXPORT TestFlightDownload download(const std::string& bundle,
                                                         const std::filesystem::path& output,
                                                         bool include_sinf = true);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

APPLE_AUTH_CLIENT_EXPORT std::uint64_t
unwrap_testflight_transport(const std::filesystem::path& input,
                            const std::filesystem::path& output,
                            ByteView hardware20,
                            ByteView dp_info88);
APPLE_AUTH_CLIENT_EXPORT TestFlightArchiveInfo
normalize_testflight_ipa(const std::filesystem::path& input,
                         const std::filesystem::path& output,
                         const std::string& expected_bundle = {});

} // namespace apple_auth
