#pragma once
#include <apple_auth/core.hpp>

namespace apple_auth {

// Storage encryption is independent of Apple protocols. Keys are exactly 32 raw bytes.
inline constexpr std::size_t session_key_size = 32;
inline constexpr std::size_t session_encryption_overhead = 37;
APPLE_AUTH_EXPORT Bytes generate_session_key();
APPLE_AUTH_EXPORT Bytes encrypt_session(ByteView plaintext, ByteView key);
APPLE_AUTH_EXPORT Bytes decrypt_session(ByteView encrypted, ByteView key);

} // namespace apple_auth
