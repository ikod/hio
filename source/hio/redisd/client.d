///
module hio.redisd.client;

import std.typecons;
import std.stdio;
import std.algorithm;
import std.range;
import std.string;
import std.datetime;

import std.meta: allSatisfy;
import std.traits: isSomeString;

import std.experimental.logger;

import hio.socket;
import hio.resolver;
import hio.redisd.codec;

import hio.http.common: URL, parse_url;

private immutable bufferSize = 2*1024;

///
class NotAuthenticated : Exception {
    ///
    this(string msg) {
        super(msg);
    }
}
/// client API
class Client {

    private {
        URL         _url;
        HioSocket   _connection;
        Decoder     _input_stream;
        Duration    _timeout = 1.seconds;
    }
    /// Constructor
    this(string url="redis://localhost:6379") {
        _url = parse_url(url);
        _connection = new HioSocket();
        _input_stream = new Decoder();
        if ( _url.userinfo ) {
            auto v = execCommand("AUTH", _url.userinfo[1..$]);
            if ( v.svar != "OK" ) {
                throw new NotAuthenticated("Can't authenticate");
            }
        }
    }
    auto strerror()
    {
        return _connection.strerror();
    }
    auto errno()
    {
        return _connection.errno();
    }

    void connect()
    {
        debug(hioredis) tracef("connecting to %s:%s", _url.host, _url.port);
        auto r = hio_gethostbyname(_url.host, _url.port);

        if (r.status == ARES_SUCCESS)
        {
            _connection.connect(r.addresses[0], _timeout);
        }
    }
    private void reconnect() {
        if ( _connection )
        {
            _connection.close();
        }
        _connection = new HioSocket();
        connect();
        _input_stream = new Decoder;
        if (_url.userinfo) {
            auto auth = execCommand("AUTH", _url.userinfo[1..$]);
            if (auth.svar != "OK") {
                throw new NotAuthenticated("Can't authenticate");
            }
        }
    }
    /// Build redis command from command name and args.
    /// All args must be of type string.
    RedisdValue makeCommand(A...)(A args) {
        static assert(allSatisfy!(isSomeString, A), "all command parameters must be of type string");
        return redisdValue(tuple(args));
    }
    /// Build and execute redis transaction from command array.
    RedisdValue transaction(RedisdValue[] commands) {
        RedisdValue[] results;
        RedisdValue r = this.execCommand("MULTI");
        foreach (c; commands) {
            exec(c);
        }
        r = this.execCommand("EXEC");
        return r;
    }
    /// build and execute redis pipeline from commands array.
    RedisdValue[] pipeline(RedisdValue[] commands) {
        immutable(ubyte)[] data = commands.map!encode.join();
        _connection.send(data);
        RedisdValue[] response;
        while (response.length < commands.length) {
            debug(hioredis) tracef("response length=%d, commands.length=%d", response.length, commands.length);
            auto r = _connection.recv(bufferSize);
            if (r.timedout || r.error || r.input.length == 0)
            {
                break;
            }
            _input_stream.put(r.input);
            while(true) {
                auto v = _input_stream.get();
                if (v.type == ValueType.Incomplete) {
                    break;
                }
                response ~= v;
                if (v.type == ValueType.Error
                        && cast(string) v.svar[4 .. 18] == "Protocol error") {
                    debug(hioredis)
                        trace("reopen connection");
                    _connection.close();
                    reconnect();
                    return response;
                }
            }
        }
        return response;
    }

    private RedisdValue exec(RedisdValue command) {
        RedisdValue response;
        _connection.send(command.encode);
        while (true) {
            auto r = _connection.recv(bufferSize);
            if ( r.error || r.timedout || r.input.length == 0) 
            {
                break;
            }
            _input_stream.put(r.input);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if (response.type == ValueType.Error && response.svar[4 .. 18] == "Protocol error") {
            _connection.close();
            debug(hioredis)
                trace("reopen connection");
            reconnect();
        }
        if (response.type == ValueType.Error && response.svar[0..6] == "NOAUTH" ) {
            throw new NotAuthenticated("Auth required");
        }
        return response;
    }
    /// build and execute single redis command.
    RedisdValue execCommand(A...)(A args) {
        immutable(ubyte)[][] data;
        RedisdValue request = makeCommand(args);
        RedisdValue response;
        debug(hioredis) tracef("send request %s", request);
        _connection.send(request.encode);
        while(true) {
            auto r = _connection.recv(bufferSize);
            if (r.error || r.timedout || r.input.length == 0)
            {
                break;
            }
            auto b = r.input;
            _input_stream.put(b);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if ( response.type == ValueType.Error && 
                cast(string)response.svar[4..18] == "Protocol error") {
            _connection.close();
            debug(hioredis) trace("reopen connection");
            reconnect();
        }
        if (response.type == ValueType.Error && response.svar[0 .. 6] == "NOAUTH") {
            throw new NotAuthenticated("Auth required");
        }
        debug(hioredis) tracef("got response %s", response);
        return response;
    }
    /// Simple key/value set
    RedisdValue set(K, V)(K k, V v) {
        return execCommand("SET", k, v);
    }
    /// Simple key/value get
    RedisdValue get(K)(K k) {
        return execCommand("GET", k);
    }
    /// Consume reply
    RedisdValue read() {
        RedisdValue response;
        response = _input_stream.get();
        while(response.type == ValueType.Incomplete) {
            auto r = _connection.recv(bufferSize);
            if ( r.error || r.timedout || r.input.length == 0)
            {
                break;
            }
            _input_stream.put(r.input);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if (response.type == ValueType.Error && cast(string) response.svar[4 .. 18]
                == "Protocol error") {
            _connection.close();
            debug(hioredis)
                trace("reopen connection");
            reconnect();
        }
        return response;
    }

    bool connected()
    {
        return _connection.connected;
    }

    void close()
    {
        _connection.close();
        _connection = null;
        debug(hioredis) trace("connection closed");
    }
}