module hio.tls.openssl;

version(openssl11):
//
shared static this()
{
    init_ssl_library();
}

import std.experimental.logger;
import hio.tls.common;

/+
# define SSL_ERROR_NONE                  0
# define SSL_ERROR_SSL                   1
# define SSL_ERROR_WANT_READ             2
# define SSL_ERROR_WANT_WRITE            3
# define SSL_ERROR_WANT_X509_LOOKUP      4
# define SSL_ERROR_SYSCALL               5/* look at error stack/return
                                           * value/errno */
# define SSL_ERROR_ZERO_RETURN           6
# define SSL_ERROR_WANT_CONNECT          7
# define SSL_ERROR_WANT_ACCEPT           8
# define SSL_ERROR_WANT_ASYNC            9
# define SSL_ERROR_WANT_ASYNC_JOB       10
# define SSL_ERROR_WANT_CLIENT_HELLO_CB 11
+/

package enum {
    SSL_ERROR_NONE = 0,
    SSL_ERROR_SSL = 1,
    SSL_ERROR_WANT_READ = 2,
    SSL_ERROR_WANT_WRITE = 3,
    SSL_ERROR_WANT_X509_LOOKUP = 4,
    SSL_ERROR_SYSCALL = 5, /* look at error stack/return
                                            * value/errno */
    SSL_ERROR_ZERO_RETURN = 6,
    SSL_ERROR_WANT_CONNECT = 7,
    SSL_ERROR_WANT_ACCEPT = 8,
    SSL_ERROR_WANT_ASYNC = 9,
    SSL_ERROR_WANT_ASYNC_JOB = 10,
    SSL_ERROR_WANT_CLIENT_HELLO_CB = 11
}

immutable SSL_error_strings = [
    "SSL_ERROR_NONE",
    "SSL_ERROR_SSL",
    "SSL_ERROR_WANT_READ",
    "SSL_ERROR_WANT_WRITE",
    "SSL_ERROR_WANT_X509_LOOKUP",
    "SSL_ERROR_SYSCALL",
    "SSL_ERROR_ZERO_RETURN",
    "SSL_ERROR_WANT_CONNECT",
    "SSL_ERROR_WANT_ACCEPT",
    "SSL_ERROR_WANT_ASYNC",
    "SSL_ERROR_WANT_ASYNC_JOB",
    "SSL_ERROR_WANT_CLIENT_HELLO_CB"
];

package struct SSL {}
package struct SSL_CTX {}
package struct SSL_METHOD {}

package extern(C)
{
    int         OPENSSL_init_ssl(ulong, void*) @trusted nothrow;
    int         OPENSSL_init_crypto(ulong, void*) @trusted nothrow;
    SSL_METHOD* TLS_method() @trusted nothrow;
    SSL_METHOD* TLS_client_method() @trusted nothrow;
    SSL_CTX*    SSL_CTX_new(SSL_METHOD*) @trusted nothrow;
    void        SSL_CTX_free(SSL_CTX*) @trusted nothrow;
    SSL*        SSL_new(SSL_CTX*) @trusted nothrow;
    int         SSL_set_fd(SSL*, int) @trusted nothrow;
    int         SSL_connect(SSL*) @trusted nothrow;
    int         SSL_get_error(SSL*, int) @trusted nothrow;
    long        SSL_ctrl(SSL*, int, long, void*) @trusted nothrow;
    void        SSL_set_connect_state(SSL*) @trusted nothrow;
    void        SSL_set_accept_state(SSL*) @trusted nothrow;
    int         SSL_read(SSL*, void *, int) @trusted nothrow;
    int         SSL_write(SSL*, void*, int) @trusted nothrow;
    void        SSL_free(SSL*) @trusted nothrow;
    char*       ERR_reason_error_string(ulong) @trusted nothrow;
    char*       ERR_error_string(ulong, char*) @trusted nothrow;
    ulong       ERR_get_error() @trusted nothrow;
}

void init_ssl_library()
{
        /**
        Standard initialisation options

        #define OPENSSL_INIT_LOAD_SSL_STRINGS       0x00200000L

        # define OPENSSL_INIT_LOAD_CRYPTO_STRINGS    0x00000002L
        # define OPENSSL_INIT_ADD_ALL_CIPHERS        0x00000004L
        # define OPENSSL_INIT_ADD_ALL_DIGESTS        0x00000008L
        **/
        enum OPENSSL_INIT_LOAD_SSL_STRINGS = 0x00200000L;
        enum OPENSSL_INIT_LOAD_CRYPTO_STRINGS = 0x00000002L;
        enum OPENSSL_INIT_ADD_ALL_CIPHERS = 0x00000004L;
        enum OPENSSL_INIT_ADD_ALL_DIGESTS = 0x00000008L;
        OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS, null);
        OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);
}
