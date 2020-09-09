module hio.socket;

import std.typecons;
import std.string;
import std.conv;
import std.traits;
import std.datetime;
import std.exception;
import std.algorithm;

import std.algorithm.comparison: min;

import std.experimental.logger;

import core.memory: pureMalloc, GC;
import core.exception : onOutOfMemoryError;

import std.experimental.allocator;
import std.experimental.allocator.building_blocks;

//static import std.socket;

import std.socket;

import core.sys.posix.sys.socket;
import core.sys.posix.unistd;
import core.sys.posix.arpa.inet;
import core.sys.posix.netinet.tcp;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.time : timeval;

import core.sys.posix.fcntl;

import core.stdc.string;
import core.stdc.errno;
import core.stdc.stdio: printf;

public import hio.events;
import hio.common;
import nbuff;

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
//    debug(hiosocket) tracef("loopCallback for %d", fd);
//    hlSocket s = fd2so[fd];
//    if ( s && s._fileno >= 0) {
//        debug(hiosocket) tracef("calling handler(%s) for %s", appeventToString(ev), s);
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

class ConnectionRefused : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
        super(msg, file, line);
    }
}

class Timeout : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
        super(msg, file, line);
    }
}

bool isLinux() pure nothrow @nogc @safe {
    version(linux) {
        return true;
    } else {
        return false;
    }
}

interface AsyncSocketLike
{
    bool open() @safe;
    void close() @safe;
    bool connected() @safe;
    void bind(Address addr);
    bool connect(Address addr, hlEvLoop loop, HandlerDelegate f, Duration timeout) @safe;
    void accept(hlEvLoop loop, Duration timeout, void delegate(AsyncSocketLike) @safe f) @safe;
    int  io(hlEvLoop, ref IORequest, Duration) @safe;
}

// callback based socket
class hlSocket : FileEventHandler, AsyncSocketLike {
    private {
        enum State {
            NEW = 0,
            IDLE,
            CONNECTING,
            ACCEPTING,
            IO,
            SHUTDOWN,
        }
        enum Flags
        {
            EXTERNALLY_MANAGED_FD = 1, // socket fd created and managed outside of this class
        }
        ushort               _flags;
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
        void delegate(AsyncSocketLike) @safe _accept_callback;
        // io related fields
        IORequest           _iorq;
        IOResult            _result;
        Timer                _connect_timer;
        Timer                _io_timer;
        AppEvent             _pollingFor = AppEvent.NONE;
        MutableNbuffChunk    _input;
        size_t               _input_length;
        bool                 _connected;
        uint                 _accepts_in_a_row = 10;
    }
    override string describe() @safe
    {
        return "hlSocket: "
           ~"_state: %s; ".format(_state)
           ~"_file(_line): %s:%s; ".format(_file, _line)
           ~"_fileno: %s; ".format(_fileno)
           ~"_polling: %s; ".format(appeventToString(_polling))
           ~"_connected: %s; ".format(_connected)
           ~"_conn_timer: [%s]; ".format(_connect_timer)
           ~"_io_timer: [%s]; ".format(_io_timer)
           ~"_callback: %s; ".format(_callback)
           ;
    }
    this(ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l =  __LINE__) @safe {
        debug(hiosocket) tracef("create socket");
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
        _flags |= Flags.EXTERNALLY_MANAGED_FD;
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
        assert(_io_timer is null);
        assert(_connect_timer is null);
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

    bool blocking() @property @safe
    {
        auto flags = () @trusted {return fcntl(_fileno, F_GETFL, 0);}();
        return cast(bool)(flags & O_NONBLOCK);
    }
    void blocking(bool blocking) @property @safe {
        auto flags = () @trusted {return fcntl(_fileno, F_GETFL, 0);}();
        if ( blocking ) {
            (() @trusted => fcntl(_fileno, F_SETFL, flags & ~O_NONBLOCK))();
        } else {
            (() @trusted => fcntl(_fileno, F_SETFL, flags | O_NONBLOCK))();
        }
    }
    void timeoutHandler(AppEvent e) @safe {
        debug
        {
            tracef("Timeout handler: %s", appeventToString(e));
        }
        final switch (_state) {
        case State.SHUTDOWN:
            assert(0);
        case State.NEW:
            assert(0);
        case State.IDLE:
            assert(0);
        case State.CONNECTING:
            debug(hiosocket) tracef("connection timed out");
            _connected = false;
            _errno = ETIMEDOUT;
            _polling = AppEvent.NONE;
            _loop.stopPoll(_fileno, AppEvent.OUT);
            _loop.detach(_fileno);
            _state = State.IDLE;
            _connect_timer = null;
            if ( e & AppEvent.SHUTDOWN)
            {
                _state = State.SHUTDOWN;
            }
            _callback(e);
            return;
        case State.ACCEPTING:
            debug(hiosocket) tracef("accept timed out");
            _connected = false;
            _errno = ETIMEDOUT;
            _polling = AppEvent.NONE;
            _loop.stopPoll(_fileno, AppEvent.IN);
            _loop.detach(_fileno);
            _state = State.IDLE;
            if ( e & AppEvent.SHUTDOWN)
            {
                _state = State.SHUTDOWN;
            }
            _accept_callback(null);
            return;
        case State.IO:
            assert(0);
        }
    }
    override void eventHandler(int fd, AppEvent e) @safe {
        debug(hiosocket) tracef("event %s in state %s", appeventToString(e), _state);
        final switch ( _state ) {
        case State.SHUTDOWN:
            return;
            assert(0);
        case State.NEW:
            if ( e & AppEvent.SHUTDOWN)
            {
                _state = State.SHUTDOWN;
                return;
            }
            assert(0);
        case State.IDLE:
            if ( e & AppEvent.SHUTDOWN)
            {
                _state = State.SHUTDOWN;
                return;
            }
            assert(0);
        case State.CONNECTING:
            debug(hiosocket) tracef("connection event: %s", appeventToString(e));
            if ( e & AppEvent.SHUTDOWN)
            {
                _state = State.SHUTDOWN;
                _connected = false;
                if ( _connect_timer )
                {
                    _loop.stopTimer(_connect_timer);
                    _connect_timer = null;
                }
                _polling = AppEvent.NONE;
                _loop.stopPoll(_fileno, AppEvent.OUT);
                _callback(e);
                return;
            }
            assert(e & (AppEvent.OUT|AppEvent.HUP|AppEvent.ERR), "We can handle only OUT event in connecting state, but got %s".format(e));
            if ( e & AppEvent.OUT )
            {
                _connected = true;
            }
            if ( (e & (AppEvent.HUP|AppEvent.ERR)) ) {
                int err;
                uint err_s = err.sizeof;
                auto rc = (() @trusted => .getsockopt(_fileno, SOL_SOCKET, SO_ERROR, &err, &err_s))();
                if ( rc == 0 ) {
                    _errno = err;
                    debug(hiosocket) tracef("error connecting: %s", s_strerror(err));
                }
                _connected = false;
            }
            _polling = AppEvent.NONE;
            if ( e & AppEvent.SHUTDOWN)
            {
                _state = State.SHUTDOWN;
            }
            else
            {
                _state = State.IDLE;
            }
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
              retry:
                int new_s = (() @trusted => .accept(_fileno, &sa, &sa_len))();
                if ( new_s == -1 ) {
                    auto err = errno();
                    if ( err == EINTR )
                    {
                        // restart accept
                        goto retry;
                    }
                    if ( err == EWOULDBLOCK || err == EAGAIN ) {
                        // POSIX.1-2001 and POSIX.1-2008 allow
                        // either error to be returned for this case, and do not require
                        // these constants to have the same value, so a portable
                        // application should check for both possibilities.
                        break;
                    }
                    throw new Exception(s_strerror(err));
                }
                debug(hiosocket) tracef("New socket fd: %d", new_s);
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
                if ( _connect_timer ) {
                    _loop.stopTimer(_connect_timer);
                    _connect_timer = null;
                }
                hlSocket ns = new hlSocket(new_s, _af, _sock_type);
                ns._flags &= ~Flags.EXTERNALLY_MANAGED_FD;
                ns._connected = true;
                if ( e & AppEvent.SHUTDOWN)
                {
                    _state = State.SHUTDOWN;
                }
                _accept_callback(ns);
                debug(hiosocket) tracef("accept_callback for fd: %d - done", new_s);
            }
            //_handler(e);
            return;
        case State.IO:
            io_handler(e);
            return;
        }
    }

    public bool open() @trusted {
        immutable flag = 1;
        if (_fileno != -1) {
            throw new SocketException("You can't open already opened socket: fileno(%d)".format(_fileno));
        }
        _fileno = socket(_af, _sock_type, 0);
        if ( _fileno < 0 )
        {
            _errno = errno();
            return false;
        }
        debug(hiosocket) tracef("new socket created, %s", this);
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
        return true;
    }

    public void close() @safe {
        //assert(_state == State.IDLE);
        if ( _fileno != -1 ) {
            debug(hiosocket) tracef("closing %d, polling: %x", _fileno, _polling);
            if ( _loop  )
            {
                if ( _polling != AppEvent.NONE )
                {
                    debug(hiosocket) tracef("detach from polling for %s", appeventToString(_polling));
                    _loop.stopPoll(_fileno, _polling);
                    _polling = AppEvent.NONE;
                }
                _loop.detach(_fileno);
            }
            if ( (_flags & Flags.EXTERNALLY_MANAGED_FD) == 0 )
            {
                .close(_fileno);
            }
            _fileno = -1;
        }
        if ( _connect_timer )
        {
            debug(hiosocket) tracef("also stop connect timer: %s", _connect_timer);
            _loop.stopTimer(_connect_timer);
            _connect_timer = null;
        }
        if ( _io_timer )
        {
            debug(hiosocket) tracef("also stop io timer: %s", _io_timer);
            _loop.stopTimer(_io_timer);
            _io_timer = null;
        }
        _iorq = IORequest();
        _result = IOResult();
    }
    public void bind(Address addr) @safe
    {
         switch (_af) {
             case AF_INET:
                {
                    import core.sys.posix.netinet.in_;
                    InternetAddress ia = cast(InternetAddress)addr;
                    static int flag = 1;
                    int rc;
                    () @trusted {
                        debug(hiosocket) tracef("binding fileno %s to %s", _fileno, ia);
                        auto rc = .setsockopt(_fileno, SOL_SOCKET, SO_REUSEADDR, &flag, flag.sizeof);
                        debug(hiosocket) tracef("setsockopt for bind result: %d", rc);
                        if ( rc != 0 ) {
                            throw new Exception(to!string(strerror(errno())));
                        }
                        sockaddr_in sa;
                        sa.sin_family = AF_INET;
                        sa.sin_port = htons(ia.port);
                        sa.sin_addr.s_addr = htonl(ia.addr);
                        rc = .bind(_fileno, cast(sockaddr*)&sa, cast(uint)sa.sizeof);
                        debug(hiosocket) {
                            tracef("bind result: %d", rc);
                        }
                        if ( rc != 0 ) {
                            throw new SocketException(to!string(strerror(errno())));
                        }
                    }();
                }
                break;
             case AF_UNIX:
             default:
                 throw new SocketException("unsupported address family");
         }

    }
    public void bind(string addr) @trusted {
         debug(hiosocket) {
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
                    debug(hiosocket) tracef("setsockopt for bind result: %d", rc);
                    if ( rc != 0 ) {
                    throw new Exception(to!string(strerror(errno())));
                    }
                    rc = .bind(_fileno, cast(sockaddr*)&sin, cast(uint)sin.sizeof);
                    debug(hiosocket) {
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
        debug(hiosocket) tracef("listen on %d ok", _fileno);
    }

    public void stopPolling(L)(L loop) @safe {
        debug(hiosocket) tracef("Stop polling on %d", _fileno);
        loop.stopPoll(_fileno, _polling);
    }

    private auto getSndRcvTimeouts() @safe {

        timeval sndtmo, rcvtmo;
        socklen_t tmolen = sndtmo.sizeof;
        auto rc = () @trusted {
            return .getsockopt(_fileno, SOL_SOCKET, SO_SNDTIMEO, &sndtmo, &tmolen);
        }();
        enforce(rc==0, "Failed to get sndtmo");
        debug(hiosocket) tracef("got setsockopt sndtimeo: %d: %s", rc, sndtmo);
        rc = () @trusted {
            return .getsockopt(_fileno, SOL_SOCKET, SO_RCVTIMEO, &rcvtmo, &tmolen);
        }();
        enforce(rc == 0, "Failed to get rcvtmo");
        debug(hiosocket) tracef("got setsockopt sndtimeo: %d: %s", rc, rcvtmo);
        return Tuple!(timeval, "sndtimeo", timeval, "rcvtimeo")(sndtmo, rcvtmo);
    }

    private void setSndRcvTimeouts(Tuple!(timeval, "sndtimeo", timeval, "rcvtimeo") timeouts) @safe {

        timeval sndtmo = timeouts.sndtimeo, rcvtmo = timeouts.rcvtimeo;
        socklen_t tmolen = sndtmo.sizeof;

        auto rc = () @trusted {
            return .setsockopt(_fileno, SOL_SOCKET, SO_SNDTIMEO, &sndtmo, tmolen);
        }();
        debug(hiosocket) tracef("got setsockopt sndtimeo: %d: %s", rc, sndtmo);
        rc = () @trusted {
            return .setsockopt(_fileno, SOL_SOCKET, SO_RCVTIMEO, &rcvtmo, tmolen);
        }();
        debug(hiosocket) tracef("got setsockopt sndtimeo: %d: %s", rc, rcvtmo);
    }

    private void setSndRcvTimeouts(Duration timeout) @safe {
        timeval     ntmo;
        socklen_t   stmo;
        auto vals = timeout.split!("seconds", "usecs")();
        ntmo.tv_sec = cast(typeof(timeval.tv_sec)) vals.seconds;
        ntmo.tv_usec = cast(typeof(timeval.tv_usec)) vals.usecs;
        auto rc = () @trusted {
            return .setsockopt(_fileno, SOL_SOCKET, SO_SNDTIMEO, &ntmo, ntmo.sizeof);
        }();
        debug(hiosocket) tracef("got setsockopt sndtimeo: %d: %s", rc, ntmo);
        rc = () @trusted {
            return .setsockopt(_fileno, SOL_SOCKET, SO_RCVTIMEO, &ntmo, ntmo.sizeof);
        }();
        debug(hiosocket) tracef("got setsockopt rcvtimeo: %d: %s", rc, ntmo);
    }

    ///
    /// connect synchronously (no loop, no fibers)
    /// in blocked mode
    ///
    public bool connect(string addr, Duration timeout) @safe {
        switch (_af) {
        case AF_INET: {
                import core.sys.posix.netinet.in_;
                import core.sys.posix.sys.time: timeval;
                // addr must be "host:port"
                auto internet_addr = str2inetaddr(addr);

                // save old timeout values and set new
                auto old_timeouts = getSndRcvTimeouts();
                setSndRcvTimeouts(timeout);

                auto old_blocking = blocking();
                blocking(true);

                sockaddr_in sin;
                sin.sin_family = _af;
                sin.sin_port = internet_addr[1];
                sin.sin_addr = in_addr(internet_addr[0]);
                uint sa_len = sin.sizeof;
                auto rc = (() @trusted => .connect(_fileno, cast(sockaddr*)&sin, sa_len))();
                auto connerrno = errno();

                blocking(old_blocking);
                // restore timeouts
                setSndRcvTimeouts(old_timeouts);
                if (rc == -1 ) {
                    debug(hiosocket) tracef("connect errno: %s %s", s_strerror(connerrno), sin);
                    _connected = false;
                    _state = State.IDLE;
                    return false;
                }
                _state = State.IDLE;
                _connected = true;
                return true;
            }
        default:
            throw new SocketException("unsupported address family");
        }
    }
    ///
    /// Return true if connect delayed
    ///
    public bool connect(string addr, hlEvLoop loop, HandlerDelegate f, Duration timeout) @safe {
        assert(timeout > 0.seconds);
        debug(hiosocket) tracef("enter connect to: %s", addr);
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
                        debug(hiosocket) tracef("connect so %d to %s errno: %s", _fileno, addr, s_strerror(errno()));
                        _connected = false;
                        _state = State.IDLE;
                        _errno = errno();
                        f(AppEvent.ERR|AppEvent.IMMED);
                        return false;
                    }
                    if ( rc == 0 )
                    {
                        debug(hiosocket) tracef("connected %d immediately to %s", _fileno, addr);
                        _connected = true;
                        _state = State.IDLE;
                        f(AppEvent.OUT|AppEvent.IMMED);
                        return true;
                    }
                    debug(hiosocket) tracef("connect %d to %s - wait for event", _fileno, addr);
                    _loop = loop;
                    _state = State.CONNECTING;
                    _callback = f;
                    _polling |= AppEvent.OUT;
                    _connect_timer = new Timer(timeout, &timeoutHandler);
                    _loop.startTimer(_connect_timer);
                    loop.startPoll(_fileno, AppEvent.OUT, this);
                }
                break;
            default:
                throw new SocketException("unsupported address family");
        }
        return true;
    }

    public bool connect(Address addr, hlEvLoop loop, HandlerDelegate f, Duration timeout) @safe {
        assert(timeout > 0.seconds);
        switch (_af) {
        case AF_INET: {
                debug(hiosocket) tracef("connecting to %s", addr);
                import core.sys.posix.netinet.in_;
                sockaddr_in *sin = cast(sockaddr_in*)(addr.name);
                uint sa_len = sockaddr.sizeof;
                auto rc = (() @trusted => .connect(_fileno, cast(sockaddr*)sin, sa_len))();
                if (rc == -1 && errno() != EINPROGRESS) {
                    debug(hiosocket) tracef("connect to %s errno: %s", addr, s_strerror(errno()));
                    _connected = false;
                    _errno = errno();
                    _state = State.IDLE;
                    f(AppEvent.ERR | AppEvent.IMMED);
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

    override public void accept(hlEvLoop loop, Duration timeout, void delegate(AsyncSocketLike) @safe f) {
        _loop = loop;
        _accept_callback = f;
        _state = State.ACCEPTING;
        _polling |= AppEvent.IN;
        _connect_timer = new Timer(timeout, &timeoutHandler);
        _loop.startTimer(_connect_timer);
        loop.startPoll(_fileno, AppEvent.IN|AppEvent.EXT_EPOLLEXCLUSIVE, this);
    }

    private auto w(ref Nbuff b) @trusted
    {
        import core.sys.posix.sys.uio: iovec, writev;
        iovec[8] iov;
        int n = b.toIoVec(&iov[0], 8);
        msghdr hdr;
        hdr.msg_iov = &iov[0];
        hdr.msg_iovlen = n;
        version(linux)
        {
            int flags = MSG_NOSIGNAL;
        }
        else
        {
            int flags;
        }
        long r = sendmsg(_fileno, &hdr, flags);
        // long r = .writev(_fileno, &iov[0], n);
        return r;
    }

    void io_handler(AppEvent ev) @safe {
        debug(hiosocket) tracef("event %s on fd %d", appeventToString(ev), _fileno);
        if ( ev & AppEvent.SHUTDOWN )
        {
            _state = State.SHUTDOWN;
            if ( _io_timer ) {
                _loop.stopTimer(_io_timer);
                _io_timer = null;
            }
            _result.error = true;
            _iorq.callback(_result);
            return;
        }
        if ( ev == AppEvent.TMO ) {
            debug(hiosocket) tracef("io timedout, %s, %s", _iorq.output, this);
            _loop.stopPoll(_fileno, _pollingFor);
            _polling = AppEvent.NONE;
            _state = State.IDLE;
            if ( !_input.isNull() )
            {
                _result.input = NbuffChunk(_input, _input.length);
            }
            _io_timer = null;
            // return timeout flag
            _result.timedout = true;
            // make callback
            _iorq.callback(_result);
            return;
        }
        if ( ev & AppEvent.IN )
        {
            size_t _will_read = min(_buffer_size, _iorq.to_read);
            debug(hiosocket) tracef("on read: _input.length: %d, _will_read: %d, _input_size: %d", _input_length, _will_read, _input.size);
            assert(_input_length + _will_read <= _input.size);
            auto rc = (() @trusted => recv(_fileno, &_input.data[_input_length], _will_read, 0))();
            debug(hiosocket) tracef("recv on fd %d returned %d", _fileno, rc);
            if ( rc < 0 )
            {
                _state = State.IDLE;
                _result.error = true;
                _polling &= _pollingFor ^ AppEvent.ALL;
                _loop.stopPoll(_fileno, _pollingFor);
                if ( _io_timer ) {
                    _loop.stopTimer(_io_timer);
                    _io_timer = null;
                }
                _result.input = NbuffChunk(_input, _input.length);
                _iorq.callback(_result);
                return;
            }
            if ( rc > 0 )
            {
                // b.length = rc;
                // debug(hiosocket) tracef("adding data %s", b);
                // _input ~= b;
                // b = null;
                _input_length += rc;
                _iorq.to_read -= rc;
                debug(hiosocket) tracef("after adding data have space for %s bytes more, allowPartialInput: %s", _iorq.to_read, _iorq.allowPartialInput);
                if ( _iorq.to_read == 0 || _iorq.allowPartialInput ) {
                    _loop.stopPoll(_fileno, _pollingFor);
                    _polling = AppEvent.NONE;
                    _state = State.IDLE;
                    if ( _io_timer ) {
                        _loop.stopTimer(_io_timer);
                        _io_timer = null;
                    }
                    _result.input = NbuffChunk(_input, _input_length);
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
                _result.input = NbuffChunk(_input, _input_length);
                _polling = AppEvent.NONE;
                _state = State.IDLE;
                _iorq.callback(_result);
                return;
            }
        }
        if ( ev & AppEvent.OUT ) {
            //debug(hiosocket) tracef("sending %s", _iorq.output);
            assert(_result.output.length>0);
            long rc;
            do
            {
                rc = w(_result.output);
                debug(hiosocket) tracef("sent %d bytes", rc);
                if ( rc > 0)
                {
                    _result.output.pop(rc);
                }
            }
            while(rc > 0 && _result.output.length > 0);
            assert(rc != 0);
            if ( rc < 0 && errno() == EAGAIN )
            {
                // can't send right now, just retry, wait for next event
                return;
            }
            if ( rc < 0 ) {
                // error sending
                _loop.stopPoll(_fileno, _pollingFor);
                if ( _io_timer ) {
                    _loop.stopTimer(_io_timer);
                    _io_timer = null;
                }
                if ( !_input.isNull() )
                {
                    _result.input = NbuffChunk(_input, _input_length);
                }
                _polling = AppEvent.NONE;
                _state = State.IDLE;
                _result.error = true;
                _iorq.callback(_result);
                debug(hiosocket) tracef("send completed with error");
                return;
            }
            if ( _result.output.length == 0 ) {
                _loop.stopPoll(_fileno, _pollingFor);
                if ( _io_timer ) {
                    _loop.stopTimer(_io_timer);
                    _io_timer = null;
                }
                if ( !_input.isNull() )
                {
                    _result.input = NbuffChunk(_input, _input_length);
                }
                _polling = AppEvent.NONE;
                _state = State.IDLE;
                _iorq.callback(_result);
                debug(hiosocket) tracef("send completed");
                return;
            }
        }
        else
        {
            debug(hiosocket) tracef("Unhandled event on %d", _fileno);
        }
    
    }
    ///
    /// Make blocking IO without evelnt loop.
    /// Can be called from non-fiber context
    ///
    /// return IOResult
    ///
    IOResult io(IORequest iorq, in Duration timeout) @safe {
        IOResult result;

        version (linux) {
            immutable uint flags = MSG_NOSIGNAL;
        } else {
            immutable uint flags = 0;
        }

        auto old_timeouts = getSndRcvTimeouts();
        setSndRcvTimeouts(timeout);

        scope(exit) {
            setSndRcvTimeouts(old_timeouts);
        }

        debug(hiosocket) tracef("Blocked io request %s", iorq);

        // handle requested output
        result.output = iorq.output;
        while(result.output.length > 0)
        {
            auto rc = w(result.output);
            if ( rc > 0)
            {
                result.output.pop(rc);
                continue;
            }
            assert(rc<0);
            result.error = true;
            return result;
        }
        // handle requested input
        size_t to_read = iorq.to_read;
        if ( to_read > 0 ) {
            //ubyte[] buffer = new ubyte[](to_read);
            auto   buffer = Nbuff.get(to_read);
            size_t ptr, l;

            while(to_read>0) {
                auto rc = () @trusted {
                    return .recv(_fileno, cast(void*)&buffer.data[ptr], to_read, 0);
                }();
                //debug(hiosocket) tracef("got %d bytes to: %s", rc, buffer);
                if ( rc == 0 || (rc > 0 && iorq.allowPartialInput) ) {
                    // client closed connection
                    l += rc;
                    buffer.length = l;
                    result.input = NbuffChunk(buffer, l);
                    debug(hiosocket) tracef("Blocked io returned %s", result);
                    return result;
                }
                if ( rc < 0 ) {
                    buffer.length = l;
                    result.error = true;
                    result.input = NbuffChunk(buffer, l);
                    debug(hiosocket) tracef("Blocked io returned %s (%s)", result, s_strerror(errno()));
                    return result;
                }
                to_read -= rc;
                ptr += rc;
                l += rc;
            }
            buffer.length = l;
            result.input = NbuffChunk(buffer, l);
            debug(hiosocket) tracef("Blocked io returned %s", result);
            return result;
        }
        debug(hiosocket) tracef("Blocked io returned %s", result);
        return result;
    }
    ///
    /// Make unblocked IO using loop
    ///
    int io(hlEvLoop loop, ref IORequest iorq, in Duration timeout) @safe {

        _loop = loop;

        _iorq = iorq;
        _result = IOResult();
        _state = State.IO;

        AppEvent ev = AppEvent.NONE;
        if ( iorq.output.length ) {
            ev |= AppEvent.OUT;
            _result.output = _iorq.output;
        }
        if ( iorq.to_read > 0 ) {
            ev |= AppEvent.IN;
            _input = Nbuff.get(iorq.to_read);
            _input_length = 0;
        }
        _pollingFor = ev;
        assert(_pollingFor != AppEvent.NONE, "No read or write requested");

        if (_io_timer && timeout<=0.seconds) {
            debug(hiosocket) tracef("closing prev timer: %s", _io_timer);
            _loop.stopTimer(_io_timer);
            _io_timer = null;
        }

        if ( timeout > 0.seconds ) {
            if ( _io_timer )
            {
                _io_timer.rearm(timeout);
            } else
            {
                _io_timer = new Timer(timeout, &io_handler);
            }
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
        version(linux)
        {
            int flags = MSG_NOSIGNAL;
        }
        else
        {
            int flags;
        }
        return .send(_fileno, data.ptr, data.length, flags);
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
    IOResult send(hlEvLoop loop, immutable(ubyte)[] data, Duration timeout, void delegate(ref IOResult) @safe callback) @safe {

        enforce!SocketException(data.length > 0, "You must have non-empty 'data' when calling 'send'");

        IOResult result;
        Nbuff o;
        NbuffChunk d = NbuffChunk(data);
        o.append(d);
        result.output = o;

        uint flags = 0;
        version(linux) {
            flags = MSG_NOSIGNAL;
        }
        auto rc = (() @trusted => .send(_fileno, &data[0], data.length, flags))();
	debug(hiosocket) tracef("fast .send so %d rc = %d", _fileno, rc);
        if ( rc < 0 ) {
            auto err = errno();
            if ( err != EWOULDBLOCK && err != EAGAIN ) {
                // case a.
                result.error = true;
                return result;
            }
            rc = 0; // like we didn't sent anything
        }
        //data = data[rc..$];
        debug(hiosocket) tracef(".send result %d", rc);
        result.output = result.output[rc..$];
        if ( result.output.empty ) {
            // case b. send comleted
            debug(hiosocket) tracef("fast send to %d completed", _fileno);
            return result;
        }
        // case c. - we have to use event loop
        IORequest iorq;
        iorq.output = result.output;
        iorq.callback = callback;
        io(loop, iorq, timeout);
        result.output = iorq.output;
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
        throw new Exception("addr must be in form a.b.c.d:p, got: " ~ addr);
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

class HioSocket
{
    import core.thread;

    struct InputStream {
        private {
            size_t      _buffer_size = 16*1024;
            Duration    _timeout = 1.seconds;
            HioSocket   _socket;
            bool        _started;
            bool        _done;
            NbuffChunk  _data;
        }
        this(HioSocket s, Duration t = 10.seconds) @safe {
            _socket = s;
            _timeout = t;
            _buffer_size = s._socket._buffer_size;
        }
        bool empty() {
            return _started && _done;
        }
        auto front() {
            if ( _done ) {
                _data = _data[0..0];
                return _data;
            }
            if (!_started ) {
                _started = true;
                auto r = _socket.recv(_buffer_size, _timeout);
                if (r.timedout || r.error || r.input.length == 0) {
                    _done = true;
                } else {
                    _data = r.input;
                }
            }
            debug(hiosocket) tracef("InputStream front: %s", _data);
            return _data;
        }
        void popFront() {
            auto r = _socket.recv(_buffer_size, _timeout);
            if (r.timedout || r.error || r.input.length == 0) {
                _done = true;
            }
            else {
                _data = r.input;
            }
        }
    }
    private {
        hlSocket _socket;
        Fiber    _fiber;
    }
    this(ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l = __LINE__) @safe {
        _socket = new hlSocket(af, sock_type, f, l);
        if ( _socket.open() == false )
        {
            throw new SocketException("Can't open socket: %s".format(s_strerror(_socket._errno)));
        }
    }

    this(int fileno, ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l = __LINE__) {
        _socket = new hlSocket(fileno, af, sock_type, f, l);
    }

    this(hlSocket so)
    {
        _socket = so;
    }

    ~this() {
        // if ( _socket ) {
        //     _socket.close();
        // }
    }
    override string toString() {
        return _socket.toString();
    }
    void bufferSize(int s)
    {
        _socket._buffer_size = s;
    }
    auto fileno()
    {
        return _socket.fileno;
    }

    void bind(string addr) {
        _socket.bind(addr);
    }
    void handler(AppEvent e) @safe {
        debug
        {
            tracef("HioSocket handler enter %s", e);
        }
        assert(_fiber !is null);
        (()@trusted{_fiber.call();})();
    }
    void connect(Address addr, Duration timeout) @trusted {
        if ( _socket._state == hlSocket.State.SHUTDOWN )
        {
            throw new LoopShutdownException("shutdown before connect");
        }
        auto loop = getDefaultLoop();
        _fiber = Fiber.getThis();
        bool connected;
        void callback(AppEvent e) {
            if ( e & AppEvent.OUT )
            {
                connected = true;
            }
            if (!(e & AppEvent.IMMED)) {
                if ( e & AppEvent.TMO )
                {
                    // timedout;
                    _socket._errno = ETIMEDOUT;
                }
                (() @trusted { _fiber.call(); })();
            }
        }

        if (_socket.connect(addr, loop, &callback, timeout) && !connected)
        {
            Fiber.yield();
        }
        if ( _socket._state == hlSocket.State.SHUTDOWN )
        {
            throw new LoopShutdownException("shutdown while connect");
        }
        if ( _socket._errno == ECONNREFUSED ) {
            throw new ConnectionRefused("Unable to connect socket: connection refused on %s".format(addr));
        }
        if ( ! _socket.connected )
        {
            throw new SocketException("failed to connect to %s: %s".format(addr, s_strerror(_socket._errno)));
        }
    }
    ///
    void connect(string addr, Duration timeout) @trusted {
        assert(_socket);
        if ( _socket._state == hlSocket.State.SHUTDOWN )
        {
            throw new LoopShutdownException("shutdown before connect for %s".format(_socket));
        }
        auto loop = getDefaultLoop();
        _fiber = Fiber.getThis();
        if ( _fiber is null ) {
            // we are not in context of any task, connect synchronously
            // 1. set blocking mode, socket timeout
            // 2. call connect, throw if faied
            // 3. set unblocking mode
            // 4. return
            _socket.blocking = true;
            _socket.connect(addr, timeout);
            _socket.blocking = false;
            return;
        }
        bool connected;
        void callback(AppEvent e) {
            debug(hiosocket) tracef("connect so %d - got event %s", _socket._fileno, appeventToString(e));
            if ( e & AppEvent.OUT )
            {
                connected = true;
            }
            if ( !(e & AppEvent.IMMED) ) {
                // we called yield
                if ( e & AppEvent.TMO )
                {
                    // timedout;
                    _socket._errno = ETIMEDOUT;
                }
                (() @trusted { _fiber.call(); })();
            }
        }
        if ( _socket.connect(addr, loop, &callback, timeout) && !connected)
        {
            debug(hiosocket) tracef("connect so %d - wait for event", _socket._fileno);
            Fiber.yield();
        }
        assert(_socket);
        if ( _socket._state == hlSocket.State.SHUTDOWN )
        {
            throw new LoopShutdownException("shutdown while connect for %s".format(_socket));
        }
        if ( _socket._errno == ECONNREFUSED ) {
            throw new ConnectionRefused("Unable to connect socket: connection refused on " ~ addr);
        }
    }
    ///
    bool connected() const @safe {
        return _socket.connected;
    }
    auto strerror()
    {
        return s_strerror(errno());
    }
    ///
    auto errno() @safe {
        return _socket.socket_errno();
    }
    ///
    auto listen(int backlog = 10) @safe {
        return _socket.listen(backlog);
    }
    ///
    void close() @safe {
        if ( _socket ) {
            assert(_socket._state == hlSocket.State.IDLE
                || _socket._state == hlSocket.State.SHUTDOWN
                || _socket._state == hlSocket.State.NEW,
                "You can call close() on socket only when it is in IDLE state, not in %s(%s)".format(_socket._state, _socket));
            _socket.close();
            _socket = null;
        }
    }
    ///
    private HioSocket _accept_socket;
    void accept_callback(AsyncSocketLike so) scope @trusted {
        debug(hiosocket) tracef("Got %s on accept", so);
        if ( so is null ) {
            _accept_socket = null;
            _fiber.call();
            return;
        }
        debug(hiosocket) tracef("got accept callback for socket %d", fileno);
        if ( _socket._polling & AppEvent.IN ) {
            getDefaultLoop.stopPoll(_socket.fileno, AppEvent.IN);
            _socket._polling &= ~AppEvent.IN;
        }
        _socket._state = hlSocket.State.IDLE;
        _accept_socket = new HioSocket(cast(hlSocket)so);
        _fiber.call();
    }
    auto accept(Duration timeout = Duration.max) {
        HioSocket s;

        auto loop = getDefaultLoop();
        _fiber = Fiber.getThis();

        _socket._accepts_in_a_row = 10;
        _socket.accept(loop, timeout, &accept_callback);
        Fiber.yield();
        if ( _socket._state == hlSocket.State.SHUTDOWN )
        {
            throw new LoopShutdownException("shutdown while accepting");
        }
        return _accept_socket;
    }
    ///
    IOResult recv(size_t n, Duration timeout = 10.seconds, Flag!"allowPartialInput" allowPartialInput = Yes.allowPartialInput) @trusted {
        assert(_socket);
        IORequest ioreq;
        IOResult  iores;
        import core.stdc.stdio;

        ioreq.allowPartialInput = cast(bool)allowPartialInput;

        _fiber = Fiber.getThis();
        if ( _fiber is null) {
            // read not in context of any fiber. Blocked read.
            _socket.blocking = true;
            ioreq.to_read = n;
            iores = _socket.io(ioreq, timeout);
            _socket.blocking = false;
            return iores;
        }
        void callback(ref IOResult ior) @trusted {
            //debug(hiosocket) tracef("got ior on recv: %s", ior);
            iores = ior;
            _fiber.call();
        }

        ioreq.to_read = n;
        ioreq.callback = &callback;
        _socket.io(getDefaultLoop(), ioreq, timeout);
        //debug(hiosocket) infof("recv yielding on %s", _socket);
        Fiber.yield();
        return iores;
    }
    ///
    size_t send(ref Nbuff data, Duration timeout = 1.seconds) @trusted {
        _fiber = Fiber.getThis();
        IOResult  ioresult;
        IORequest iorq;

        if ( _fiber is null ) {
            IORequest ioreq;
            _socket.blocking = true;
            ioreq.output = data;
            ioresult = _socket.io(ioreq, timeout);
            _socket.blocking = false;
            if ( ioresult.error ) {
                return -1;
            }
            return 0;
        }

        void callback(ref IOResult ior) @trusted {
            ioresult = ior;
            _fiber.call();
        }
        iorq.callback = &callback;
        iorq.output = data;

        // ioresult = _socket.send(getDefaultLoop(), data.data.data, timeout, &callback);
        // if ( ioresult.error ) {
        //     return -1;
        // }
        // if ( ioresult.output.empty ) {
        //     return data.length;
        // }
        _socket.io(getDefaultLoop(), iorq, timeout);
        Fiber.yield();
        if (ioresult.error) {
            return -1;
        }
        return data.length - ioresult.output.length;
    }
    ///
    size_t send(immutable (ubyte)[] data, Duration timeout = 1.seconds) @trusted {
        assert(_socket);
        _fiber = Fiber.getThis();
        IOResult ioresult;
        debug(hiosocket) tracef("enter send to so %d", _socket._fileno);

        if ( _fiber is null ) {
            IORequest ioreq;
            _socket.blocking = true;
            ioreq.output = Nbuff(data);
            ioresult = _socket.io(ioreq, timeout);
            _socket.blocking = false;
            if ( ioresult.error ) {
                return -1;
            }
            return 0;
        }

        void callback(ref IOResult ior) @trusted {
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
        assert(_socket);
        if (ioresult.error) {
            return -1;
        }
        return data.length - ioresult.output.length;
    }
    ///
    InputStream inputStream(Duration t=10.seconds) @safe {
        return InputStream(this, t);
    }
}
struct LineReader
{
    private
    {
        enum    NL = "\n".representation;
        HioSocket   _socket;
        Nbuff       _buff;
        size_t      _last_position = 0;
        bool        _done;
        ushort      _buffer_size;
    }
    /// constructor
    this(HioSocket s, ushort bs = 16*1024)
    {
        _socket = s;
        _buffer_size = bs;
    }
    /// if input stream closed or errored
    bool done()
    {
        return _done;
    }
    /// what we have in the buffer after fetching last line
    auto rest()
    {
        return _buff;
    }
    /// read next line
    Nbuff readLine(Duration timeout = 10.seconds)
    {
        while(!_done)
        {
            //debug(hiosocket) tracef("count until NL starting from %d", _last_position);
            long p = _buff.countUntil(NL, _last_position);
            if (p>=0)
            {
                Nbuff line = _buff[0 .. p];
                _last_position = 0;
                _buff.pop(p+1);
                debug(hiosocket) tracef("got line %s", line.data);
                return line;
            }
            _last_position = _buff.length;
            auto r = _socket.recv(_buffer_size, timeout);
            if (r.timedout || r.error || r.input.length == 0) {
                debug(hiosocket) tracef("got terminal result %s", r);
                _done = true;
                return _buff;
            } else {
                debug(hiosocket) tracef("append %d bytes", r.input.length);
                _buff.append(r.input, 0, r.input.length);
            }
        }
        return Nbuff();
    }
}

unittest {
    import core.thread;
    import hio.scheduler;
    void server(ushort port) {
        auto s = new HioSocket();
        scope(exit)
        {
            s.close();
        }
        s.bind("127.0.0.1:%s".format(port));
        s.listen();
        auto c = s.accept(2.seconds);
        if ( c is null ) {
            s.close();
            throw new Exception("Accept failed");
        }
        auto io = c.recv(64, 1.seconds);
        assert(io.input == "hello".representation);
        c.send("world".representation);
        c.close();
        s.close();
    }
    void client(ushort port) {
        auto s = new HioSocket();
        scope(exit) {
            s.close();
        }
        s.connect("127.0.0.1:%d".format(port), 1.seconds);
        if ( s.connected ) {
            auto rq = s.send("hello".representation, 1.seconds);
            auto rs = s.recv(64, 1.seconds);
            assert(rs.input == "world".representation);
        } else {
            throw new Exception("Can't connect to server");
        }
    }
    void hlClient(ushort port)
    {
        auto s = new hlSocket();
        s.open();
        scope(exit)
        {
            s.close();
        }
        auto ok = s.connect("127.0.0.1:%d".format(port), 1.seconds);
        IORequest iorq;
        iorq.output = Nbuff("hello");
        iorq.to_read = 8;
        s.blocking = true;
        IOResult iors = s.io(iorq, 1.seconds);
        assert(iors.input == "world".representation);
        infof("hlClient done");
    }
    globalLogLevel = LogLevel.info;
    info("Test hlSocket");
    auto t = new Thread({
        scope(exit)
        {
            uninitializeLoops();
        }
        try{
            App(&server, cast(ushort)12345);
        } catch (Exception e) {
            infof("Got %s in server", e);
        }
    }).start;
    Thread.sleep(500.msecs);
    hlClient(12345);
    t.join;
    globalLogLevel = LogLevel.info;

    info("Test HioSockets 0");

    // all ok case
    t = new Thread({
        scope(exit)
        {
            uninitializeLoops();
        }
        try{
            App(&server, cast(ushort)12345);
        } catch (Exception e) {
            infof("Got %s in server", e);
        }
    }).start;
    Thread.sleep(500.msecs);
    client(12345);
    t.join;

    info("Test HioSockets 1");
    // all fail case - everything should throw
    t = new Thread({
        scope(exit)
        {
            uninitializeLoops();
        }
        App(&server, cast(ushort) 12345);
    }).start;
    assertThrown!Exception(client(12346));
    assertThrown!Exception(t.join);

    info("Test HioSockets 2");
    // the same but client in App
    // all ok case
    globalLogLevel = LogLevel.info;
    t = new Thread({
        scope(exit)
        {
            uninitializeLoops();
        }
        App(&server, cast(ushort) 12345);
    }).start;
    Thread.sleep(500.msecs);
    App(&client, cast(ushort)12345);
    t.join;

    info("Test HioSockets 3");
    // all fail case - everything should throw
    t = new Thread({
        scope(exit)
        {
            uninitializeLoops();
        }
        App(&server, cast(ushort) 12345);
    }).start;
    assertThrown!Exception(App(&client, cast(ushort)12346));
    assertThrown!Exception(t.join);

    info("Test lineReader");
    globalLogLevel = LogLevel.info;
    t = new Thread({
        scope(exit)
        {
            uninitializeLoops();
        }
        App({
            auto s = new HioSocket();
            s.bind("127.0.0.1:12345");
            s.listen();
            auto c = s.accept(2.seconds);
            if ( c is null ) {
                s.close();
                return;
            }
            foreach(l; ["\n", "a\n", "bb\n"])
            {
                c.send(l.representation, 1.seconds);
            }
            hlSleep(100.msecs);
            c.send("ccc\nrest".representation, 100.msecs);
            c.recv(64, 1.seconds);
            c.close();
            s.close();
        });
    }).start;
    Thread.sleep(100.msecs);
    App({
        auto s = new HioSocket();
        s.connect("127.0.0.1:12345", 10.seconds);
        auto reader = LineReader(s);
        auto e = reader.readLine();
        auto a = reader.readLine();
        auto b = reader.readLine();
        auto c = reader.readLine();
        auto rest = reader.rest();
        s.send("die".representation, 1.seconds);
        assert(e.length == 0);
        assert(a.data == "a".representation);
        assert(b.data == "bb".representation);
        assert(c.data == "ccc".representation);
        assert(rest.data == "rest".representation);
        s.close();
    });
    t.join;
}
