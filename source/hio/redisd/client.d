///
module redisd.client;

import std.typecons;
import std.stdio;
import std.algorithm;
import std.range;
import std.string;

import std.meta: allSatisfy;
import std.traits: isSomeString;

import std.experimental.logger;

import redisd.connection;
import redisd.codec;

import hio.http.common: URL, parse_url;

private immutable bufferSize = 4*1024;

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
        URL                 _url;
        ConnectionMaker     _connection_maker;
        HioSocketConnection _connection;
        Decoder             _input_stream;
    }
    /// Constructor
    this(string url="redis://localhost:6379", ConnectionMaker connectionMaker=&stdConnectionMaker) {
        _url = parse_url(url);
        _connection_maker = connectionMaker;
        _connection = new HioSocketConnection();
        _connection.connect(_url);
        _input_stream = new Decoder();
        if ( _url.userinfo ) {
            auto v = execCommand("AUTH", _url.userinfo[1..$]);
            if ( v.svar != "OK" ) {
                throw new NotAuthenticated("Can't authenticate");
            }
        }
    }

    private void reconnect() {
        _connection = new HioSocketConnection();
        _connection.connect(_url);
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
            debug(redisd) tracef("response length=%d, commands.length=%d", response.length, commands.length);
            auto b = _connection.recv(bufferSize);
            if (b.length == 0) {
                break;
            }
            _input_stream.put(b);
            while(true) {
                auto v = _input_stream.get();
                if (v.type == ValueType.Incomplete) {
                    break;
                }
                response ~= v;
                if (v.type == ValueType.Error
                        && cast(string) v.svar[4 .. 18] == "Protocol error") {
                    debug (redisd)
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
            auto b = _connection.recv(bufferSize);
            if (b.length == 0) {
                break;
            }
            _input_stream.put(b);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if (response.type == ValueType.Error && response.svar[4 .. 18] == "Protocol error") {
            _connection.close();
            debug (redisd)
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
        _connection.send(request.encode);
        while(true) {
            auto b = _connection.recv(bufferSize);
            if ( b.length == 0 ) {
                // error, timeout or something bad
                break;
            }
            _input_stream.put(b);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if ( response.type == ValueType.Error && 
                cast(string)response.svar[4..18] == "Protocol error") {
            _connection.close();
            debug(redisd) trace("reopen connection");
            reconnect();
        }
        if (response.type == ValueType.Error && response.svar[0 .. 6] == "NOAUTH") {
            throw new NotAuthenticated("Auth required");
        }
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
            auto b = _connection.recv(bufferSize);
            if (b.length == 0) {
                break;
            }
            _input_stream.put(b);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if (response.type == ValueType.Error && cast(string) response.svar[4 .. 18]
                == "Protocol error") {
            _connection.close();
            debug (redisd)
                trace("reopen connection");
            reconnect();
        }
        return response;
    }

    void close() {
        _connection.close();
    }
}