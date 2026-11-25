#pragma once

#include <apple_auth/export.h>

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace apple_auth {

using Bytes = std::vector<std::uint8_t>;
using ByteView = std::span<const std::uint8_t>;
using Block = std::array<std::uint8_t, 16>;
using HardwareId = std::array<std::uint8_t, 20>;
using MachineId = std::array<std::uint8_t, 60>;

enum class ErrorCode {
    invalid_argument = 1,
    invalid_data,
    buffer_too_small,
    network,
    authentication,
    internal,
    unsupported
};

class Error : public std::runtime_error {
  public:
    APPLE_AUTH_EXPORT Error(ErrorCode code, std::string message);
    APPLE_AUTH_EXPORT ErrorCode code() const noexcept;

  private:
    ErrorCode code_;
};

enum class ProfileKind {
    store = -1,
    grandslam = -2
};

enum class ProfilePlatform : std::uint32_t {
    mac = 1, // Shared by Mac and iPhone device profiles.
    windows = 2,
    android = 4
};

struct HardwareFields {
    std::optional<std::uint32_t> volume_serial;
    std::optional<ByteView> bios;
    std::optional<ByteView> processor;
};

// Registry byte strings include their original terminators. Missing and empty differ.
APPLE_AUTH_EXPORT HardwareId hardware_id(const HardwareFields& fields);
APPLE_AUTH_EXPORT HardwareId local_hardware_id();
APPLE_AUTH_EXPORT std::uint32_t time_counter(std::int64_t unix_seconds);
APPLE_AUTH_EXPORT std::string base64(ByteView bytes);
APPLE_AUTH_EXPORT const char* version() noexcept;

struct FileEncoding {
    std::uint32_t version = 3;
    Bytes prefix;
    Block iv{};

    APPLE_AUTH_EXPORT static FileEncoding random();
};

// Immutable authenticated profile; copies and concurrent OTP generation are safe.
class Profile {
  public:
    APPLE_AUTH_EXPORT static Profile
    import_file(ByteView file, const HardwareId& hardware, std::string_view filename);
    APPLE_AUTH_EXPORT ProfileKind kind() const noexcept;
    APPLE_AUTH_EXPORT ProfilePlatform platform() const noexcept;
    APPLE_AUTH_EXPORT MachineId machine_id() const noexcept;
    APPLE_AUTH_EXPORT Block otp(std::uint32_t counter) const;
    APPLE_AUTH_EXPORT Bytes otp_envelope(std::uint32_t counter) const;
    APPLE_AUTH_EXPORT std::string otp_header(std::uint32_t counter) const;
    APPLE_AUTH_EXPORT std::string machine_id_header() const;
    // Canonical name; keep different profile kinds in separate directories.
    APPLE_AUTH_EXPORT std::string_view filename() const noexcept;
    APPLE_AUTH_EXPORT Bytes
    export_file(const HardwareId& hardware,
                std::string_view filename,
                const FileEncoding& encoding = FileEncoding::random()) const;

  private:
    struct Impl;
    std::shared_ptr<const Impl> impl_;
    explicit Profile(std::shared_ptr<const Impl> impl);
    friend class ProvisioningSession;
};

struct ProvisioningEntropy {
    Bytes selector;
    std::array<std::uint8_t, 84> body{};
    Block nonce{};

    APPLE_AUTH_EXPORT static ProvisioningEntropy random();
};

struct SapEntropy {
    // AES/HMAC keys: 36 bytes; OAEP seed: 20; loader key, nonce and IV: 16 each.
    std::array<std::uint8_t, 104> initial{};
    std::array<std::uint8_t, 33> profile{};
    // macOS SAP1 certificate generation uses 78 nonzero bytes.
    std::array<std::uint8_t, 78> certificate{};
    APPLE_AUTH_EXPORT static SapEntropy random();
};

enum class SapPlatform : std::uint32_t { macos = 1, android = 66 };

// SAP 200. The caller supplies the certificate and setup reply over HTTPS.
class SapSession {
  public:
    APPLE_AUTH_EXPORT explicit SapSession(ByteView certificate,
                                          const SapEntropy& entropy = SapEntropy::random());
    APPLE_AUTH_EXPORT SapSession(ByteView certificate,
                                 SapPlatform platform,
                                 const SapEntropy& entropy = SapEntropy::random());
    APPLE_AUTH_EXPORT ~SapSession();
    APPLE_AUTH_EXPORT SapSession(SapSession&&) noexcept;
    APPLE_AUTH_EXPORT SapSession& operator=(SapSession&&) noexcept;
    SapSession(const SapSession&) = delete;
    SapSession& operator=(const SapSession&) = delete;
    APPLE_AUTH_EXPORT ByteView request() const noexcept;
    APPLE_AUTH_EXPORT void finish(ByteView reply);
    APPLE_AUTH_EXPORT bool ready() const noexcept;
    APPLE_AUTH_EXPORT Bytes sign(ByteView body) const;
    APPLE_AUTH_EXPORT Bytes sign(ByteView body, const Block& nonce) const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// One version-4 SPIM/CPIM/PTM exchange. The caller owns HTTP and the clock.
// A failed finish can be retried.
class ProvisioningSession {
  public:
    APPLE_AUTH_EXPORT
    ProvisioningSession(ByteView challenge,
                        const HardwareId& hardware,
                        std::uint32_t unix_seconds,
                        const ProvisioningEntropy& entropy = ProvisioningEntropy::random());
    APPLE_AUTH_EXPORT
    ProvisioningSession(ByteView challenge,
                        const HardwareId& hardware,
                        std::uint32_t unix_seconds,
                        ProfileKind kind,
                        const ProvisioningEntropy& entropy = ProvisioningEntropy::random());
    APPLE_AUTH_EXPORT
    ProvisioningSession(ByteView challenge,
                        const HardwareId& hardware,
                        std::uint32_t unix_seconds,
                        ProfilePlatform platform,
                        const ProvisioningEntropy& entropy = ProvisioningEntropy::random());
    APPLE_AUTH_EXPORT ~ProvisioningSession();
    APPLE_AUTH_EXPORT ProvisioningSession(ProvisioningSession&&) noexcept;
    APPLE_AUTH_EXPORT ProvisioningSession& operator=(ProvisioningSession&&) noexcept;
    ProvisioningSession(const ProvisioningSession&) = delete;
    ProvisioningSession& operator=(const ProvisioningSession&) = delete;
    APPLE_AUTH_EXPORT ByteView request() const noexcept;
    APPLE_AUTH_EXPORT Profile finish(ByteView ptm, const Block& trust_key);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace apple_auth
