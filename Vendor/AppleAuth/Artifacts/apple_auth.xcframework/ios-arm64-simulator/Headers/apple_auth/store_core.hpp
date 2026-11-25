#pragma once
#include <apple_auth/core.hpp>

namespace apple_auth {

// Hardware: 6 bytes for Store, 20 for TestFlight. Empty entropy uses the SDK CSPRNG.
APPLE_AUTH_EXPORT Bytes generate_kbsync(std::uint64_t dsid,
                                        ByteView hardware,
                                        ByteView entropy = {});

// Removes the download transport layer, preserving FairPlay-encrypted content.
// Call with consecutive chunks of 32768 bytes; only the last chunk may be shorter.
class TestFlightTransport {
  public:
    APPLE_AUTH_EXPORT TestFlightTransport(ByteView hardware20, ByteView dp_info88);
    APPLE_AUTH_EXPORT ~TestFlightTransport();
    APPLE_AUTH_EXPORT TestFlightTransport(TestFlightTransport&&) noexcept;
    APPLE_AUTH_EXPORT TestFlightTransport& operator=(TestFlightTransport&&) noexcept;
    TestFlightTransport(const TestFlightTransport&) = delete;
    TestFlightTransport& operator=(const TestFlightTransport&) = delete;
    APPLE_AUTH_EXPORT void decrypt_chunk(std::span<std::uint8_t> chunk) const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Mac App Store dpInfo v3; uses the same chunk boundaries as TestFlightTransport.
class AppStoreMacTransport {
  public:
    APPLE_AUTH_EXPORT AppStoreMacTransport(ByteView hardware6, ByteView dp_info88);
    APPLE_AUTH_EXPORT ~AppStoreMacTransport();
    APPLE_AUTH_EXPORT AppStoreMacTransport(AppStoreMacTransport&&) noexcept;
    APPLE_AUTH_EXPORT AppStoreMacTransport& operator=(AppStoreMacTransport&&) noexcept;
    AppStoreMacTransport(const AppStoreMacTransport&) = delete;
    AppStoreMacTransport& operator=(const AppStoreMacTransport&) = delete;
    APPLE_AUTH_EXPORT void decrypt_chunk(std::span<std::uint8_t> chunk) const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace apple_auth
