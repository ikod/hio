module hio.events;

import std.datetime;
import std.exception;
import std.container;
import std.experimental.logger;
import std.typecons;
import core.sync.mutex;
import std.format;

import hio.common;

import nbuff;

enum AppEvent : int {
    NONE = 0x00,
    IN   = 0x01,
    OUT  = 0x02,
    ERR  = 0x04,
    CONN = 0x08,
    HUP  = 0x10,
    TMO  = 0x20,
    USER = 0x40,
    IMMED= 0x80,
    ALL  = 0xff,
    EXT_EPOLLEXCLUSIVE = 0x100, // linux/epoll specific 
}
private immutable string[int] _names;

shared static this() {
    _names = [
        0:"NONE",
        1:"IN",
        2:"OUT",
        4:"ERR",
        8:"CONN",
       16:"HUP",
       32:"TMO",
       64:"USER",
       0x80:"IMMED",
    ];
}

alias HandlerDelegate = void delegate(AppEvent) @safe;
alias SigHandlerDelegate = void delegate(int) @safe;
alias FileHandlerFunction = void function(int, AppEvent) @safe;
//alias NotificationHandler = void delegate(Notification) @safe;
alias FileHandlerDelegate = void delegate(int, AppEvent) @safe;

string appeventToString(AppEvent ev) @safe pure {
    import std.format;
    import std.range;

    string[] a;
    with(AppEvent) {
        foreach(e; [IN,OUT,ERR,CONN,HUP,TMO]) {
            if ( ev & e ) {
                a ~= _names[e];
            }
        }
    }
    return a.join("|");
}

class NotFoundException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
        super(msg, file, line);
    }
}

class NotImplementedException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
        super(msg, file, line);
    }
}

//final class FileDescriptor {
//    package {
//        immutable int   _fileno;
//        HandlerDelegate _handler;
//        AppEvent        _polling;
//    }
//    this(int fileno) nothrow @safe {
//        _fileno = fileno;
//    }
//    override string toString() const @safe {
//        import std.format: format;
//        return appeventToString(_polling);
//        //return "FileDescriptor: filehandle: %d, events: %s".format(_fileno, appeventToString(_polling));
//    }
//}

//class CanPoll {
//    union Id {
//        int     fd = -1;
//    }
//    Id  id;
//}

abstract class EventHandler {
    abstract void eventHandler(AppEvent) @safe;
}

abstract class FileEventHandler {
    abstract void eventHandler(int, AppEvent) @safe;
}

final class Timer {
    private static ulong timer_id = 1;
    package {
        SysTime                   _expires;
        bool                      _armed;
        immutable ulong           _id;
        immutable HandlerDelegate _handler;
        immutable string          _file;
        immutable int             _line;
        version(unittest)
        {
            Duration              _delay;
        }
    }
    int opCmp(in Timer other) const nothrow pure @safe {
        int timeCmp = _expires.opCmp(other._expires);
        if ( timeCmp != 0 ) {
            return timeCmp;
        }
        return _id < other._id ? -1 : 1;
    }

    bool eq(const Timer b) const pure nothrow @safe {
        return this._id == b._id && this._expires == b._expires && this._handler == b._handler;
    }
    auto id() pure @nogc nothrow
    {
        return _id;
    }
    this(Duration d, HandlerDelegate h, string f = __FILE__, int l =  __LINE__) @safe {
        if ( d == Duration.max ) {
            _expires = SysTime.max;
        } else {
            _expires = Clock.currTime + d;
        }
        _handler = h;
        _id = timer_id;
        _file = f;
        _line = l;
        timer_id++;
        version(unittest)
        {
            _delay = d;
        }
    }
    this(SysTime e, HandlerDelegate h, string f = __FILE__, int l =  __LINE__) @safe {
        enforce(e != SysTime.init, "Unintialized expires for new timer");
        enforce(h != HandlerDelegate.init, "Unitialized handler for new Timer");
        _expires = e;
        _handler = h;
        _file = f;
        _line = l;
        _id = timer_id++;
    }
    auto rearm(Duration d)
    {
        assert(!_armed);
        if ( d == Duration.max ) {
            _expires = SysTime.max;
        } else {
            _expires = Clock.currTime + d;
        }
        version(unittest)
        {
            _delay = d;
        }
    }
    override string toString() const @trusted {
        import std.format: format;
        version(unittest)
        {
            return "timer: expires: %s(%s), id: %d, addr %X (%s:%d)".format(_expires, _delay, _id, cast(void*)this, _file, _line);
        }
        else
        {
            return "timer: expires: %s, id: %d, addr %X (%s:%d)".format(_expires, _id, cast(void*)this, _file, _line);
        }
    }
}

final class Signal {
    private static ulong signal_id = 1;
    package {
        immutable int   _signum;
        immutable ulong _id;
        immutable SigHandlerDelegate _handler;
    }

    this(int signum, SigHandlerDelegate h) {
        _signum = signum;
        _handler = h;
        _id = signal_id++;
    }
    int opCmp(in Signal other) const nothrow pure @safe {
        if ( _signum == other._signum ) {
            return _id < other._id ? -1 : 1;
        }
        return _signum < other._signum ? -1 : 1;
    }
    override string toString() const @trusted {
        import std.format: format;
        return "signal: signum: %d, id: %d".format(_signum, _id);
    }
}

struct IORequest {
    size_t              to_read = 0;
    bool                allowPartialInput = true;
    Nbuff               output;

    void delegate(IOResult) @safe callback;
}
struct IOResult {
    NbuffChunk          input;
    Nbuff               output;     // updated output slice
    bool                timedout;   // if we timedout
    bool                error;      // if there was an error
    string toString() const @trusted {
        import std.format;
        return "in:%s, out:%s, tmo: %s, error: %s".format(input, output, timedout?"yes":"no", error?"yes":"no");
    }
}


struct CircBuff(T) {
    enum Size = 512;
    private
    {
        ushort start=0, length = 0;
        T[Size] queue;
    }

    invariant
    {
        assert(length<=Size);
        assert(start<Size);
    }

    auto get() @safe
    in
    {
        assert(!empty);
    }
    out
    {
        assert(!full);
    }
    do
    {
        enforce(!empty);
        auto v = queue[start];
        length--;
        start = (++start) % Size;
        return v;
    }

    void put(T v) @safe
    in
    {
        assert(!full);
    }
    out
    {
        assert(!empty);
    }
    do
    {
        enforce(!full);
        queue[(start + length)%Size] = v;
        length++;
    }
    bool empty() const @safe @property @nogc nothrow {
        return length == 0;
    }
    bool full() const @safe @property @nogc nothrow {
        return length == Size;
    }
}

alias Broadcast = Flag!"broadcast";

//struct NotificationDelivery {
//    Notification _n;
//    Broadcast    _broadcast;
//}

//class Notification {
//    import  containers;
//
//    private SList!(void delegate(Notification) @safe) _subscribers;
//
//    void handler(Broadcast broadcast = Yes.broadcast) @trusted {
//        debug tracef("Handle %s".format(broadcast));
//        if ( broadcast )
//        {
//            debug tracef("subscribers %s".format(_subscribers.range));
//            foreach(s; _subscribers.range) {
//                debug tracef("subscriber %s".format(&s));
//                s(this);
//                debug tracef("subscriber %s - done".format(&s));
//            }
//        } else
//        {
//            auto s = _subscribers.front;
//            s(this);
//        }
//    }
//
//    void subscribe(void delegate(Notification) @safe s) @safe @nogc nothrow {
//        _subscribers ~= s;
//    }
//
//    void unsubscribe(void delegate(Notification) @safe s) @safe @nogc {
//        _subscribers.remove(s);
//    }
//}
//@safe unittest {
//    import std.stdio;
//    class TestNotification : Notification {
//        int _v;
//        this(int v) {
//            _v = v;
//        }
//    }
//    
//    auto ueq = CircBuff!Notification();
//    assert(ueq.empty);
//    assert(!ueq.full);
//    foreach(i;0..ueq.Size) {
//        auto ue = new TestNotification(i);
//        ueq.put(ue);
//    }
//    assert(ueq.full);
//    foreach(n;0..ueq.Size) {
//        auto i = ueq.get();
//        assert(n==(cast(TestNotification)i)._v);
//    }
//    assert(ueq.empty);
//    foreach(i;0..ueq.Size) {
//        auto ue = new TestNotification(i);
//        ueq.put(ue);
//    }
//    assert(ueq.full);
//    foreach(n;0..ueq.Size) {
//        auto i = ueq.get();
//        assert(n==(cast(TestNotification)i)._v);
//    }
//    //
//    int testvar;
//    void d1(Notification n) @safe {
//        testvar++;
//        auto v = cast(TestNotification)n;
//    }
//    void d2(Notification n) {
//        testvar--;
//    }
//    auto n1 = new TestNotification(1);
//    n1.subscribe(&d1);
//    n1.subscribe(&d2);
//    n1.subscribe(&d1);
//    n1.handler(Yes.broadcast);
//    assert(testvar==1);
//    n1.unsubscribe(&d2);
//    n1.handler(Yes.broadcast);
//    assert(testvar==3);
//}

//class Subscription {
//    NotificationChannel     _channel;
//    void delegate() @safe   _handler;
//    shared this(shared NotificationChannel c, void delegate() @safe h) @safe nothrow {
//        _channel = c;
//        _handler = h;
//    }
//}
//
//private shared int shared_notifications_id;
//shared class SharedNotification {
//    import containers;
//    import core.atomic;
//    private {
//        int                     _n_id;
//        //private shared SList!Subscription   _subscribers;
//        private Subscription[]  _subscribers;
//    }
//
//    shared this() @safe {
//        _n_id = shared_notifications_id;
//        atomicOp!"+="(shared_notifications_id, 1);
//    }
//
//    void handler(Broadcast broadcast = Yes.broadcast) @safe {
//        if ( broadcast )
//        {
//            //foreach(s; _subscribers) {
//            //    s(this);
//            //}
//        } else
//        {
//            //auto s = _subscribers.front;
//            //s(this);
//        }
//    }
//
//    void subscribe(NotificationChannel c, void delegate() @safe s) @safe nothrow shared {
//        _subscribers ~= new shared Subscription(c, s);
//    }
//
//    void unsubscribe(NotificationChannel c, void delegate() @safe s) @safe {
//        //_subscribers.remove(Subscription(c, s));
//    }
//}


@safe unittest {
    //info("testing shared notifications");
    //auto sna = new shared SharedNotification();
    //auto snb = new shared SharedNotification();
    //assert(sna._n_id == 0);
    //assert(snb._n_id == 1);
    //shared NotificationChannel c = new shared NotificationChannel;
    //shared SharedNotification sn = new shared SharedNotification();
    //sn.subscribe(c, delegate void() {});
    //info("testing shared notifications - done");
}
