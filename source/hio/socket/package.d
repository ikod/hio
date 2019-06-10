module hio.socket;

import std.typecons;
import std.string;
import std.conv;
import std.traits;
import std.datetime;
import std.exception;

import std.algorithm.comparison: min;

import std.experimental.logger;

import core.memory: pureMalloc, GC;
import core.exception : onOutOfMemoryError;

import std.experimental.allocator;
import std.experimental.allocator.building_blocks;

//static import std.socket;

import core.sys.posix.sys.socket;
import core.sys.posix.unistd;
import core.sys.posix.arpa.inet;
import core.sys.posix.netinet.tcp;
import core.sys.posix.netinet.in_;

import core.sys.posix.fcntl;

import core.stdc.string;
import core.stdc.errno;

import hio.events;
import hio.common;
//import nbuff;

import hio;

//alias Socket = RefCounted!SocketImpl;

alias AcceptFunction = void function(int fileno);
alias AcceptDelegate = void delegate(hlSocket);

// static ~this() {
//     trace("deinit");
// }

//hlSocket[int] fd2so;
//
//void loopCallback(int fd, AppEvent ev) @safe {
//    debug tracef("loopCallback for %d", fd);
//    hlSocket s = fd2so[fd];
//    if ( s && s._fileno >= 0) {
//        debug tracef("calling handler(%s) for %s", appeventToString(ev), s);
//        s._handler(ev);
//    } else {
//        infof("impossible event %s on fd: %d", appeventToString(ev), fd);
//    }
//}

class SocketException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
        super(msg, file, line);
    }
}

class hlSocket : FileEventHandler {
    private {
        enum State {
            NEW = 0,
            IDLE,
            CONNECTING,
            ACCEPTING,
            IO,
        }

        immutable ubyte      _af = AF_INET;
        immutable int        _sock_type = SOCK_STREAM;
        int                  _fileno = -1;
        int                  _errno;
        HandlerDelegate      _handler;
        AppEvent             _polling = AppEvent.NONE;
        size_t               _buffer_size = 16*1024;
        hlEvLoop             _loop;
        immutable string     _file;
        immutable int        _line;
        State                _state = State.NEW;
        HandlerDelegate      _callback;
        // accept related fields
        void delegate(int) @safe _accept_callback;
        // io related fields
        IORequest            _iorq;
        IOResult             _result;
        Timer                _connect_timer;
        Timer                _io_timer;
        AppEvent             _pollingFor = AppEvent.NONE;
        ubyte[]              _input;
        bool                 _connected;
        uint                 _accepts_in_a_row = 10;
    }

    this(ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l =  __LINE__) @safe {
        debug tracef("create socket");
        _af = af;
        _sock_type = sock_type;
        _file = f;
        _line = l;
    }

    this(int s, ubyte af = AF_INET, int sock_type = 0, string f = __FILE__, int l =  __LINE__) @safe
    in {assert(s>=0);}
    body {
        _af = af;
        _sock_type = sock_type;
        _fileno = s;
        _file = f;
        _line = l;
        auto flags = (() @trusted => fcntl(_fileno, F_GETFL, 0) | O_NONBLOCK)();
        (() @trusted => fcntl(_fileno, F_SETFL, flags))();
    }


    ~this() {
        // if ( _fileno != -1 ) {
        //     if ( _loop && _polling != AppEvent.NONE ) {
        //         _loop.stopPoll(_fileno, _polling);
        //         _loop.detach(_fileno);
        //     }
        //     //fd2so[_fileno] = null;
        //     .close(_fileno);
        //     _fileno = -1;
        // }
        // close();
    }
    
    override string toString() const @safe {
        import std.format: format;
        return "socket: fileno: %d, (%s:%d)".format(_fileno, _file, _line);
    }
    public bool connected() const pure @safe nothrow {
        return _connected;
    }

    public auto fileno() const pure @safe nothrow {
        return _fileno;
    }

    public auto socket_errno() const pure @safe nothrow {
        return _errno;
    }

    void timeoutHandler(AppEvent e) @safe {
        debug
        {
            tracef("Timeout handler: %s", appeventToString(e));
        }
        final switch (_state) {
        case State.NEW:
            assert(0);
        case State.IDLE:
            assert(0);
        case State.CONNECTING:
            debug tracef("connection timed out");
            _connected = false;
            _errno = ETIMEDOUT;
            _polling = AppEvent.NONE;
            _loop.stopPoll(_fileno, AppEvent.OUT);
            _loop.detach(_fileno);
            _state = State.IDLE;
            _callback(e);
            return;
        case State.ACCEPTING:
            assert(0);
        case State.IO:
            assert(0);
        }
    }
    override void eventHandler(int fd, AppEvent e) @safe {
        debug tracef("event %s in state %s", appeventToString(e), _state);
        final switch ( _state ) {
        case State.NEW:
            assert(0);
        case State.IDLE:
            assert(0);
        case State.CONNECTING:
            debug tracef("connection event: %s", appeventToString(e));
            assert(e & (AppEvent.OUT|AppEvent.HUP), "We can handle only OUT event in connectiong state");
            if ( e & AppEvent.OUT ) {
                _connected = true;
            }
            if ( e & AppEvent.HUP ) {
                int err;
                uint err_s = err.sizeof;
                auto rc = (() @trusted => .getsockopt(_fileno, SOL_SOCKET, SO_ERROR, &err, &err_s))();
                if ( rc == 0 ) {
                    _errno = err;
                    debug tracef("error connecting: %s", s_strerror(err));
                }
                _connected = false;
            }
            _polling = AppEvent.NONE;
            _state = State.IDLE;
            if ( _connect_timer ) {
                _loop.stopTimer(_connect_timer);
                _connect_timer = null;
            }
            _loop.stopPoll(_fileno, AppEvent.OUT);
            _callback(e);
            return;
            //_handler(e);
        case State.ACCEPTING:
            assert(e == AppEvent.IN, "We can handle only IN event in accepting state");
            foreach(_; 0.._accepts_in_a_row) {
                if ( _fileno == -1 ) {
                    break; // socket can be closed in handler
                }
                sockaddr sa;
                uint sa_len = sa.sizeof;
                int new_s = (() @trusted => .accept(_fileno, &sa, &sa_len))();
                if ( new_s == -1 ) {
                    auto err = errno();
                    if ( err == EWOULDBLOCK || err == EAGAIN ) {
                        // POSIX.1-2001 and POSIX.1-2008 allow
                        // either error to be returned for this case, and do not require
                        // these constants to have the same value, so a portable
                        // application should check for both possibilities.
                        break;
                    }
                    throw new Exception(s_strerror(err));
                }
                debug tracef("New socket fd: %d", new_s);
                immutable int flag = 1;
                auto rc = (() @trusted => .setsockopt(new_s, IPPROTO_TCP, TCP_NODELAY, &flag, flag.sizeof))();
                if ( rc != 0 ) {
                     throw new Exception(s_strerror(errno()));
                }
                version(OSX) {
                    rc = (() @trusted => .setsockopt(_fileno, SOL_SOCKET, SO_NOSIGPIPE, &flag, flag.sizeof))();
                    if ( rc != 0 ) {
                         throw new Exception(s_strerror(errno()));
                    }
                }
                auto flags = (() @trusted => fcntl(new_s, F_GETFL, 0) | O_NONBLOCK)();
                (() @trusted => fcntl(new_s, F_SETFL, flags))();
                //hlSocket ns = new hlSocket(_af, _sock_type, new_s);
                //fd2so[new_s] = ns;
                //_accept_callback(ns);
                _accept_callback(new_s);
                debug tracef("accept_callback for fd: %d - done", new_s);
            }
            //_handler(e);
            return;
        case State.IO:
            io_handler(e);
            return;
        }
    }

    public int open() @trusted {
        immutable flag = 1;
        if (_fileno != -1) {
            throw new SocketException("You can't open already opened socket: fileno(%d)".format(_fileno));
        }
        _fileno = socket(_af, _sock_type, 0);
        if ( _fileno < 0 )
            return _fileno;
        _polling = AppEvent.NONE;
        //fd2so[_fileno] = this;
        auto rc = .setsockopt(_fileno, IPPROTO_TCP, TCP_NODELAY, &flag, flag.sizeof);
        if ( rc != 0 ) {
             throw new Exception(to!string(strerror(errno())));
        }
        version(OSX) {
            rc = .setsockopt(_fileno, SOL_SOCKET, SO_NOSIGPIPE, &flag, flag.sizeof);
            if ( rc != 0 ) {
                 throw new Exception(to!string(strerror(errno())));
            }
        }
        auto flags = fcntl(_fileno, F_GETFL, 0) | O_NONBLOCK;
        fcntl(_fileno, F_SETFL, flags);
        return _fileno;
    }

    public void close() @safe {
        if ( _fileno != -1 ) {
            debug tracef("closing %d, polling: %x", _fileno, _polling);
            if ( _loop && _polling != AppEvent.NONE ) {
                debug tracef("detach from polling for %s", appeventToString(_polling));
                _loop.stopPoll(_fileno, _polling);
                _loop.detach(_fileno);
            }
            //fd2so[_fileno] = null;
            .close(_fileno);
            _fileno = -1;
        }
    }
    
    public void bind(string addr) @trusted {
         debug {
             tracef("binding to %s", addr);
         }
         switch (_af) {
             case AF_INET:
                {
                    import core.sys.posix.netinet.in_;
                    // addr must be "host:port"
                    auto internet_addr = str2inetaddr(addr);
                    sockaddr_in sin;
                    sin.sin_family = _af;
                    sin.sin_port = internet_addr[1];
                    sin.sin_addr = in_addr(internet_addr[0]);
                    int flag = 1;
                    auto rc = .setsockopt(_fileno, SOL_SOCKET, SO_REUSEADDR, &flag, flag.sizeof);
                    debug tracef("setsockopt for bind result: %d", rc);
                    if ( rc != 0 ) {
                    throw new Exception(to!string(strerror(errno())));
                    }
                    rc = .bind(_fileno, cast(sockaddr*)&sin, cast(uint)sin.sizeof);
                    debug {
                        tracef("bind result: %d", rc);
                    }
                    if ( rc != 0 ) {
                        throw new SocketException(to!string(strerror(errno())));
                    }
                }
                break;
             case AF_UNIX:
             default:
                 throw new SocketException("unsupported address family");
         }
    }

    public void listen(int backlog = 10) @trusted {
        int rc = .listen(_fileno, backlog);
        if ( rc != 0 ) {
            throw new SocketException(to!string(strerror(errno())));
        }
        debug tracef("listen on %d ok", _fileno);
    }

    public void stopPolling(L)(L loop) @safe {
        debug tracef("Stop polling on %d", _fileno);
        loop.stopPoll(_fileno, _polling);
    }

    ///
    /// Return true if connect delayed
    ///
    public bool connect(string addr, hlEvLoop loop, HandlerDelegate f, Duration timeout) @safe {
        assert(timeout > 0.seconds);
        switch (_af) {
            case AF_INET:
                {
                    import core.sys.posix.netinet.in_;
                    // addr must be "host:port"
                    auto internet_addr = str2inetaddr(addr);
                    sockaddr_in sin;
                    sin.sin_family = _af;
                    sin.sin_port = internet_addr[1];
                    sin.sin_addr = in_addr(internet_addr[0]);
                    uint sa_len = sin.sizeof;
                    auto rc = (() @trusted => .connect(_fileno, cast(sockaddr*)&sin, sa_len))();
                    if ( rc == -1 && errno() != EINPROGRESS ) {
                        debug infof("connect errno: %s", s_strerror(errno()));
                        _connected = false;
                        _state = State.IDLE;
                        f(AppEvent.ERR|AppEvent.IMMED);
                        return false;
                    }
                    _loop = loop;
                    _state = State.CONNECTING;
                    _callback = f;
                    _polling |= AppEvent.OUT;
                    loop.startPoll(_fileno, AppEvent.OUT, this);
                }
                break;
            default:
                throw new SocketException("unsupported address family");
        }
        _connect_timer = new Timer(timeout, &timeoutHandler);
        _loop.startTimer(_connect_timer);
        return true;
    }

    public void accept(T)(hlEvLoop loop, T f) {
        _loop = loop;
        _accept_callback = f;
//        if ( _state != State.ACCEPTING ) {
            _state = State.ACCEPTING;
            _polling |= AppEvent.IN;
            loop.startPoll(_fileno, AppEvent.IN, this);
//        }
    }

    void io_handler(AppEvent ev) @safe {
        debug tracef("event %s on fd %d", appeventToString(ev), _fileno);
        if ( ev == AppEvent.TMO ) {
            debug tracef("io timedout");
            _loop.stopPoll(_fileno, _pollingFor);
            _polling = AppEvent.NONE;
            delegate void() @trusted {
                _result.input = assumeUnique(_input);
            }();
            // return what we collected
            _result.input = (() @trusted => assumeUnique(_input))();
            // return timeout flag
            _result.timedout = true;
            // make callback
            _iorq.callback(_result);
            return;
        }
        if ( ev & AppEvent.IN )
        {
            ubyte[] b = new ubyte[](min(_buffer_size, _iorq.to_read));
            auto rc = (() @trusted => recv(_fileno, &b[0], _buffer_size, 0))();
            debug tracef("recv on fd %d returned %d", _fileno, rc);
            if ( rc < 0 )
            {
                _result.error = true;
                _polling &= _pollingFor ^ AppEvent.ALL;
                _loop.stopPoll(_fileno, _pollingFor);
                if ( _io_timer ) {
                    _loop.stopTimer(_io_timer);
                    _io_timer = null;
                }
                _result.input = (() @trusted => assumeUnique(_input))();
                //_result.output = output;
                _iorq.callback(_result);
                return;
            }
            if ( rc > 0 )
            {
                debug tracef("adding data %s", b[0..rc]);
                _input ~= b[0..rc];
                b = null;
                _iorq.to_read -= rc;
                if ( _iorq.to_read == 0 || _iorq.allowPartialInput ) {
                    _loop.stopPoll(_fileno, _pollingFor);
                    _polling = AppEvent.NONE;
                    if ( _io_timer ) {
                        _loop.stopTimer(_io_timer);
                        _io_timer = null;
                    }
                    _result.input = (() @trusted => assumeUnique(_input))();
                    _iorq.callback(_result);
                    return;
                }
                return;
            }
            if ( rc == 0 )
            {
                // socket closed
                _loop.stopPoll(_fileno, _pollingFor);
                if ( _io_timer ) {
                    _loop.stopTimer(_io_timer);
                    _io_timer = null;
                }
                _result.input = (() @trusted => assumeUnique(_input))();
                _polling = AppEvent.NONE;
                _iorq.callback(_result);
                return;
            }
        }
        if ( ev & AppEvent.OUT ) {
            debug tracef("sending %s", _iorq.output);
            assert(_iorq.output.length>0);
            uint flags = 0;
            version(linux) {
                flags = MSG_NOSIGNAL;
            }
            auto rc = (() @trusted => .send(_fileno, &_iorq.output[0], _iorq.output.length, flags))();
            if ( rc < 0 ) {
                // error sending
            }
            _iorq.output = _iorq.output[rc..$];
            if ( _iorq.output.length == 0 ) {
                _loop.stopPoll(_fileno, _pollingFor);
                if ( _io_timer ) {
                    _loop.stopTimer(_io_timer);
                    _io_timer = null;
                }
                _result.input = (() @trusted => assumeUnique(_input))();
                //_result.output = output;
                _polling = AppEvent.NONE;
                _iorq.callback(_result);
                return;
            }
        }
        else
        {
            debug tracef("Unhandled event on %d", _fileno);
        }
    
    }
    auto io(hlEvLoop loop, in IORequest iorq, in Duration timeout) @safe {

        AppEvent ev = AppEvent.NONE;
        if ( iorq.output && iorq.output.length ) {
            ev |= AppEvent.OUT;
        }
        if ( iorq.to_read > 0 ) {
            ev |= AppEvent.IN;
            _input.reserve(iorq.to_read);
        }
        _pollingFor = ev;
        assert(_pollingFor != AppEvent.NONE);

        if (_io_timer) {
            debug tracef("closing prev timer: %s", _io_timer);
            _loop.stopTimer(_io_timer);
        }

        _loop = loop;
        _iorq = iorq;
        _state = State.IO;
        if ( timeout > 0.seconds ) {
            _io_timer = new Timer(timeout, &io_handler);
            _loop.startTimer(_io_timer);
        }
        _loop.startPoll(_fileno, _pollingFor, this);
        return 0;
    }
    /**
    * just send, no callbacks, no timeouts, nothing
    * returns what os-level send returns
    **/
    long send(immutable(ubyte)[] data) @trusted {
        return .send(_fileno, data.ptr, data.length, 0);
    }
    /**************************************************************************
     * Send data from data buffer
     * input: data     - data to send
     *        timeout  - how long to wait until timedout
     *        callback - callback which accept IOResult
     * 1. try to send as much as possible. If complete data sent, then return
     *    IOresult with empty output and clean timeout and error fileds.
     * 2. If we can't send complete buffer, then prepare io call and return 
     *    nonempty result output.
     * So at return user have to check:
     * a) if result.error == true - send failed
     * b) if result.data.empty - data send completed
     * c) otherwise io call were issued, user will receive callback
     **************************************************************************/
    IOResult send(hlEvLoop loop, immutable(ubyte)[] data, Duration timeout, void delegate(IOResult) @safe callback) @safe {

        enforce!SocketException(data.length > 0, "You must have non-empty 'data' when calling 'send'");

        IOResult result;
        result.output = data;

        uint flags = 0;
        version(linux) {
            flags = MSG_NOSIGNAL;
        }
        auto rc = (() @trusted => .send(_fileno, &data[0], data.length, flags))();
        if ( rc < 0 ) {
            auto err = errno();
            if ( err != EWOULDBLOCK && err != EAGAIN ) {
                // case a.
                result.error = true;
                return result;
            }
            rc = 0; // like we didn't sent anything
        }
        enforce!SocketException(rc > 0, "send must not return 0");
        data = data[rc..$];
        result.output = data;
        if ( result.output.empty ) {
            // case b. send comleted
            debug tracef("fast send to %d completed", _fileno);
            return result;
        }
        // case c. - we have to use event loop
        IORequest iorq;
        iorq.output = data;
        iorq.callback = callback;
        io(loop, iorq, timeout);
        return result;
    }
}


private auto str2inetaddr(string addr) @safe pure {
    auto pos = indexOf(addr, ':');
    if ( pos == -1 ) {
        throw new Exception("incorrect addr %s, expect host:port", addr);
    }
    auto host = addr[0..pos].split('.');
    auto port = addr[pos+1..$];
    // auto s = addr.split(":");
    // if ( s.length != 2 ) {
    //     throw new Exception("incorrect addr %s, expect host:port", addr);
    // }
    // host = s[0].split(".");
    if ( host.length != 4 ) {
        throw new Exception("addr must be in form a.b.c.d:p");
    }
    uint   a = to!ubyte(host[0]) << 24 | to!ubyte(host[1]) << 16 | to!ubyte(host[2]) << 8 | to!ubyte(host[3]);
    ushort p = to!ushort(port);
    return tuple(core.sys.posix.arpa.inet.htonl(a), core.sys.posix.arpa.inet.htons(p));
}

@safe unittest {
    import core.sys.posix.arpa.inet;
    assert(str2inetaddr("0.0.0.0:1") == tuple(0, htons(1)));
    assert(str2inetaddr("1.0.0.0:0") == tuple(htonl(0x01000000),0 ));
    assert(str2inetaddr("255.255.255.255:0") == tuple(0xffffffff, 0));
}

@safe unittest {
    globalLogLevel = LogLevel.info;

    hlSocket s0 = new hlSocket();
    s0.open();
    hlSocket s1 = s0;
    s0.close();
    s1.close();
}

@safe unittest {
    globalLogLevel = LogLevel.info;

    hlSocket s = new hlSocket();
    s.open();
    s.close();
}

//unittest {
//    globalLogLevel = LogLevel.trace;
//
//    hlSocket s = new hlSocket();
//    s.open();
//
//
//    auto mockLoop = new hlEvLoop();
//    mockLoop.run = (Duration d) {
//        s._handler(AppEvent.IN);
//    };
//
//    mockLoop.startPoll = (int fd, AppEvent ev, FileHandlerFunction f) @safe {
//        tracef("called mock startPoll: %d, %s", fd, appeventToString(ev));
//    };
//
//    mockLoop.stopPoll = (int fd, AppEvent ev) @safe {
//        tracef("called mock stopPoll: %d, %s", fd, appeventToString(ev));
//    };
//
//    IORequest iorq;
//    iorq.to_read = 1;
//    iorq.output = "abc".representation();
//    iorq.callback = (IOResult r) {
//        tracef("called mock callback: %s", r);
//    };
//    auto result = s.io(mockLoop, iorq, 1.seconds);
//    mockLoop.run(1.seconds);
//    assert(s._polling == AppEvent.NONE);
//    iorq.to_read = 0;
//    result = s.io(mockLoop, iorq, 1.seconds);
//    mockLoop.run(1.seconds);
//    assert(s._polling == AppEvent.NONE);
//    s.close();
//}

class HioSocket
{
    import core.thread;

    private {
        hlSocket _socket;
        Fiber    _fiber;
    }
    this(ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l = __LINE__) {
        _socket = new hlSocket(af, sock_type, f, l);
        _socket.open();
    }

    this(int fileno, ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l = __LINE__) {
        _socket = new hlSocket(fileno, af, sock_type, f, l);
    }

    ~this() {
        // if ( _socket ) {
        //     _socket.close();
        // }
    }
    override string toString() {
        return _socket.toString();
    }

    void bind(string addr) {
        _socket.bind(addr);
    }
    void handler(AppEvent e) @safe {
        debug
        {
            tracef("HioSocket handler enter");
        }
        (()@trusted{_fiber.call();})();
    };
    void connect(string addr, Duration timeout){
        auto loop = getDefaultLoop();
        _fiber = Fiber.getThis();
        void callback(AppEvent e) {
            if ( !(e & AppEvent.IMMED) ) {
                (() @trusted { _fiber.call(); })();
            }
        }
        if ( _socket.connect(addr, loop, &callback, timeout) ) {
            Fiber.yield();
        }
        infof("Connect state: %s", _socket.connected);
    }
    bool connected() {
        return _socket.connected;
    }
    auto errno() {
        return _socket.socket_errno();
    }
    auto listen(int backlog = 10) {
        return _socket.listen(backlog);
    }
    auto close() {
        if ( _socket ) {
            _socket.close();
            _socket = null;
        }
    }
    auto accept() {
        HioSocket s;

        auto loop = getDefaultLoop();
        _fiber = Fiber.getThis();

        void callback(int fileno) @trusted {
            assert(fileno >= 0);
            debug tracef("got accept callback for socket %d", fileno);
            if ( _socket._polling & AppEvent.IN ) {
                getDefaultLoop.stopPoll(_socket.fileno, AppEvent.IN);
                _socket._polling &= ~AppEvent.IN;
            }
            _socket._state = hlSocket.State.IDLE;
            s = new HioSocket(fileno);
            _fiber.call();
        }
        _socket._accepts_in_a_row = 1;
        _socket.accept(loop, &callback);
        Fiber.yield();
        return s;
    }

    IOResult recv(size_t n, Duration timeout = 10.seconds) {
        IORequest ioreq;
        IOResult  iores;

        _fiber = Fiber.getThis();
        void callback(IOResult ior) @trusted {
            debug tracef("got ior on recv: %s", ior);
            iores = ior;
            _fiber.call();
        }

        ioreq.to_read = n;
        ioreq.callback = &callback;
        _socket.io(getDefaultLoop(), ioreq, timeout);
        debug tracef("recv yielding on %s", _socket);
        Fiber.yield();
        debug tracef("recv done on %s", _socket);
        return iores;
    }

    size_t send(immutable (ubyte)[] data, Duration timeout = 1.seconds) {
        _fiber = Fiber.getThis();
        IOResult ioresult;

        void callback(IOResult ior) @trusted {
            ioresult = ior;
            _fiber.call();
        }
        ioresult = _socket.send(getDefaultLoop(), data, timeout, &callback);
        if ( ioresult.error ) {
            return -1;
        }
        if ( ioresult.output.empty ) {
            return data.length;
        }
        Fiber.yield();
        if (ioresult.error) {
            return -1;
        }
        return data.length - ioresult.output.length;
    }
}
