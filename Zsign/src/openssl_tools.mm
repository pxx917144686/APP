//
//  p12_password_check.cpp
//  feather
//
//  Created by HAHALOSAH on 8/6/24.
//

#include "openssl_tools.hpp"
#include "common.h"

#include <openssl/pem.h>
#include <openssl/cms.h>
#include <openssl/err.h>
#include <openssl/provider.h>
#include <openssl/pkcs12.h>
#include <openssl/conf.h>
#include <openssl/evp.h>
#include <openssl/x509.h>

#include <string>

using namespace std;

static char g_p12_error[512] = {0};

static void p12_record_error(const char *stage) {
	unsigned long code = ERR_get_error();
	char detail[256] = {0};
	if (code) {
		ERR_error_string_n(code, detail, sizeof detail);
	}
	snprintf(g_p12_error, sizeof g_p12_error, "%s: %s", stage, code ? detail : "no openssl error");
}

NSData *p12_certificate_der_data(const void *bytes, size_t length, NSString *pass) {
	g_p12_error[0] = '\0';
	if (!bytes || length == 0) {
		p12_record_error("empty p12 data");
		return nil;
	}

	BIO *bio = BIO_new_mem_buf(bytes, (int)length);
	if (!bio) {
		p12_record_error("BIO_new_mem_buf");
		return nil;
	}

	OSSL_PROVIDER_load(NULL, "default");
	OSSL_PROVIDER_load(NULL, "legacy");

	PKCS12 *p12 = d2i_PKCS12_bio(bio, NULL);
	BIO_free(bio);
	if (!p12) {
		p12_record_error("d2i_PKCS12_bio");
		return nil;
	}

	EVP_PKEY *pkey = NULL;
	X509 *cert = NULL;
	STACK_OF(X509) *ca = NULL;
	NSData *result = nil;

	int parsed = PKCS12_parse(p12, [pass UTF8String], &pkey, &cert, &ca);
	if (!parsed) {
		p12_record_error("PKCS12_parse");
	} else if (!cert) {
		p12_record_error("PKCS12_parse returned no certificate");
	}
	if (parsed && cert) {
		unsigned char *der = NULL;
		int len = i2d_X509(cert, &der);
		if (len > 0 && der) {
			result = [NSData dataWithBytes:der length:(NSUInteger)len];
			OPENSSL_free(der);
		}
	}

	if (cert) X509_free(cert);
	if (pkey) EVP_PKEY_free(pkey);
	if (ca) sk_X509_pop_free(ca, X509_free);
	PKCS12_free(p12);
	return result;
}

const char *p12_last_error(void) {
	return g_p12_error;
}

NSData *p12_certificate_der(NSString *file, NSString *pass) {
	g_p12_error[0] = '\0';

	BIO *bio = BIO_new_file([file fileSystemRepresentation], "rb");
	if (!bio) {
		p12_record_error("BIO_new_file");
		return nil;
	}

	OSSL_PROVIDER_load(NULL, "default");
	OSSL_PROVIDER_load(NULL, "legacy");
	PKCS12 *p12 = d2i_PKCS12_bio(bio, NULL);
	BIO_free(bio);
	if (!p12) {
		p12_record_error("d2i_PKCS12_bio");
		return nil;
	}

	EVP_PKEY *pkey = NULL;
	X509 *cert = NULL;
	STACK_OF(X509) *ca = NULL;
	NSData *result = nil;

	int parsed = PKCS12_parse(p12, [pass UTF8String], &pkey, &cert, &ca);
	if (!parsed) {
		p12_record_error("PKCS12_parse");
	} else if (!cert) {
		p12_record_error("PKCS12_parse returned no certificate");
	}
	if (parsed && cert) {
		unsigned char *der = NULL;
		int len = i2d_X509(cert, &der);
		if (len > 0 && der) {
			result = [NSData dataWithBytes:der length:(NSUInteger)len];
			OPENSSL_free(der);
		}
	}

	if (cert) X509_free(cert);
	if (pkey) EVP_PKEY_free(pkey);
	if (ca) sk_X509_pop_free(ca, X509_free);
	PKCS12_free(p12);
	return result;
}

bool p12_password_check(NSString *file, NSString *pass) {
	const std::string strFile = [file cStringUsingEncoding:NSUTF8StringEncoding];
	const std::string strPass = [pass cStringUsingEncoding:NSUTF8StringEncoding];
	
	BIO *bio = BIO_new_file(strFile.c_str(), "rb");
	if (!bio) {
		NSLog(@"Failed to open .p12 file");
		return false;
	}
	
	OSSL_PROVIDER_load(NULL, "legacy");
	
	PKCS12 *p12 = d2i_PKCS12_bio(bio, NULL);
	BIO_free(bio);
	
	if (!p12) {
		NSLog(@"Failed to parse PKCS12");
		return false;
	}
	
	if( PKCS12_verify_mac(p12, NULL, 0) ) {
		return true;
	} else if( PKCS12_verify_mac(p12, strPass.c_str(), -1) ) {
		return true;
	} else {
		return false;
	}
	
	PKCS12_free(p12);
	return false;
}

// This is fucking bullshit IMO.
//
// In total, I probably wasted a total of 1.5 hours on this
// Feel free to increment the counter until someone finds a proper fix
//
// hours_wasted = 1.5
//
// TODO: FIX
void password_check_fix_WHAT_THE_FUCK(NSString *path) {
	string strProvisionFile = [path cStringUsingEncoding:NSUTF8StringEncoding];
	string strProvisionData;
	ZFile::ReadFile(strProvisionFile.c_str(), strProvisionData);
	
	BIO *in = BIO_new(BIO_s_mem());
	OPENSSL_assert((size_t)BIO_write(in, strProvisionData.data(), (int)strProvisionData.size()) == strProvisionData.size());
	d2i_CMS_bio(in, NULL);
}

void password_check_fix_WHAT_THE_FUCK_free(NSString *path) {
	string strProvisionFile = [path cStringUsingEncoding:NSUTF8StringEncoding];
	string strProvisionData;
	ZFile::ReadFile(strProvisionFile.c_str(), strProvisionData);
	
	BIO *in = BIO_new(BIO_s_mem());
	if (!in) return;
	
	if ((size_t)BIO_write(in, strProvisionData.data(), (int)strProvisionData.size()) != strProvisionData.size()) {
		BIO_free(in);
		return;
	}
	
	CMS_ContentInfo *cms = d2i_CMS_bio(in, NULL);
	if (cms) CMS_ContentInfo_free(cms);
	// free my boy
	BIO_free(in);
}
