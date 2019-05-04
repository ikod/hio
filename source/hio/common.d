module hio.common;

import std.exception;
import std.conv;
import core.stdc.string: strerror;
import std.experimental.logger;

import core.sys.posix.sys.socket;
import core.stdc.string;
import core.stdc.errno;
import core.sys.posix.unistd;

auto s_strerror(T)(T e) @trusted {
    return to!string(strerror(e));
}

SocketPair makeSocketPair() @safe {
    import core.sys.posix.fcntl;
    int[2] pair;
    auto r = (() @trusted => socketpair(AF_UNIX, SOCK_DGRAM, 0, pair))();
    if ( r == -1 ) {
        throw new Exception(s_strerror(errno()));
    }
    auto flags = (() @trusted => fcntl(pair[0], F_GETFL, 0) | O_NONBLOCK)();
    (() @trusted => fcntl(pair[0], F_SETFL, flags))();
    flags = (() @trusted => fcntl(pair[1], F_GETFL, 0) | O_NONBLOCK)();
    (() @trusted => fcntl(pair[1], F_SETFL, flags))();
    SocketPair result;
    result._pair = pair;
    return result;
}


struct SocketPair {
    int[2]  _pair = [-1, -1];
    public void close() {
        core.sys.posix.unistd.close(_pair[0]);
        core.sys.posix.unistd.close(_pair[1]);
    }
    auto opIndex(size_t i) const {
        return _pair[i];
    }
    auto read(uint i, size_t len) @safe
    {
        enforce!Exception(i <= 1, "Index in socketpair must be 0 or 1");
        if ( len <= 0 ) {
            throw new Exception("read length must be > 0");
        }
        ubyte[] b = new ubyte[](len);
        auto s = (() @trusted => core.sys.posix.unistd.read(_pair[i], b.ptr, len))();
        enforce!Exception(s > 0, "failed to read from socketpair");
        return b;
    }
    auto write(uint i, ubyte[] b) @safe {
        return (() @trusted => core.sys.posix.unistd.write(_pair[i], b.ptr, b.length))();
    }
}

//class NotificationChannel {
//    import  containers;

//    private enum NotificationType {Signal, Broadcast}
//
//    private NotificationType _type = NotificationType.Signal;
//
//    private SList!(void delegate() @safe) _subscribers;
//
//    SocketPair  _pipe;
//
//    auto readEnd() const @safe @nogc {
//        return _pipe[0];
//    }
//
//    auto writeEnd() const @safe @nogc {
//        return _pipe[1];
//    }
//
//    void handler() @safe {
//        with (NotificationType) final switch(_type) {
//        case Signal:
//            auto s = _subscribers.front;
//            s();
//            break;
//        case Broadcast:
//            foreach(s; _subscribers) {
//                s();
//            }
//            break;
//        }
//    }
//
//    this() @safe {
//        _pipe = makeSocketPair();
//    }
//    shared this() @safe {
//        //_pipe = makeSocketPair();
//    }
//    void subscribe(void delegate() @safe h) @safe {
//        _subscribers ~= h;
//    }
//    void unsubscribe(void delegate() @safe h) @safe {
//        _subscribers.remove(h);
//    }
//
//    auto signal() @property @safe @nogc {
//        _type = NotificationType.Signal;
//        ubyte[1] b = [0];
//        auto s = _pipe.write(1, b);
//        return this;
//    }
//    auto broadcast() @property @safe @nogc {
//        _type = NotificationType.Broadcast;
//        ubyte[1] b = [0];
//        auto s = _pipe.write(1, b);
//        return this;
//    }
//}

