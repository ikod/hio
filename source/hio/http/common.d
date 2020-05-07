module hio.http.common;

import std.string;
import std.bitmanip;
import std.uni;

import std.experimental.logger;

import ikod.containers.compressedlist: CompressedList;
import nbuff: SmartPtr, Nbuff, smart_ptr;

import hio.http.http_parser;

package enum SchCode
{
    HTTP = 0,
    HTTPS = 1,
    UNKNOWN
}

struct URL
{
    private
    {
        SchCode _schemaCode = SchCode.UNKNOWN;
        string _url;
        string _schema;
        string _host;
        ushort _port;
        string _path;
        string _query;
        string _fragment;
        string _userinfo;
        long   _path_off = -1;
    }
    auto url() pure inout @nogc
    {
        return _url;
    }
    auto schema() pure inout @nogc
    {
        return _schema;
    }
    auto host() pure inout @nogc
    {
        return _host;
    }
    auto port() pure inout @nogc
    {
        return _port;
    }
    auto path() pure inout @nogc
    {
        return _path;
    }
    long path_off() pure inout @safe @nogc
    {
        return _path_off;
    }
    auto query() pure inout @nogc
    {
        return _query;
    }
    auto fragment() pure inout @nogc
    {
        return _fragment;
    }
    auto userinfo() pure inout @nogc
    {
        return _userinfo;
    }
    auto schemaCode() pure inout @nogc
    {
        return _schemaCode;
    }
    long pstrlen() @safe @nogc nothrow
    {
        // build path/query/frag lengh
        long l = 0;
        if ( _path.length == 0)
        {
            l += 1;
        }
        else
        {
            l += _path.length;
        }
        if ( _query.length > 0 )
        {
            l += 1 + _query.length;
        }
        if ( _fragment.length > 0)
        {
            l += 1 + _fragment.length;
        }
        return l;
    }
}

URL parse_url(string url)
{
    URL             result;
    http_parser_url parser;

    result._url = url;
    http_parser_url_init(&parser);
    auto l = http_parser_parse_url(url.ptr, url.length, 0, &parser);
    if ( l )
    {
        return result;
    }
    if ( (1<<http_parser_url_fields.UF_PORT) & parser.field_set )
    {
        result._port = parser.port;
    }
    if ( (1<<http_parser_url_fields.UF_SCHEMA) & parser.field_set )
    {
        auto off = parser.field_data[http_parser_url_fields.UF_SCHEMA].off;
        auto len = parser.field_data[http_parser_url_fields.UF_SCHEMA].len;
        if ( off>=0 && len>=0 && off+len <= url.length )
        {
            result._schema = url[off..off+len];
            if (result._schema.toLower == "http")
            {
                result._schemaCode = SchCode.HTTP;
                if ( !result._port )
                {
                    result._port = 80;
                }
            }
            else if (result._schema.toLower == "https")
            {
                result._schemaCode = SchCode.HTTP;
                if ( !result._port )
                {
                    result._port = 443;
                }
            }
        }
    }
    if ( (1<<http_parser_url_fields.UF_HOST) & parser.field_set )
    {
        auto off = parser.field_data[http_parser_url_fields.UF_HOST].off;
        auto len = parser.field_data[http_parser_url_fields.UF_HOST].len;
        if ( off>=0 && len>=0 && off+len <= url.length )
        {
            result._host = url[off..off+len];
        }
    }
    if ( (1<<http_parser_url_fields.UF_PATH) & parser.field_set )
    {
        auto off = parser.field_data[http_parser_url_fields.UF_PATH].off;
        auto len = parser.field_data[http_parser_url_fields.UF_PATH].len;
        if ( off>=0 && len>=0 && off+len <= url.length )
        {
            result._path = url[off..off+len];
        }
        result._path_off = off;
    }
    if ( (1<<http_parser_url_fields.UF_QUERY) & parser.field_set )
    {
        auto off = parser.field_data[http_parser_url_fields.UF_QUERY].off;
        auto len = parser.field_data[http_parser_url_fields.UF_QUERY].len;
        if ( off>=0 && len>=0 && off+len <= url.length )
        {
            result._query = url[off..off+len];
        }
    }
    if ( (1<<http_parser_url_fields.UF_FRAGMENT) & parser.field_set )
    {
        auto off = parser.field_data[http_parser_url_fields.UF_FRAGMENT].off;
        auto len = parser.field_data[http_parser_url_fields.UF_FRAGMENT].len;
        if ( off>=0 && len>=0 && off+len <= url.length )
        {
            result._fragment = url[off..off+len];
        }
    }
    if ( (1<<http_parser_url_fields.UF_USERINFO) & parser.field_set )
    {
        auto off = parser.field_data[http_parser_url_fields.UF_USERINFO].off;
        auto len = parser.field_data[http_parser_url_fields.UF_USERINFO].len;
        if ( off>=0 && len>=0 && off+len <= url.length )
        {
            result._userinfo = url[off..off+len];
        }
    }
    debug(hiohttp) tracef("url_parser: %s", parser);
    return result;
}

unittest
{
    URL u = parse_url("http://example.com/");
    assert(u._schema == "http");
    assert(u._host == "example.com");
    assert(u._path == "/");
    assert(u.port == 80);
    u =parse_url("https://a:b@example.com/path?query#frag");
    assert(u._schema == "https");
    assert(u._host == "example.com");
    assert(u._path == "/path");
    assert(u._query == "query");
    assert(u._fragment == "frag");
    assert(u._userinfo == "a:b");
    assert(u.port == 443);
}

struct Header
{
    string  FieldName;
    string  FieldValue;
}

struct Method
{
    private string _name;
    string  name() @safe @nogc nothrow
    {
        return _name;
    }
}

struct _UH {
    // flags for each important header, added by user using addHeaders
    mixin(bitfields!(
    bool, "Host", 1,
    bool, "UserAgent", 1,
    bool, "ContentLength", 1,
    bool, "Connection", 1,
    bool, "AcceptEncoding", 1,
    bool, "ContentType", 1,
    bool, "Cookie", 1,
    uint, "", 1
    ));
}

package struct Request
{
    private
    {
        Method                  _method;
        CompressedList!Header   _user_headers;
        _UH                     _user_headers_flags;
        Nbuff                   _body;
    }
    ~this()
    {
        clear();
    }
    this(Method m)
    {
        _method = m;
    }
    void method(string m) @safe @nogc nothrow
    {
        _method = Method(m);
    }
    void method(Method m) @safe @nogc nothrow
    {
        _method = m;
    }
    string method() @safe @nogc nothrow
    {
        return _method.name;
    }
    void addHeader(Header h) @safe @nogc nothrow
    {
        if (icmp(h.FieldName, "host")==0)
        {
            _user_headers_flags.Host = true;
        }
        else
        if (icmp(h.FieldName, "useragent")==0)
        {
            _user_headers_flags.UserAgent = true;
        }
        _user_headers.insertBack(h);
    }
    auto user_headers() @safe @nogc nothrow
    {
        return _user_headers;
    }
    auto user_headers_flags() @safe @nogc nothrow
    {
        return _user_headers_flags;
    }
    void clear()
    {
        _user_headers.clear;
    }
}
// alias Request = SmartPtr!_Request;

ushort standard_port(string schema) @safe
{
    switch(schema)
    {
        case "http":
            return 80;
        case "https":
            return 443;
        default:
            return 0;
    }
}