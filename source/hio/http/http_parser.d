module hio.http.http_parser;

import std.experimental.logger;
import std.bitmanip;

enum http_parser_type
{
    HTTP_REQUEST,
    HTTP_RESPONSE,
    HTTP_BOTH
}

struct http_parser_settings
{
    http_cb      on_message_begin;
    http_data_cb on_url;
    http_data_cb on_status;
    http_data_cb on_header_field;
    http_data_cb on_header_value;
    http_cb      on_headers_complete;
    http_data_cb on_body;
    http_cb      on_message_complete;
    /* When on_chunk_header is called, the current chunk length is stored
    * in parser->content_length.
    */
    http_cb      on_chunk_header;
    http_cb      on_chunk_complete;
}

struct http_parser
{
    mixin(bitfields!(
        uint, "type", 2,         /* enum http_parser_type */
        uint, "flags", 8,        /* F_* values from 'flags' enum; semi-public */
        uint, "state", 7,        /* enum state from http_parser.c */
        uint, "header_state", 7, /* enum header_state from http_parser.c */
        uint, "index", 5,        /* index into current matcher */
        uint, "extra_flags", 2,
        uint, "lenient_http_headers", 1
    ));

    uint    nread;
    ulong   content_length;

    ushort http_major;
    ushort http_minor;
    mixin(bitfields!(
        uint, "status_code", 16,
        uint, "method", 8,
        uint, "http_errno", 7,
        uint, "upgrade", 1
    ));
    // uint status_code : 16; /* responses only */
    // uint method : 8;       /* requests only */
    // uint http_errno : 7;

    /* 1 = Upgrade header was present and the parser has exited because of that.
    * 0 = No upgrade header present.
    * Should be checked when http_parser_execute() returns in addition to
    * error checking.
    */
    //uint upgrade : 1;

    /** PUBLIC **/
    void *data; /* A pointer to get hook to the "connection" or "socket" object */
}
enum http_parser_url_fields {
    UF_SCHEMA           = 0
  , UF_HOST             = 1
  , UF_PORT             = 2
  , UF_PATH             = 3
  , UF_QUERY            = 4
  , UF_FRAGMENT         = 5
  , UF_USERINFO         = 6
  , UF_MAX              = 7
  }

package struct _field_data {
    ushort off;               /* Offset into buffer in which field starts */
    ushort len;               /* Length of run in buffer */
}
package struct http_parser_url {
    ushort  field_set;           /* Bitmask of (1 << UF_*) values */
    ushort  port;                /* Converted UF_PORT string */

    _field_data[http_parser_url_fields.UF_MAX]
            field_data;
}

package extern(C)
{
    alias http_data_cb = int function(http_parser*, const char *at, size_t length);
    alias http_cb = int function(http_parser*);
    ///
    void http_parser_init(http_parser *parser, http_parser_type type) @trusted;
    size_t http_parser_execute(http_parser *parser,
                            const http_parser_settings *settings,
                            const char *data,
                            size_t len);
    /* Initialize all http_parser_url members to 0 */
    void http_parser_url_init(http_parser_url *u);

    /* Parse a URL; return nonzero on failure */
    int http_parser_parse_url(const char *buf, size_t buflen,
                            int is_connect,
                            http_parser_url *u);
}

unittest
{
    info("Test http_parser basics");
    http_parser parser;
    http_parser_settings settings;
    http_parser_init(&parser, http_parser_type.HTTP_REQUEST);
    auto data0 = "GET / HTTP/1.0\nConnect";
    auto data1 = "ion: close\n\n";
    auto r = http_parser_execute(&parser, &settings, data0.ptr, data0.length);
    assert(r == data0.length);
    r = http_parser_execute(&parser, &settings, data1.ptr, data1.length);
    assert(r == data1.length);
    assert(parser.http_errno == 0);
    assert(parser.http_major == 1);
    assert(parser.http_minor == 0);
}

unittest
{
    import std.stdio;
    info("Test http_parser callbacks");
    static bool
        message_begin,
        message_complete,
        headers_complete;
    http_cb on_message_begin = (http_parser* parser)
    {
        message_begin = true;
        return 0;
    };
    http_cb on_message_complete = (http_parser* parser)
    {
        message_complete = true;
        return 0;
    };
    http_cb on_headers_complete = (http_parser* parser)
    {
        headers_complete = true;
        writeln("headers complete");
        return 0;
    };
    http_data_cb on_header_field = (http_parser* parser, const char* at, size_t length)
    {
        writefln("HeaderField: <%s>", at[0..length]);
        return 0;
    };
    http_data_cb on_header_value = (http_parser* parser, const char* at, size_t length)
    {
        writefln("HeaderValue: <%s>", at[0..length]);
        return 0;
    };
    http_parser parser;
    http_parser_settings settings;
    settings.on_message_begin = on_message_begin;
    settings.on_message_complete = on_message_complete;
    settings.on_headers_complete = on_headers_complete;
    settings.on_header_field = on_header_field;
    settings.on_header_value = on_header_value;
    http_parser_init(&parser, http_parser_type.HTTP_REQUEST);
    auto data0 = "GET / HTTP/1.0\nConnecti";
    auto data1 = "on: close\nX: Y\n Z\n\n";
    auto r = http_parser_execute(&parser, &settings, data0.ptr, data0.length);
    r = http_parser_execute(&parser, &settings, data1.ptr, data1.length);
    http_parser_execute(&parser, &settings, null, 0);
    assert(message_begin);
    assert(headers_complete);
    assert(message_complete);
}