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
/// 用 OpenSSL 解析 p12，返回叶子证书的 DER。系统 SecPKCS12Import 解不了
/// PBES2/AES-256 加密的 p12（errSecDecode），这里兜底。
NSData * _Nullable p12_certificate_der(NSString * _Nonnull file, NSString * _Nonnull pass);
/// 最近一次 p12_certificate_der 失败的原因（OpenSSL 错误栈），给诊断用。
const char * _Nonnull p12_last_error(void);
/// 同 p12_certificate_der，但直接从内存解析，不落临时文件。
NSData * _Nullable p12_certificate_der_data(const void * _Nonnull bytes, size_t length, NSString * _Nonnull pass);
void password_check_fix_WHAT_THE_FUCK(NSString *path);
void password_check_fix_WHAT_THE_FUCK_free(NSString *path);
#ifdef __cplusplus
}
#endif
