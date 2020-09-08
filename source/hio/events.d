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
    NONE =               0x0000,
    IN   =               0x0001,
    OUT  =               0x0002,
    ERR  =               0x0004,
    CONN =               0x0008,
    HUP  =               0x0010,
    TMO  =               0x0020,
    USER =               0x0040,
    IMMED=               0x0080,
    SHUTDOWN =           0x0100,
    EXT_EPOLLEXCLUSIVE = 0x1000, // linux/epoll specific 
    ALL  =               0x0fff,
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
       0x100:"SHUTDOWN",
    ];
}

///
alias HandlerDelegate = void delegate(AppEvent) @safe;
alias SigHandlerDelegate = void delegate(int) @safe;
alias FileHandlerFunction = void function(int, AppEvent) @safe;
//alias NotificationHandler = void delegate(Notification) @safe;
alias FileHandlerDelegate = void delegate(int, AppEvent) @safe;
alias IOCallback = void delegate(ref IOResult) @safe;

string appeventToString(AppEvent ev) @safe pure {
    import std.format;
    import std.range;

    string[] a;
    with(AppEvent) {
        foreach(e; [IN,OUT,ERR,CONN,HUP,TMO,SHUTDOWN]) {
            if ( ev & e ) {
                a ~= _names[e];
            }
        }
    }
    return a.join("|");
}

class LoopShutdownException: Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
        super(msg, file, line);
    }
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
    string        describe();
}

abstract class FileEventHandler {
    abstract void eventHandler(int, AppEvent) @safe;
    abstract string describe();
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
    alias describe = toString;
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

    IOCallback          callback;
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


