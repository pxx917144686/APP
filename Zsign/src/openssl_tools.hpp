//
//  p12_password_check.hpp
//  feather
//
//  Created by HAHALOSAH on 8/6/24.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
bool p12_password_check(NSString *file, NSString *pass);
NSData * _Nullable p12_certificate_der(NSString * _Nonnull file, NSString * _Nonnull pass);
const char * _Nonnull p12_last_error(void);
NSData * _Nullable p12_certificate_der_data(const void * _Nonnull bytes, size_t length, NSString * _Nonnull pass);
void password_check_fix_WHAT_THE_FUCK(NSString *path);
void password_check_fix_WHAT_THE_FUCK_free(NSString *path);
#ifdef __cplusplus
}
#endif
