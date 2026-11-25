#pragma once

#include <apple_auth/core.hpp>

namespace apple_auth {

// GrandSlam SRP-6a without HTTP, JSON or plist dependencies.
class SrpHandshake {
  public:
    struct Proof {
        Bytes m1, m2, key;
        APPLE_AUTH_EXPORT void verify(ByteView reply) const;
        APPLE_AUTH_EXPORT Bytes decrypt_session(ByteView server_proof, ByteView encrypted) const;
        APPLE_AUTH_EXPORT ~Proof();
    };

    // Empty selects secure randomness; explicit secrets are for protocol tests.
    APPLE_AUTH_EXPORT explicit SrpHandshake(Bytes secret = {});
    APPLE_AUTH_EXPORT ~SrpHandshake();
    SrpHandshake(const SrpHandshake&) = delete;
    SrpHandshake& operator=(const SrpHandshake&) = delete;
    APPLE_AUTH_EXPORT Bytes public_key() const;
    APPLE_AUTH_EXPORT Proof complete(const std::string& user,
                                    const std::string& password,
                                    ByteView salt,
                                    ByteView server,
                                    int iterations,
                                    const std::string& protocol) const;

  private:
    Bytes secret_;
};

} // namespace apple_auth
