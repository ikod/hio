module hio.http.client;

import std.experimental.logger;
import std.socket;
import std.string;
import std.datetime;
import std.algorithm.mutation: copy;
import std.exception;

import hio.socket;
import hio.resolver;
import hio.loop;

import hio.http.common;
import hio.http.http_parser;

import ikod.containers.hashmap;
import ikod.containers.compressedlist;

import nbuff: Nbuff, NbuffChunk, SmartPtr;

AsyncSocketLike socketFabric(URL url) @safe
{
    if ( url.schemaCode == SchCode.HTTP )
    {
        auto s = new hlSocket();
        s.open();
        return s;
    }
    assert(0);
}

package struct ConnectionTriple
{
    string  schema;
    string  host;
    ushort  port;
}

// handle all logics like: proxy, redirects, connection pool,...
struct AsyncHTTPClient
{
    private
    {
        HashMap!(ConnectionTriple, AsyncSocketLike) _conn_pool;
        void delegate(AsyncHTTPResult) @safe        _callback;
        AsyncSocketLike function(URL) @safe         _conn_factory = &socketFabric;
        AsyncHTTP                                   _handler;
        Duration                                    _connect_timeout = 5.seconds;
        Duration                                    _send_timeout = 5.seconds;
        Duration                                    _receive_timeout = 5.seconds;
        //
        hlEvLoop                                    _loop;
        // lifetime - request
        Request                                     _request; // request headers, body, etc
        URL                                         _url;
        AsyncSocketLike                             _connection;
        InternetAddress[]                           _endpoints;
        int                                         _buffer_size = 16*1024;
    }
    ~this()
    {
        if ( _connection )
        {
            _connection.close();
        }
    }
    private bool use_proxy() @safe
    {
        return false;
    }
    private void _http_handler_call(AsyncSocketLike c) @safe
    {
        assert(_handler._state == AsyncHTTP.State.INIT);
        _handler._connection = _connection;
        _handler._callback = (AsyncHTTPResult r) @safe {
            //debug(hiohttp) tracef("handler_callback %s", r);
            _callback(r);
        };
        _handler.execute();
    }
    private void _connect_callback(AppEvent e) @safe
    {
        if ( _connection is null )
        {
            debug(hiohttp) tracef("connect_callback on closed connection, you probably closed it already?");
            return;
        }
        debug(hiohttp) tracef("connect_callback %s", e);
        if ( _connection.connected )
        {
            _http_handler_call(_connection);
        }
        else
        {
            // retry with next address if possible
            if ( _endpoints.length > 0)
            {
                _connection.close();
                _connection = _conn_factory(_url);
                _connect_call();
            }
            else
            {
                // no more endpoints to connect
                AsyncHTTPResult r;
                _callback(r);
            }
        }
    }
    private void _connect_call() @safe
    {
        // connect to first endpoint
        auto endpoint = _endpoints[0];
        _endpoints = _endpoints[1..$];
        _connection.connect(endpoint, _loop, &_connect_callback, _connect_timeout);
    }

    private void _resolver_call(URL url)
    {
        debug(hiohttp) tracef("resolve %s", url);
        hio_gethostbyname(url.host, &_resolver_callback, url.port);
    }
    private void _resolver_callback(int status, InternetAddress[] addresses) @safe
    {
        debug(hiohttp) tracef("resolve calback");
        _endpoints = addresses;
        _connect_call();
    }

    /// build request line.
    /// Take proxy into account. 
    private NbuffChunk _build_request_line() @trusted
    {
        if (!use_proxy)
        {
            ulong ml = _request.method.length;
            auto pqs = _url.path_off >= 0 ? _url.url[_url.path_off..$] : "/";
            ulong pl = pqs.length;
            auto q = Nbuff.get(ml + 1 + pl + 10);
            copy(_request.method, q.data[0 .. ml]);
            copy(" ".representation, q.data[ml .. ml+1]);
            copy(pqs.representation, q.data[ml+1..ml+1+pl]);
            copy(" HTTP/1.1\n".representation, q.data[ml+1+pl..ml + 1 + pl + 10]);
            debug(hiohttp) tracef("rq_line");
            return NbuffChunk(q, ml + 1 + pl + 10);
        }
        else
        {
            assert(0);
        }
    }
    /// build all headers based on reuest url, headers, etc.
    private Nbuff _build_request_header() @safe
    {
        Nbuff message_header;
        auto request_line = _build_request_line();
        message_header.append(request_line);
        if ( !_request.user_headers_flags.Host )
        {
            message_header.append("Host: ");
            if ( _url.port == standard_port(_url.schema) )
            {
                message_header.append(_url.host);
            }
            else
            {
                message_header.append(_url.host ~ ":%d".format(_url.port));
            }
            message_header.append("\n");
        }
        if (!_request.user_headers_flags.UserAgent)
        {
            message_header.append("UserAgent: hio\n");
        }
        foreach (ref h; _request.user_headers)
        {
            message_header.append(h.FieldName);
            message_header.append(": ");
            message_header.append(h.FieldValue);
            message_header.append("\n");
        }
        message_header.append("\n");
        return message_header;
    }
    void execute(Method method, URL url, void delegate(AsyncHTTPResult) @safe callback)
    {
        enforce(_connection is null, "You can't reenter this");
        _loop = getDefaultLoop();
        _url = url;
        _request.method = method;

        _callback = callback;
        _handler._client = &this;

        // reset resolving
        _endpoints.length = 0;

        auto f = _conn_pool.fetch(ConnectionTriple(url.schema, url.host, url.port));
        if (f.ok)
        {
            _connection = f.value;
        }
        else
        {
            _connection = _conn_factory(url);
        }

        if ( _connection.connected )
        {
            _http_handler_call(_connection);
        }
        else
        {
            // resolve, connect and then call handler
            _resolver_call(url);
        }
    }
}

unittest
{
    import std.stdio;
    AsyncHTTPClient c;
    c._request.method = Method("GET");
    c._url = parse_url("http://example.com:8080/path");
    auto q = c._build_request_line();
    
    assert(q == "GET /path HTTP/1.1\n".representation);

    c._request.addHeader(Header("X-header", "x-value"));
    c._request.addHeader(Header("Content-Length", "100"));

    Nbuff header = c._build_request_header();
    writeln(cast(string)header.data.data);
}
extern(C)
{
    private int on_header_field(http_parser* parser, const char* at, size_t length)
    {
        AsyncHTTP* c = cast(AsyncHTTP*)parser.data;
        assert(c._state == AsyncHTTP.State.HEADERS_RECEIVE);
        assert(c._current_buffer_length > 0);
        long position = cast(immutable(ubyte)*)at - c._current_buffer_ptr;
        debug(hiohttp) tracef("on header field in state %s", c._expected_part);
        debug(hiohttp) tracef("on header field: %d", c._offset + position);
        if (length>0)
            debug(hiohttp) tracef("on header field: %s",
                cast(string)c._response_headers[c._offset + position..c._offset + position+length].data.data);
        final switch(c._expected_part)
        {
            case AsyncHTTP.HeaderPart.Value:
                // finalize value and start next Header
                debug(hiohttp) tracef("got <%s: %s>",
                    cast(string)c._response_headers.data.data[c._field_beg..c._field_end],
                    cast(string)c._response_headers.data.data[c._value_beg..c._value_end]);
                goto case;
            case AsyncHTTP.HeaderPart.None:
                c._expected_part = AsyncHTTP.HeaderPart.Field;
                c._field_beg = c._offset + position;
                c._field_end = c._field_beg + length;
                break;
            case AsyncHTTP.HeaderPart.Field:
                // continue receiving current header
                c._field_end += length;
                break;
        }
        return 0;
    }
    private int on_header_value(http_parser* parser, const char* at, size_t length)
    {
        AsyncHTTP* c = cast(AsyncHTTP*)parser.data;
        assert(c._state == AsyncHTTP.State.HEADERS_RECEIVE);
        debug(hiohttp) tracef("on header value in state %s", c._expected_part);
        long position = cast(immutable(ubyte)*)at - c._current_buffer_ptr;
        if (length>0)
            debug(hiohttp) tracef("on header value: %s",
                cast(string)c._response_headers[c._offset + position..c._offset + position+length].data.data);
        // async_http_connection c = cast(async_http_connection)parser.data;
        // c._state = State.IDLE;
        final switch(c._expected_part)
        {
            case AsyncHTTP.HeaderPart.None:
                assert(0);
            case AsyncHTTP.HeaderPart.Value:
                c._value_end += length;
                break;
            case AsyncHTTP.HeaderPart.Field:
                // finalize header and start next value
                debug(hiohttp) tracef("got Field: %s", cast(string)c._response_headers.data.data[c._field_beg..c._field_end]);
                c._expected_part = AsyncHTTP.HeaderPart.Value;
                c._value_beg = c._offset + position;
                c._value_end = c._value_beg + length;
                break;
        }
        return 0;
    }
    private int on_body(http_parser* parser, const char* at, size_t length)
    {
        debug(hiohttp) tracef("on body");
        AsyncHTTP* c = cast(AsyncHTTP*)parser.data;
        long position = cast(immutable(ubyte)*)at - c._current_buffer_ptr;
        assert(c._state == AsyncHTTP.State.BODY_RECEIVE, "Expected state BODY_RECEIVE, got %s".format(c._state));
        c.onBody(position, length);
        return 0;
    }
    private int on_headers_complete(http_parser* parser)
    {
        debug(hiohttp) tracef("headers complete");
        AsyncHTTP* c = cast(AsyncHTTP*)parser.data;
        debug(hiohttp) tracef("got <%s: %s>",
            cast(string)c._response_headers.data.data[c._field_beg..c._field_end],
            cast(string)c._response_headers.data.data[c._value_beg..c._value_end]);
        c._state = c.onHeadersComplete();
        debug(hiohttp) tracef("next state: %s", c._state);
        return 0;
    }
    private int on_message_complete(http_parser* parser)
    {
        debug(hiohttp) tracef("message complete");
        // async_http_connection c = cast(async_http_connection)parser.data;
        // c._state = State.IDLE;
        AsyncHTTP* c = cast(AsyncHTTP*)parser.data;
        c.onBodyComplete();
        return 0;
    }
}

// handle strait forward http request-response
struct AsyncHTTP
{
    private
    {
        enum State
        {
            INIT,
            SENDING_REQUEST,
            HEADERS_RECEIVE,
            HEADERS_COMPLETED,
            BODY_RECEIVE,
            DONE,
            ERROR
        }
        enum HeaderPart
        {
            None = 0,
            Field,
            Value
        }
        State                   _state;
        AsyncSocketLike         _connection;
        void delegate(AsyncHTTPResult) @safe
                                _callback;
        http_parser             _parser;
        http_parser_settings    _parser_settings = {
                on_header_field:     &on_header_field,
                on_header_value:     &on_header_value,
                on_headers_complete: &on_headers_complete,
                on_body:             &on_body,
                on_message_complete: &on_message_complete,
        };
        AsyncHTTPClient*        _client;
        AsyncHTTPResult         _result;
        HeaderPart              _expected_part;
        size_t                  _offset;                    // offset of each socket input
        size_t                  _field_beg, _field_end;     // beg and end of headers field and value
        size_t                  _value_beg, _value_end;     // beg and end of headers field and value
        NbuffChunk              _current_input;
        immutable(ubyte)*       _current_buffer_ptr;
        size_t                  _current_buffer_length;
        Nbuff                   _response_headers;
        Nbuff                   _response_body;
    }
    ~this()
    {
        // we can destroy it only when it is idle
        assert(_state == State.INIT, "You can't destroy in %s".format(_state));
    }
    private void _receiving_response(IOResult res) @safe
    {
        assert(_state == State.HEADERS_RECEIVE || _state == State.BODY_RECEIVE);

        if (res.timedout)
        {
            onTimeout();
            return;
        }
        if ( res.error )
        {
            onError();
            return;
        }

        _current_input = res.input;

        size_t r;
        switch(_state)
        {
            case State.HEADERS_RECEIVE:
                _response_headers.append(_current_input);
                () @trusted {
                    // ptr used in http_parser_execute callback
                    _current_buffer_ptr = _current_input.data.ptr;
                    _current_buffer_length = _current_input.data.length;
                    r = http_parser_execute(&_parser, &_parser_settings, cast(char*)_current_buffer_ptr, _current_buffer_length);
                }();
                assert(r == _current_buffer_length);
                _offset += _current_buffer_length;
                _current_buffer_length = 0;
                break;
            case State.BODY_RECEIVE:
                () @trusted {
                    // ptr used in http_parser_execute callback
                    _current_buffer_ptr = _current_input.data.ptr;
                    _current_buffer_length = _current_input.data.length;
                    r = http_parser_execute(&_parser, &_parser_settings, cast(char*)_current_buffer_ptr, _current_buffer_length);
                }();
                assert(r == _current_buffer_length, "r=%d on body receive, instead of %d".format(r, _current_buffer_length));
                break;
            case State.DONE:
                break;
            default:
                assert(0);
        }
        // we processed data, what we have to do in new state
        switch(_state)
        {
            case State.BODY_RECEIVE, State.HEADERS_RECEIVE:
                IORequest iorq;
                iorq.to_read = _client._buffer_size;
                iorq.callback = &_receiving_response;
                _parser.data = &_client._handler;
                _connection.io(_client._loop, iorq, _client._receive_timeout);
                return;
            default:
                return;
        }
    }

    private void _send_request_done(IOResult res) @safe
    {
        //debug(hiohttp) tracef("result: %s", res);
        if ( res.error || res.timedout )
        {
            _state = State.ERROR;
            _callback(_result);
            return;
        }
        IORequest iorq;
        iorq.to_read = _client._buffer_size;
        iorq.callback = &_receiving_response;
        _parser.data = &_client._handler;
        _state = State.HEADERS_RECEIVE;
        _connection.io(_client._loop, iorq, _client._receive_timeout);
    }
    private void _send_request() @safe
    {
        assert(_state == State.SENDING_REQUEST);
        IORequest iorq;
        iorq.output = _client._build_request_header();
        iorq.callback = &_send_request_done;
        _connection.io(_client._loop, iorq, _client._send_timeout);
    }
    State onHeadersComplete()
    {
        debug(hiohttp) tracef("Checking headers");
        _result.status_code = _parser.status_code;
        _response_body.clear;
        return State.BODY_RECEIVE;
    }
    void onBody(long off, size_t len)
    {
        import std.stdio;
        NbuffChunk b = _current_input[off..off+len];
        _response_body.append(b);
    }
    void onBodyComplete()
    {
        debug(hiohttp) tracef("Body complete");
        _result.response_body = _response_body;
        AsyncHTTPResult result = _result;
        auto cb = _callback;
        // make cleanup
        //
        // cleanup done
        _state = State.INIT;
        cb(result);
        return;
    }
    void onTimeout() @safe
    {
        _result.status_code = -1;
        AsyncHTTPResult result = _result;
        auto cb = _callback;
        // make cleanup
        //
        // cleanup done
        _state = State.INIT;
        cb(result);
        return;
    }
    void onError() @safe
    {

    }
    void execute() @safe
    {
        assert(_connection.connected);
        assert(_state == State.INIT);
        debug(hiohttp) tracef("handling %s", _client._url);
        _state = State.SENDING_REQUEST;
        http_parser_init(&_parser, http_parser_type.HTTP_RESPONSE);
        _send_request();
    }
}

struct AsyncHTTPResult
{
    int     status_code = -1;
    Nbuff   response_body;
}

unittest
{
    import std.stdio;
    import hio.scheduler;
    import std.datetime;
    info("Test http.client");
    App({
        void callback(AsyncHTTPResult result) @safe
        {
            //infof("Client called back with result: %s", result);
            () @trusted {
                if ( result.status_code < 0 )
                {
                    writefln("<<<error>>>");
                    return;
                }
                writefln("<<<%s>>>", cast(string)result.response_body.data.data);
            }();
            getDefaultLoop.stop();
        }
        URL url = parse_url("http://httpbin.org/stream/100");
        // auto loop = getDefaultLoop();
        // Request request = Request(Method("GET"));
        // request.addHeader(Header("X-header", "X-value"));
        AsyncHTTPClient client;
        // client._connection = socketFabric(url);
        client.execute(Method("GET"), url, &callback);
        hlSleep(25.seconds);
    });
}
