
#ifndef APPLE_AUTH_CLIENT_EXPORT_H
#define APPLE_AUTH_CLIENT_EXPORT_H

#ifdef APPLE_AUTH_CLIENT_STATIC_DEFINE
#  define APPLE_AUTH_CLIENT_EXPORT
#  define APPLE_AUTH_CLIENT_NO_EXPORT
#else
#  ifndef APPLE_AUTH_CLIENT_EXPORT
#    ifdef apple_auth_client_EXPORTS
        /* We are building this library */
#      define APPLE_AUTH_CLIENT_EXPORT 
#    else
        /* We are using this library */
#      define APPLE_AUTH_CLIENT_EXPORT 
#    endif
#  endif

#  ifndef APPLE_AUTH_CLIENT_NO_EXPORT
#    define APPLE_AUTH_CLIENT_NO_EXPORT 
#  endif
#endif

#ifndef APPLE_AUTH_CLIENT_DEPRECATED
#  define APPLE_AUTH_CLIENT_DEPRECATED __attribute__ ((__deprecated__))
#endif

#ifndef APPLE_AUTH_CLIENT_DEPRECATED_EXPORT
#  define APPLE_AUTH_CLIENT_DEPRECATED_EXPORT APPLE_AUTH_CLIENT_EXPORT APPLE_AUTH_CLIENT_DEPRECATED
#endif

#ifndef APPLE_AUTH_CLIENT_DEPRECATED_NO_EXPORT
#  define APPLE_AUTH_CLIENT_DEPRECATED_NO_EXPORT APPLE_AUTH_CLIENT_NO_EXPORT APPLE_AUTH_CLIENT_DEPRECATED
#endif

/* NOLINTNEXTLINE(readability-avoid-unconditional-preprocessor-if) */
#if 0 /* DEFINE_NO_DEPRECATED */
#  ifndef APPLE_AUTH_CLIENT_NO_DEPRECATED
#    define APPLE_AUTH_CLIENT_NO_DEPRECATED
#  endif
#endif

#endif /* APPLE_AUTH_CLIENT_EXPORT_H */
