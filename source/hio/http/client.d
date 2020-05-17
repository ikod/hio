module hio.http.client;

import std.experimental.logger;
import std.stdio;
import std.socket;
import std.string;
import std.datetime;
import std.algorithm.mutation: copy;
import std.exception;
import std.typecons: Tuple;
import std.uni: toLower;
import std.zlib: UnCompress, HeaderFormat;

import hio.socket;
import hio.resolver;
import hio.loop;

import hio.http.common;
import hio.http.http_parser;

import ikod.containers.hashmap: HashMap, hash_function;
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
    bool opEquals(R)(const R other) const
    {
        return schema == other.schema && port == other.port && host == other.host;
    }
    hash_t toHash() const @safe pure nothrow
    {
        return hash_function(schema) + hash_function(host) + hash_function(port);
    }
}

// handle all logics like: proxy, redirects, connection pool,...
class AsyncHTTPClient
{
    enum State
    {
        INIT,
        RESOLVING,
        CONNECTING,
        HANDLING,
        ERROR
    }
    private
    {
        State                                       _state = State.INIT;
        HashMap!(ConnectionTriple, AsyncSocketLike) _conn_pool;
        void delegate(AsyncHTTPResult) @safe        _callback;
        AsyncSocketLike function(URL) @safe         _conn_factory = &socketFabric;
        AsyncHTTP                                   _handler;
        Duration                                    _connect_timeout = 30.seconds;
        Duration                                    _send_timeout = 30.seconds;
        Duration                                    _receive_timeout = 30.seconds;
        int                                         _buffer_size = 16*1024;
        int                                         _max_redirects = 10;
        bool                                        _keep_alive = true;
        int                                         _verbosity = 0;
        //
        hlEvLoop                                    _loop;
        // lifetime - request
        Request                                     _request;       // request headers, body, etc
        URL                                         _original_url;  // save at begin
        URL                                         _current_url;   // current url - follow redirects
        AsyncSocketLike                             _connection;
        InternetAddress[]                           _endpoints;
        int                                         _redirects_counter;
    }
    ~this()
    {
        close();
    }
    void close() @safe
    {
        if ( _connection )
        {
            _connection.close();
            _connection = null;
        }
    }
    private bool use_proxy() @safe
    {
        return false;
    }

    bool redirectAllowed() pure @safe @nogc
    {
        if ( _redirects_counter < _max_redirects )
        {
            return true;
        }
        return false;
    }

    private void prepareRedirect(string location) @safe
    {
        _redirects_counter++;
        // return conn to pool
        _conn_pool[ConnectionTriple(_current_url.schema, _current_url.host, _current_url.port)] = _connection;

        debug(hiohttp) tracef("new location: %s", location);
        _current_url = parse_url(location);
        debug(hiohttp) tracef("new url: %s", _current_url);
    }
    private void _http_handler_callback(AsyncHTTPResult r) @safe
    {
        if ( r.status_code == 302)
        {
            if ( !redirectAllowed() )
            {
                debug(hiohttp) tracef("Can't follow redirect");
                r.error = AsyncHTTPErrors.MaxRedirectsReached;
                r.status_code = -1;
                _callback(r);
                return;
            }
            string location = r.getHeader("location").asString!(dup);
            prepareRedirect(location);
            _execute();
            return;
        }
        _callback(r);
    }
    private void _http_handler_call(AsyncSocketLike c) @safe
    {
        assert(_handler._state == AsyncHTTP.State.INIT);
        _handler._connection = _connection;
        _handler._callback = &_http_handler_callback;
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
                _connection = _conn_factory(_current_url);
                _connect_call();
            }
            else
            {
                // no more endpoints to connect
                AsyncHTTPResult r;
                r.error = AsyncHTTPErrors.ConnFailed;
                _state = State.INIT;
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

    private void _resolver_callback(int status, InternetAddress[] addresses) @safe
    {
        debug(hiohttp) tracef("resolve calback");
        if ( status != ARES_SUCCESS)
        {
            AsyncHTTPResult result;
            result.error = AsyncHTTPErrors.ResolveFailed;
            _state = State.INIT;
            _callback(result);
            return;
        }
        _state = State.CONNECTING;
        _endpoints = addresses;
        _connect_call();
    }
    private void _resolver_call(URL url) @safe
    {
        debug(hiohttp) tracef("resolve %s", url);
        hio_gethostbyname(url.host, &_resolver_callback, url.port);
    }

    /// build request line.
    /// Take proxy into account. 
    private NbuffChunk _build_request_line() @trusted
    {
        if (!use_proxy)
        {
            ulong ml = _request.method.length;
            auto pqs = _current_url.path_off >= 0 ? _current_url.url[_current_url.path_off..$] : "/";
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
        if (_verbosity >= 1) writef("-> %s", request_line.asString!(dup));

        if ( !_request.user_headers_flags.Host )
        {
            message_header.append("Host: ");
            if ( _current_url.port == standard_port(_current_url.schema) )
            {
                message_header.append(_current_url.host);
                if (_verbosity >= 1) writefln("-> Host: %s", _current_url.host);
            }
            else
            {
                message_header.append(_current_url.host ~ ":%d".format(_current_url.port));
                if (_verbosity >= 1) writefln("-> Host: %s", _current_url.host ~ ":%d".format(_current_url.port));
            }
            message_header.append("\n");
        }
        if (!_request.user_headers_flags.UserAgent)
        {
            message_header.append("UserAgent: hio\n");
            if (_verbosity >= 1) writefln("-> %s: %s", "UserAgent", "hio");
        }
        if (!_request.user_headers_flags.Connection && !_keep_alive )
        {
            message_header.append("Connection: Close\n");
            if (_verbosity >= 1) writefln("-> Connection: Close");
        }
        foreach (ref h; _request.user_headers)
        {
            message_header.append(h.FieldName);
            message_header.append(": ");
            message_header.append(h.FieldValue);
            message_header.append("\n");
            if (_verbosity >= 1)
            {
                writefln("-> %s: %s", h.FieldName, h.FieldValue);
            }
        }
        message_header.append("\n");
        return message_header;
    }

    void _execute() @safe
    {
        import std.stdio;
        debug(hiohttp) writefln("pool: %s", _conn_pool);
        debug(hiohttp) writefln("url: %s", _current_url);
        auto f = _conn_pool.fetch(ConnectionTriple(_current_url.schema, _current_url.host, _current_url.port));
        debug(hiohttp) writefln("f: %s", f);
        if (f.ok)
        {
            debug(hiohttp) tracef("Use connection from pool");
            _connection = f.value;
        }
        else
        {
            debug(hiohttp) tracef("Create new connection");
            _state = State.CONNECTING;
            _connection = _conn_factory(_current_url);
        }

        if ( _connection.connected )
        {
            debug(hiohttp) tracef("Connected, start http");
            _state = State.HANDLING;
            _http_handler_call(_connection);
            return;
        }
        else
        {
            // resolve, connect and then call handler
            // reset resolving
            _endpoints.length = 0;
            _state = State.HANDLING;
            _resolver_call(_current_url);
            return;
        }
        assert(0);
    }

    void execute(Method method, URL url, void delegate(AsyncHTTPResult) @safe callback)
    {
        enforce(_state == State.INIT, "You can't reenter this");
        enforce(_connection is null, "You can't reenter this");
        _loop = getDefaultLoop();
        _original_url = url;
        _current_url = url;
        _request.method = method;
        _redirects_counter = 0;

        _callback = callback;
        _handler._client = this;
        _handler._verbosity = _verbosity;
        _execute();
    }
}

unittest
{
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    import std.stdio;
    AsyncHTTPClient c = new AsyncHTTPClient();
    c._request.method = Method("GET");
    c._current_url = parse_url("http://example.com:8080/path");
    auto q = c._build_request_line();
    
    assert(q == "GET /path HTTP/1.1\n".representation);

    c._request.addHeader(Header("X-header", "x-value"));
    c._request.addHeader(Header("Content-Length", "100"));

    Nbuff header = c._build_request_header();
    //writeln(cast(string)header.data.data);
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
                cast(string)c._response_headers_buffer[c._offset + position..c._offset + position+length].data.data);
        final switch(c._expected_part)
        {
            case AsyncHTTP.HeaderPart.Value:
                // finalize value and start next Header
                debug(hiohttp) tracef("got <%s: %s>",
                    cast(string)c._response_headers_buffer.data.data[c._field_beg..c._field_end],
                    cast(string)c._response_headers_buffer.data.data[c._value_beg..c._value_end]);
                c.processHeader();
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
                cast(string)c._response_headers_buffer[c._offset + position..c._offset + position+length].data.data);
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
                debug(hiohttp) tracef("got Field: %s", cast(string)c._response_headers_buffer.data.data[c._field_beg..c._field_end]);
                c._expected_part = AsyncHTTP.HeaderPart.Value;
                c._value_beg = c._offset + position;
                c._value_end = c._value_beg + length;
                break;
        }
        return 0;
    }
    private int on_headers_complete(http_parser* parser)
    {
        debug(hiohttp) tracef("headers complete");
        AsyncHTTP* c = cast(AsyncHTTP*)parser.data;
        debug(hiohttp) tracef("got <%s: %s>",
            cast(string)c._response_headers_buffer.data.data[c._field_beg..c._field_end],
            cast(string)c._response_headers_buffer.data.data[c._value_beg..c._value_end]);
        c.processHeader();
        c._state = c.onHeadersComplete();
        debug(hiohttp) tracef("next state: %s", c._state);
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
        enum ContentEncoding
        {
            NONE,
            GZIP,
            DEFLATE
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
        int                     _verbosity;
        AsyncHTTPClient         _client;
        AsyncHTTPResult         _result;
        HeaderPart              _expected_part;
        size_t                  _offset;                    // offset of each socket input
        size_t                  _field_beg, _field_end;     // beg and end of headers field and value
        size_t                  _value_beg, _value_end;     // beg and end of headers field and value
        NbuffChunk              _current_input;
        immutable(ubyte)*       _current_buffer_ptr;
        size_t                  _current_buffer_length;
        Nbuff                   _response_body;
        MessageHeaders          _response_headers;
        Nbuff                   _response_headers_buffer;
        ContentEncoding         _content_encoding;
    }
    ~this()
    {
        // we can destroy it only when it is idle
        assert(_state == State.INIT, "You can't destroy in %s".format(_state));
    }
    private void reset() @safe
    {
        _response_body.clear;
        _response_headers.clear;
        _state = State.INIT;
        _content_encoding = ContentEncoding.NONE;
    }

    private void processHeader()
    {
        import std.stdio;
        // header field: _response_headers_buffer[_field_beg.._field_end]
        // header value: _response_headers_buffer[_value_beg.._value_end]
        NbuffChunk field = _response_headers_buffer.data(_field_beg, _field_end);
        NbuffChunk value = _response_headers_buffer.data(_value_beg, _value_end);
        if ( _verbosity >= 1 ) {
            writefln("<- %s: %s", cast(string)field.data, cast(string)value.data);
        }
        if (field.asString!(toLower) == "content-encoding" && value.asString!(toLower) == "gzip")
        {
            _content_encoding = ContentEncoding.GZIP;
        }
        else
        {
            _response_headers.insertBack(MessageHeader(field, value));
        }
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
                _response_headers_buffer.append(_current_input);
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
    private State onHeadersComplete()
    {
        debug(hiohttp) tracef("Checking headers");
        _result.status_code = _parser.status_code;
        _response_body.clear;
        _result.response_headers = _response_headers;
        return State.BODY_RECEIVE;
    }
    private void onBody(long off, size_t len)
    {
        import std.stdio;
        NbuffChunk b = _current_input[off..off+len];
        _response_body.append(b);
    }
    private void onBodyComplete()
    {
        debug(hiohttp) tracef("Body complete");
        _result.response_body = _response_body;
        AsyncHTTPResult result = _result;
        auto cb = _callback;
        reset();
        cb(result);
        return;
    }
    private void onTimeout() @safe
    {
        _result.status_code = -1;
        _result.error = AsyncHTTPErrors.Timeout;
        AsyncHTTPResult result = _result;
        auto cb = _callback;
        reset();
        cb(result);
        return;
    }
    private void onError() @safe
    {
        _result.status_code = -1;
        _result.error = AsyncHTTPErrors.DataError;
        AsyncHTTPResult result = _result;
        auto cb = _callback;
        reset();
        cb(result);
        return;
    }
    void execute() @safe
    {
        assert(_connection.connected);
        assert(_state == State.INIT);
        debug(hiohttp) tracef("handling %s", _client._current_url);
        _state = State.SENDING_REQUEST;
        http_parser_init(&_parser, http_parser_type.HTTP_RESPONSE);
        _send_request();
    }
}

struct AsyncHTTPResult
{
    int             status_code = -1;
    AsyncHTTPErrors error = AsyncHTTPErrors.None;
    Nbuff           response_body;
    MessageHeaders  response_headers;
    private
    {
        HashMap!(string, NbuffChunk)    cached_headers;
    }
    NbuffChunk getHeader(string h) @safe
    {
        auto hl = h.toLower;
        auto f = cached_headers.fetch(hl);
        if ( f.ok )
        {
            return f.value;
        }
        // iterate over non-cached headers, store in cache and return value if found
        while(!response_headers.empty)
        {
            auto hdr = response_headers.front;
            response_headers.popFront;
            string lowered_field = hdr.field.toLower();
            cached_headers.put(lowered_field, hdr.value);
            if ( lowered_field == hl )
            {
                return hdr.value;
            }
        }
        return NbuffChunk();
    }
}

unittest
{
    AsyncHTTPResult r;
    r.response_headers.insertBack(MessageHeader(NbuffChunk("Abc"), NbuffChunk("abc")));
    r.response_headers.insertBack(MessageHeader(NbuffChunk("Def"), NbuffChunk("bbb")));
    auto abc = r.getHeader("abc");
    assert(abc.data == "abc");
    abc = r.getHeader("abc");
    assert(abc.data == "abc");
    abc = r.getHeader("def");
    assert(abc.data == "bbb");
    abc = r.getHeader("none");
    assert(abc.empty);
}

unittest
{
    import std.stdio;
    import hio.scheduler;
    import std.datetime;
    import std.experimental.logger;
    globalLogLevel = LogLevel.info;
    info("Test http.client");
    App({
        AsyncHTTPClient client = new AsyncHTTPClient();
        void callback(AsyncHTTPResult result) @safe
        {
            //infof("Client called back with result: %s", result);
            () @trusted {
                if ( result.status_code < 0 )
                {
                    //writefln("<<<error: %s>>>", result.error.msg);
                    //writefln("<<<erro %s>>>", result.error.msg);
                    return;
                }
                //writefln("<<<body %s>>>", cast(string)result.response_body.data.data);
                //writefln("<<<erro %s>>>", result.error.msg);
            }();
            client.close();
            getDefaultLoop.stop();
        }
        URL url = parse_url("http://httpbin.org/stream/100");
        client.execute(Method("GET"), url, &callback);
        hlSleep(25.seconds);
    });
    // test redirects
    App({
        AsyncHTTPClient client = new AsyncHTTPClient();
        void callback(AsyncHTTPResult result) @safe
        {
            assert(result.status_code == 200);
            client.close();
            getDefaultLoop.stop();
        }
        URL url = parse_url("http://httpbin.org/absolute-redirect/3");
        client.execute(Method("GET"), url, &callback);
        hlSleep(25.seconds);
    });

    App({
        AsyncHTTPClient client = new AsyncHTTPClient();
        void callback(AsyncHTTPResult result) @safe
        {
            assert(result.status_code == -1);
            assert(result.error == AsyncHTTPErrors.MaxRedirectsReached);
            client.close();
            getDefaultLoop.stop();
        }
        URL url = parse_url("http://httpbin.org/absolute-redirect/3");
        client._max_redirects = 1;
        client.execute(Method("GET"), url, &callback);
        hlSleep(25.seconds);
    });
    App({
        AsyncHTTPClient client = new AsyncHTTPClient();
        void callback(AsyncHTTPResult result) @safe
        {
            () @trusted {
                assert(result.status_code == -1);
                assert(result.error == AsyncHTTPErrors.ConnFailed);
            }();
            client.close();
            getDefaultLoop.stop();
        }
        URL url = parse_url("http://2.2.2.2/");
        client._connect_timeout = 1.seconds;
        client.execute(Method("GET"), url, &callback);
        hlSleep(10.seconds);
    });

    globalLogLevel = LogLevel.trace;
    App({
        AsyncHTTPClient client = new AsyncHTTPClient();
        void callback(AsyncHTTPResult result) @safe
        {
            () @trusted {
                assert(result.status_code == 200);
            }();
            client.close();
            getDefaultLoop.stop();
        }
        URL url = parse_url("http://httpbin.org/gzip");
        client._connect_timeout = 1.seconds;
        client._verbosity = 1;
        client._request.addHeader(Header("Accept-Encoding","gzip"));
        client.execute(Method("GET"), url, &callback);
        hlSleep(10.seconds);
    });
}
