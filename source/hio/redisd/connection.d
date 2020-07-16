///
module hio.redisd.connection;

import std.algorithm;
import std.conv;
import std.stdio;

import nbuff;
import hio.http.common: URL, parse_url;
///
interface Connection {
    ///
    void connect(URL) @safe;
    ///
    size_t send(immutable(ubyte)[]);
    ///
    immutable(ubyte)[] recv(size_t);
    ///
    void close();
}

// alias ConnectionMaker = Connection function() @safe;
// /// std.socket transport
// class SocketConnection : Connection {
//     import std.socket;
//     private {
//         string  _host;
//         ushort  _port;
//         Socket  _socket;
//     }

//     this() @safe {
//         _socket = new Socket(AddressFamily.INET, SocketType.STREAM);
//         _socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

//     }

//     override void connect(URL url) @safe {
//         string host = url.host;
//         ushort port = url.port;
//         auto addr = new InternetAddress(host, port);
//         _socket.connect(addr);
//     }

//     override immutable(ubyte)[] recv(size_t to_receive) {
//         immutable(ubyte)[] result;
//         result.length = to_receive;
//         auto r = _socket.receive(cast(void[])result);
//         if ( r <= 0 ) {
//             return result[0..0];
//         }
//         return result[0..r];
//     }

//     override size_t send(immutable(ubyte)[] data) {
//         return _socket.send(cast(void[])data, SocketFlags.NONE);
//     }

//     override void close() {
//         _socket.close();
//     }

// }
// /// std.socket connection builder
// Connection stdConnectionMaker() @safe {
//     return new SocketConnection();
// }

import std.datetime;
import std.socket;
import std.format;
import hio.socket;
import hio.events;
/// hio connection builder
HioSocketConnection hioConnectionMaker() @safe {
    return new HioSocketConnection();
}
/// hio transport
class HioSocketConnection {
    private {
        HioSocket   _socket;
        Duration    _io_timeout = 1.seconds;
    }

    this() @safe {
        _socket = new HioSocket();
    }

    void io_timeout(Duration t)
    {
        _io_timeout = t;
    }

    void connect(URL url) {
        auto a = getAddressInfo(url.host, AddressFamily.INET);
        _socket.connect("%s:%d".format(a[0].address.toAddrString, url.port), _io_timeout);
    }

    bool connected()
    {
        return _socket.connected;
    }

    NbuffChunk recv(size_t to_receive) {
        IOResult r = _socket.recv(to_receive, _io_timeout);
        if ( r.error || r.timedout || r.input.length == 0) {
            return NbuffChunk();
        }
        return r.input;
    }

    size_t send(immutable(ubyte)[] data) {
        return _socket.send(data, _io_timeout);
    }

    void close() {
        _socket.close();
    }
}