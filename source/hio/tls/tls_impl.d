module hio.tls.tls_impl;

import hio.tls.openssl;
import hio.tls.common;

import std.socket;
import std.datetime;
import std.string;
import std.experimental.logger;

import hio.loop;
import hio.socket;
import hio.scheduler;

import nbuff: NbuffChunk, Nbuff, MutableNbuffChunk;

version(Posix)
{
    // see https://github.com/ikod/hio/issues/1
    import core.sys.posix.signal;
    shared static this()
    {
        signal(SIGPIPE, SIG_IGN);
    }
}

class AsyncSSLSocket : FileEventHandler, AsyncSocketLike
{
    private
    {
        enum State
        {
            INIT,
            CONNECTING,
            ACCEPTING,
            IO,
            IDLE,
            ERROR,
            CLOSED
        }
        //version (openssl11)
        //{
            SSL* _ssl;
            SSL_CTX* _ctx;
        //}
        State               _state;
        hlSocket            _so;
        Duration            _op_timeout = 15.seconds;
        hlEvLoop            _loop;
        Timer               _timer;
        int                 _polling_for;
        HandlerDelegate     _callback;
        void delegate(AsyncSocketLike) @safe _accept_callback;
        bool                _ssl_connected;
        IOResult            _ioResult;
        IOCallback          _ioCallback;
        size_t              _to_receive, _received;
        bool                _allowPartialInput = true;
        MutableNbuffChunk   _input;
        int                 _io_depth; // see io()
        string              _host;     // for SNI
        string              _cert_file;
        string              _key_file;
    }
    this(ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l = __LINE__) @safe
    {
        _so = new hlSocket(af, sock_type, f, l);
    }

    this(hlSocket so) @safe
    {
        _so = so;
    }
    void want_in() @safe
    {
        if( !(_polling_for & AppEvent.IN) )
        {
            _loop.startPoll(_so.fileno, AppEvent.IN, this);
            _polling_for |= AppEvent.IN;
        }
    }
    void stop_in() @safe
    {
        if( _polling_for & AppEvent.IN )
        {
            _loop.stopPoll(_so.fileno, AppEvent.IN);
            _polling_for &= ~AppEvent.IN;
        }
    }
    void want_out() @safe
    {
        if( !(_polling_for & AppEvent.OUT) )
        {
            _loop.startPoll(_so.fileno, AppEvent.OUT, this);
            _polling_for |= AppEvent.OUT;
        }
    }
    void stop_out() @safe
    {
        if( _polling_for & AppEvent.OUT )
        {
            _loop.stopPoll(_so.fileno, AppEvent.OUT);
            _polling_for &= ~AppEvent.OUT;
        }
    }
    override void eventHandler(int fd, AppEvent e)
    {
        debug(hiossl) tracef("got event %s for ssl underlying in state %s", e, _state);
        // here goes all events on underlying socket
        if ( e & AppEvent.IN )
        {
            if ( _state == State.CONNECTING )
            {
                immutable HandlerDelegate cb = _callback;
                immutable connect_result = handleConnectEvent();
                final switch(connect_result)
                {
                    case SSL_connect_call_result.ERROR:
                        _callback = null;
                        stop_in();
                        stop_out();
                        cb(AppEvent.ERR);
                        return;
                    case SSL_connect_call_result.CONNECTED:
                        _ssl_connected = true;
                        _callback = null;
                        _state = State.IDLE;
                        stop_in();
                        stop_out();
                        cb(AppEvent.OUT);
                        return;
                    case SSL_connect_call_result.WANT_READ:
                        debug (hiossl) tracef ("want read");
                        want_in();
                        return;
                    case SSL_connect_call_result.WANT_WRITE:
                        debug (hiossl) tracef ("want write");
                        want_out();
                        return;
                }
                assert(0);
            }
            else if ( _state == State.ACCEPTING )
            {
                immutable cb = _accept_callback;
                immutable connect_result = handleAcceptEvent();
                final switch(connect_result)
                {
                    case SSL_connect_call_result.ERROR:
                        _callback = null;
                        stop_in();
                        stop_out();
                        cb(this);
                        return;
                    case SSL_connect_call_result.CONNECTED:
                        _ssl_connected = true;
                        _callback = null;
                        _state = State.IDLE;
                        stop_in();
                        stop_out();
                        cb(this);
                        return;
                    case SSL_connect_call_result.WANT_READ:
                        debug (hiossl) tracef ("want read");
                        want_in();
                        return;
                    case SSL_connect_call_result.WANT_WRITE:
                        debug (hiossl) tracef ("want write");
                        want_out();
                        return;
                }
                assert(0);
            }
            else if ( _state == State.IO )
            {
                debug(hiossl) tracef("going to read %d bytes more", _to_receive);
                immutable int result = () @trusted {
                    return SSL_read(_ssl, cast(void*)&_input.data[_received], cast(int)_to_receive);
                }();

                if ( result > 0 )
                {
                    // success
                    _received += result;
                    _to_receive -= result;
                    debug(hiossl) tracef("successfully received %d, have to receive %d more", _received, _to_receive);
                    debug(hiossl) tracef("<%s>", cast(string)_input.data[0.._received]);
                    if ( _allowPartialInput )
                    {
                        _state = State.IDLE;
                        _ioResult.input = NbuffChunk(_input, _received);
                        _ioCallback(_ioResult);
                        return;
                    }
                }
                if ( result <= 0)
                {
                    immutable int reason = SSL_get_error(_ssl, result);
                    debug(hiossl) tracef("result %d, reason %d", result, reason);
                    switch(reason)
                    {
                        case SSL_ERROR_WANT_READ:
                            debug (hiossl) tracef ("want read");
                            want_in();
                            return;
                        case SSL_ERROR_WANT_WRITE:
                            debug (hiossl) tracef ("want write");
                            want_out();
                            return;
                        default:
                            stop_in();
                            stop_out();
                            _ioResult.error = true;
                            _state = State.IDLE;
                            _ioCallback(_ioResult);
                            return;
                    }
                }
            }
        }
        if (e & AppEvent.OUT)
        {
            if ( _state == State.CONNECTING )
            {
                immutable HandlerDelegate cb = _callback;
                immutable connect_result = handleConnectEvent();
                final switch(connect_result)
                {
                    case SSL_connect_call_result.ERROR:
                        _callback = null;
                        _state = State.IDLE;
                        stop_in();
                        stop_out();
                        cb(AppEvent.ERR);
                        return;
                    case SSL_connect_call_result.CONNECTED:
                        _ssl_connected = true;
                        _callback = null;
                        _state = State.IDLE;
                        stop_in();
                        stop_out();
                        cb(AppEvent.OUT);
                        return;
                    case SSL_connect_call_result.WANT_READ:
                        debug (hiossl) tracef ("want read");
                        want_in();
                        return;
                    case SSL_connect_call_result.WANT_WRITE:
                        debug (hiossl) tracef ("want write");
                        want_out();
                        return;
                }
                assert(0);
            }
        }
    }

    override bool open() @safe
    {
        _so.open();
        return true;
    }

    override void close() @safe
    {
        _state = State.INIT;
        _ssl_connected = false;
        stop_in();
        stop_out();
        if ( _so )
        {
            _so.close();
            _so = null;
        }
        if ( _ssl )
        {
            SSL_free(_ssl);
            _ssl = null;
        }
        if ( _ctx )
        {
            SSL_CTX_free(_ctx);
            _ctx = null;
        }
        _input.release;
        _ioResult = IOResult();
    }

    override bool connected() @safe
    {
        return _ssl_connected && _so.connected;
    }

    override void bind(Address addr) @safe
    {
        _so.bind(addr);
    }

    private void io_callback(int fd, AppEvent ev)
    {
        debug(hiossl) tracef("read callback on underlying socket");

    }
    private void timer_callback(AppEvent ev) @safe
    {
        debug(hiossl) tracef("timed out");

    }

    private SSL_connect_call_result handleAcceptEvent() @safe
    {
        auto result = SSL_accept(_ssl);
        debug (hiossl) tracef("SSL_accept rc=%d", result);

        if (result == 0)
        {
            long error = ERR_get_error();
            const char* error_str = ERR_error_string(error, null);
            debug (hiossl) tracef ("could not SSL_accept: %s\n", error_str);
            return SSL_connect_call_result.ERROR;
        }
        if (result > 0)
        {
            // connected
            _ssl_connected = true;
            return SSL_connect_call_result.CONNECTED;
        }
        // result < 0, have to continue
        // ssl want read or write
        int ssl_error = SSL_get_error(_ssl, result);
        debug (hiossl) tracef ("SSL_signal: %s", ssl_error);
        switch(ssl_error)
        {
            case SSL_ERROR_WANT_READ:
                debug (hiossl) tracef ("want read");
                return SSL_connect_call_result.WANT_READ;
            case SSL_ERROR_WANT_WRITE:
                debug (hiossl) tracef ("want write");
                return SSL_connect_call_result.WANT_WRITE;
            case SSL_ERROR_SSL:
                debug(hiossl) tracef("ssl handshake failure");
                return SSL_connect_call_result.ERROR;
            default:
                warning("while accepting: %s", SSL_error_strings[ssl_error]);
                return SSL_connect_call_result.ERROR;
        }
    }
    private SSL_connect_call_result handleConnectEvent() @safe
    {
        auto result = SSL_connect(_ssl);
        debug (hiossl) tracef("SSL_connect rc=%d", result);

        if (result == 0)
        {
            long error = ERR_get_error();
            const char* error_str = ERR_error_string(error, null);
            debug (hiossl) tracef ("could not SSL_connect: %s\n", error_str);
            return SSL_connect_call_result.ERROR;
        }
        if (result > 0)
        {
            // connected
            _ssl_connected = true;
            return SSL_connect_call_result.CONNECTED;
        }
        // result < 0, have to continue
        // ssl want read or write
        int ssl_error = SSL_get_error(_ssl, result);
        debug (hiossl) tracef ("SSL_signal: %s", ssl_error);
        switch(ssl_error)
        {
            case SSL_ERROR_WANT_READ:
                debug (hiossl) tracef ("want read");
                return SSL_connect_call_result.WANT_READ;
            case SSL_ERROR_WANT_WRITE:
                debug (hiossl) tracef ("want write");
                return SSL_connect_call_result.WANT_WRITE;
            case SSL_ERROR_SSL:
                debug(hiossl) tracef("ssl handshake failure");
                return SSL_connect_call_result.ERROR;
            default:
                assert(0, SSL_error_strings[ssl_error]);
        }
    }
    void listen(int backlog = 512)
    {
        _so.listen(backlog);
    }
    override void accept(hlEvLoop loop, Duration timeout, void delegate(AsyncSocketLike) @safe callback) @safe
    {
        _loop = loop;
        void so_accept_callback(AsyncSocketLike s) @safe
        {
            debug(hiossl) tracef("ssl callback %s", s);
            if ( s is null )
            {
                callback(s);
                return;
            }
            // set up ssl on this socket
            hlSocket new_so = cast(hlSocket)s;
            assert(new_so.connected);
            AsyncSSLSocket new_ssl_so = new AsyncSSLSocket(new_so);
            new_ssl_so._loop = loop;
            new_ssl_so._so = new_so;
            new_ssl_so._state = State.ACCEPTING;
            new_ssl_so._accept_callback = callback;

            new_ssl_so._ctx = SSL_CTX_new(TLS_server_method());
            if ( _cert_file )
            {
                new_ssl_so._cert_file = _cert_file;
                int r = SSL_CTX_use_certificate_file(new_ssl_so._ctx, toStringz(_cert_file), SSL_FILETYPE_PEM);
                assert(r==1);
            }
            if ( _key_file )
            {
                new_ssl_so._key_file = _key_file;
                int r = SSL_CTX_use_PrivateKey_file(new_ssl_so._ctx, toStringz(_key_file), SSL_FILETYPE_PEM);
                assert(r==1);
            }

            //SSL_CTX_set_cipher_list(new_ssl_so._ctx, &"ALL:!MEDIUM:!LOW"[0]);

            new_ssl_so._ssl = SSL_new(new_ssl_so._ctx);
            SSL_set_fd(new_ssl_so._ssl, cast(int) new_ssl_so._so.fileno);
            SSL_set_accept_state(new_ssl_so._ssl);
            // start negotiation
            auto accept_result = new_ssl_so.handleAcceptEvent();
            final switch(accept_result)
            {
                case SSL_connect_call_result.ERROR:
                    new_ssl_so._state = State.ERROR;
                    callback(new_ssl_so);
                    return;
                case SSL_connect_call_result.CONNECTED:
                    new_ssl_so._ssl_connected = true;
                    _state = State.IDLE;
                    callback(new_ssl_so);
                    return;
                case SSL_connect_call_result.WANT_READ:
                    debug (hiossl) tracef ("want read");
                    new_ssl_so.want_in();
                    return;
                case SSL_connect_call_result.WANT_WRITE:
                    debug (hiossl) tracef ("want write");
                    new_ssl_so.want_out();
                    return;
            }
        }
        _so.accept(_loop, timeout, &so_accept_callback);
    }
    ///
    /// turn on and set "host" for server name indeication(SNI)
    /// call this before call to connect
    ///
    public void set_host(string host) @safe
    {
        _host = host;
    }
    ///
    public void cert_file(string cert_file)
    {
        _cert_file = cert_file;
    }
    ///
    public void key_file(string key_file)
    {
        _key_file = key_file;
    }
    private void SSL_set_tlsext_host_name() @trusted nothrow {
        enum int SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
        enum long TLSEXT_NAMETYPE_host_name = 0;
        if ( _host )
        {
            SSL_ctrl(_ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME,TLSEXT_NAMETYPE_host_name, cast(void*)toStringz(_host));
        }
    }

    override bool connect(Address addr, hlEvLoop loop, HandlerDelegate callback, Duration timeout) @safe
    {
        assert(_loop is null);
        assert(_state == State.INIT);
        assert(_timer is null);
        assert(_callback is null);

        _loop = loop;
        _callback = callback;
        _state = State.CONNECTING;

        void so_connect_callback(AppEvent ev) @safe
        {
            debug (hiossl) tracef("underlying socket event %s", ev);
            if ( ev & AppEvent.TMO )
            {
                debug (hiossl) trace("Connection timeout");
                callback(AppEvent.TMO);
                return;
            }
            if ( ev & (AppEvent.ERR|AppEvent.HUP))
            {
                debug (hiossl) tracef("failed to connect: %d", _so.socket_errno);
                callback(AppEvent.ERR);
                return;
            }
            SSL_set_connect_state(_ssl);
            SSL_set_tlsext_host_name();
            immutable connect_result = handleConnectEvent();
            final switch(connect_result)
            {
                case SSL_connect_call_result.ERROR:
                    _state = State.ERROR;
                    callback(AppEvent.ERR);
                    return;
                case SSL_connect_call_result.CONNECTED:
                    _ssl_connected = true;
                    _state = State.IDLE;
                    callback(AppEvent.OUT);
                    return;
                case SSL_connect_call_result.WANT_READ:
                    debug (hiossl) tracef ("want read");
                    want_in();
                    return;
                case SSL_connect_call_result.WANT_WRITE:
                    debug (hiossl) tracef ("want write");
                    want_out();
                    return;
            }
        }
        _ctx = SSL_CTX_new(TLS_client_method());
        _ssl = SSL_new(_ctx);
        SSL_set_fd(_ssl, cast(int) _so.fileno);
        return _so.connect(addr, loop, &so_connect_callback, timeout);
    }

    int io(hlEvLoop loop, IORequest iorq, Duration timeout) @safe
    {
        assert(iorq.callback !is null);
        assert(connected);
        assert(_state == State.IDLE || _state == State.IO);
        _ioResult = IOResult();
        _ioResult.output = iorq.output;
        _to_receive = iorq.to_read;
        _allowPartialInput = iorq.allowPartialInput;
        _ioCallback = iorq.callback;
        _received = 0;
        _io_depth++;
        scope(exit)
        {
            _io_depth--;
        }

        assert(_io_depth < 10);

        if ( _to_receive > 0 )
        {
            _input = Nbuff.get(_to_receive);
        }

        while(_ioResult.output.length > 0 && !_ioResult.error )
        {
            immutable int result = () @trusted {
                NbuffChunk front = _ioResult.output.frontChunk;
                return SSL_write(_ssl, cast(void*)&front.data[0], cast(int)front.length);
            }();
            if ( result <= 0)
            {
                immutable int reason = SSL_get_error(_ssl, result);
                debug(hiossl) tracef("result %d, reason %s", result, SSL_error_strings[reason]);
                _ioResult.error = true;
                break;
                // _ioCallback(_ioResult);
                // return 0;
            }
            if ( result > 0 )
            {
                debug(hiossl) tracef("sent %d out of %d", result, _ioResult.output.length);
                _ioResult.output.pop(result);
            }
        }

        // try to read as much as possible
        r: while(_to_receive > 0 && !_ioResult.error )
        {
            debug(hiossl) trace("receiving");
            immutable int result = () @trusted {
                return SSL_read(_ssl, cast(void*)&_input.data[_received], cast(int)_to_receive);
            }();
            if ( result > 0 )
            {
                // success
                _received += result;
                _to_receive -= result;
                debug(hiossl) tracef("successfully received %d, have to receive %d more", _received, _to_receive);
                debug(hiossl) tracef("<%s>", cast(string)_input.data[0.._received]);
                continue;
            }
            if ( result <= 0)
            {
                immutable int reason = SSL_get_error(_ssl, result);
                debug(hiossl) tracef("result %d, reason %s", result, SSL_error_strings[reason]);
                switch(reason)
                {
                    case SSL_ERROR_WANT_READ:
                        debug (hiossl) tracef ("want read");
                        want_in();
                        break r;
                    case SSL_ERROR_WANT_WRITE:
                        debug (hiossl) tracef ("want write");
                        want_out();
                        break r;
                    case SSL_ERROR_SYSCALL:
                        auto e = ERR_get_error();
                        debug (hiossl) tracef("syscall error: %s", e);
                        goto default;
                    default:
                        _ioResult.error = true;
                        break;
                        // _ioCallback(_ioResult);
                        // return 0;
                }
            }
        }
        if ( _ioResult.error || (_ioResult.output.empty && _to_receive == 0) || (_received > 0 && _allowPartialInput))
        {
            if ( _received >0 )
            {
                _ioResult.input = NbuffChunk(_input, _received);
            }
            debug(hiossl) tracef("we can return now");
            if ( _io_depth >= 5)
            {
                //
                // as libssl  reads from  socket internally I have next  problem when reads in small
                // portions: if user call io() inside from ioCallback I receive too deep call stack.
                // So if stack become too deep I'll pass call to ioCallback to event loop.
                //
                auto t = new Timer(0.seconds, (AppEvent e){
                    _ioCallback(_ioResult);
                });
                _loop.startTimer(t);
                return 0;
            }
            _ioCallback(_ioResult);
            return 0;
        }
        _state = State.IO;
        return 0;
    }
}

unittest
{
    globalLogLevel = LogLevel.info;
    App({
        AsyncSSLSocket s = new AsyncSSLSocket();
        scope(exit)
        {
            s.close();
        }
        void connected(AppEvent ev)
        {
            debug (hiossl)
                tracef("connected");
        }
        s.open();
        s.connect(new InternetAddress("1.1.1.1", 443), getDefaultLoop(), &connected, 1.seconds);
        hlSleep(1.seconds);
    });
}
