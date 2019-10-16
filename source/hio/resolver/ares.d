module hio.resolver.ares;

import core.sys.posix.sys.select;
import core.sys.posix.netdb;

import std.socket;
import std.string;
import std.typecons;
import std.algorithm;
import std.traits;
import std.bitmanip;

import std.experimental.logger;

import core.thread;

import hio.events;
import hio.loop;
import hio.common;
import hio.scheduler;

struct ares_channeldata;
alias ares_channel = ares_channeldata*;
alias ares_socket_t = int;

enum ARES_SOCKET_BAD = -1;
enum ARES_GETSOCK_MAXNUM = 16;

int  ARES_SOCK_READABLE(uint bits,uint num) @safe @nogc nothrow
{
    return (bits & (1<< (num)));
}
int ARES_SOCK_WRITABLE(uint bits, uint num) @safe @nogc nothrow
{
    return (bits & (1 << ((num) + ARES_GETSOCK_MAXNUM)));
}

enum ARES_SUCCESS = 0;
enum ARES_ENODATA = 1;
enum ARES_EFORMERR = 2;
enum ARES_ESERVFAIL = 3;
enum ARES_ENOTFOUND = 4;
enum ARES_ENOTIMP   = 5;
enum ARES_EREFUSED  = 6;

/* Locally generated error codes */
enum ARES_EBADQUERY = 7;
enum ARES_EBADNAME  = 8;
enum ARES_EBADFAMILY  = 9;
enum ARES_EBADRESP    = 10;
enum ARES_ECONNREFUSED= 11;
enum ARES_ETIMEOUT    = 12;
enum ARES_EOF         = 13;
enum ARES_EFILE       = 14;
enum ARES_ENOMEM      = 15;
enum ARES_EDESTRUCTION= 16;
enum ARES_EBADSTR     = 17;

/* ares_getnameinfo error codes */
enum ARES_EBADFLAGS   =  18;

/* ares_getaddrinfo error codes */
enum ARES_ENONAME     =  19;
enum ARES_EBADHINTS   =  20;

extern(C)
{
    alias    ares_host_callback = void function(void *arg, int status, int timeouts, hostent *he);
    int      ares_init(ares_channel*);
    void     ares_destroy(ares_channel);
    timeval* ares_timeout(ares_channel channel, timeval *maxtv, timeval *tv);
    char*    ares_strerror(int);
    void     ares_gethostbyname(ares_channel channel, const char *name, int family, ares_host_callback callback, void *arg);

    int      ares_fds(ares_channel, fd_set* reads_fds, fd_set* writes_fds);
    int      ares_getsock(ares_channel channel, ares_socket_t* socks, int numsocks) @trusted @nogc nothrow;

    void     ares_process(ares_channel channel, fd_set *read_fds, fd_set *write_fds);
    void     ares_process_fd(ares_channel channel, ares_socket_t read_fd, ares_socket_t write_fd) @trusted @nogc nothrow;
    void     ares_library_init();
    void     ares_library_cleanup();
}

alias ResolverCallbackFunction = void function(int status, InternetAddress[] addresses);
alias ResolverCallbackDelegate = void delegate(int status, InternetAddress[] addresses);
alias ResolverCallbackFunction6 = void function(int status, Internet6Address[] addresses);
alias ResolverCallbackDelegate6 = void delegate(int status, Internet6Address[] addresses);

alias ResolverResult4 = Tuple!(int, "status", InternetAddress[], "addresses");
alias ResolverResult6 = Tuple!(int, "status", Internet6Address[], "addresses");
alias ResolverResult = ResolverResult4;

shared static this()
{
    ares_library_init();
}
shared static ~this()
{
    ares_library_cleanup();
}

package static Resolver theResolver;
static this() {
    theResolver = new Resolver();
}

public auto hio_gethostbyname(string host)
{
    return theResolver.gethostbyname(host);
}

public auto hio_gethostbyname6(string host)
{
    return theResolver.gethostbyname6(host);
}
///
auto ares_statusString(int status)
{
    return fromStringz(ares_strerror(status));
}

package class Resolver: FileEventHandler
{
    private
    {
        ares_channel                        _ares_channel;
        hlEvLoop                            _loop;
        bool[ARES_GETSOCK_MAXNUM]           _in_read;
        bool[ARES_GETSOCK_MAXNUM]           _in_write;
        ares_socket_t[ARES_GETSOCK_MAXNUM]  _sockets;
        int                                 _id;
        ResolverCallbackFunction[int]       _cbFunctions;
        ResolverCallbackDelegate[int]       _cbDelegates;
        ResolverCallbackFunction6[int]      _cb6Functions;
        ResolverCallbackDelegate6[int]      _cb6Delegates;
    }

    this()
    {
        immutable init_res = ares_init(&_ares_channel);
        assert(init_res == ARES_SUCCESS, "Can't initialise ares.");
    }
    ~this()
    {
        close();
    }
    void close()
    {
        if (_ares_channel)
        {
            ares_destroy(_ares_channel);
        }
    }

    private ares_host_callback host_callback4 = (void *arg, int status, int timeouts, hostent* he)
    {
        int id = cast(int)arg;
        InternetAddress[] result;
        debug tracef("got callback from ares s:\"%s\" t:%d h:%s, id: %d", fromStringz(ares_strerror(status)), timeouts, he, id);

        Resolver resolver = theResolver;
        if (status == 0 && he !is null && he.h_addrtype == AF_INET)
        {
            debug tracef("he=%s", fromStringz(he.h_name));
            debug tracef("h_length=%X", he.h_length);
            auto a = he.h_addr_list;
            while( *a )
            {
                uint addr;
                for (int i; i < he.h_length; i++)
                {
                    addr = addr << 8;
                    addr += (*a)[i];
                }
                result ~= new InternetAddress(addr, InternetAddress.PORT_ANY);
                a++;
            }
        }
        else
        {
            debug tracef("callback failed: %d", status);
        }
        auto cbf = id in resolver._cbFunctions;
        auto cbd = id in resolver._cbDelegates;
        debug tracef("cbf: %s, cbd: %s", cbd, cbf);
        if (cbf !is null)
        {
            auto cb = *cbf;
            resolver._cbFunctions.remove(id);
            cb(status, result);
        }
        else if (cbd !is null)
        {
            auto cb = *cbd;
            resolver._cbDelegates.remove(id);
            cb(status, result);
        }
    };

    private ares_host_callback host_callback6 = (void *arg, int status, int timeouts, hostent* he)
    {
        int id = cast(int)arg;
        Internet6Address[] result;
        debug tracef("got callback from ares s:\"%s\" t:%d h:%s, id: %d", fromStringz(ares_strerror(status)), timeouts, he, id);

        Resolver resolver = theResolver;
        if (status == 0 && he !is null && he.h_addrtype == AF_INET6)
        {
            if (he is null)
            {
                return;
            }
            debug tracef("he=%s", fromStringz(he.h_name));
            debug tracef("h_length=%X", he.h_length);
            auto a = he.h_addr_list;
            while(*a)
            {
                ubyte[16] *addr = cast(ubyte[16]*)*a;
                result ~= new Internet6Address(*addr, Internet6Address.PORT_ANY);
                a++;
            }
        }
        else
        {
            debug tracef("callback failed: %d", status);
        }
        auto cbf = id in resolver._cb6Functions;
        auto cbd = id in resolver._cb6Delegates;
        debug tracef("cbf: %s, cbd: %s", cbd, cbf);
        if (cbf !is null)
        {
            auto cb = *cbf;
            resolver._cb6Functions.remove(id);
            cb(status, result);
        }
        else if (cbd !is null)
        {
            auto cb = *cbd;
            resolver._cb6Delegates.remove(id);
            cb(status, result);
        }
    };
    ///
    /// gethostbyname which wait for result (can be called w/o eventloop or inside of task)
    ///
    ResolverResult4 gethostbyname(string hostname)
    {
        int                 status, id;
        InternetAddress[]   adresses;
        bool                done;

        _id++;

        debug tracef("start resolving %s", hostname);
        auto fiber = Fiber.getThis();
        if (fiber is null)
        {
            void cba(int s, InternetAddress[] a)
            {
                status = s;
                adresses = a;
                done = true;
                _cbDelegates.remove(id);
                debug tracef("resolve for %s: %s, %s", hostname, ares_strerror(s), a);
            }
            id = _id;
            _cbDelegates[_id] = &cba;
            ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET, host_callback4, cast(void*)_id);
            if ( done )
            {
                // resolved from files
                debug tracef("return ready result");
                return ResolverResult(status, adresses);
            }
            // called without loop/callback, we can and have to block
            int nfds, count;
            fd_set readers, writers;
            timeval tv;
            timeval *tvp;

            while (!done) {
                FD_ZERO(&readers);
                FD_ZERO(&writers);
                nfds = ares_fds(_ares_channel, &readers, &writers);
                if (nfds == 0)
                    break;
                tvp = ares_timeout(_ares_channel, null, &tv);
                count = select(nfds, &readers, &writers, null, tvp);
                ares_process(_ares_channel, &readers, &writers);
            }
            return ResolverResult(status, adresses);
        }
        else
        {
            bool yielded;
            void cbb(int s, InternetAddress[] a)
            {
                status = s;
                adresses = a;
                done = true;
                debug tracef("resolve for %s: %s, %s, yielded: %s", hostname, ares_strerror(s), a, yielded);
                if (yielded) fiber.call();
                debug tracef("done");
            }
            if (!_loop)
            {
                _loop = getDefaultLoop();
            }
            id = _id;
            _cbDelegates[_id] = &cbb;
            ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET, host_callback4, cast(void*)_id);
            if ( done )
            {
                // resolved from files
                debug tracef("return ready result");
                return ResolverResult(status, adresses);
            }
            auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
            debug tracef("getsocks: 0x%04X, %s", rc, _sockets);
            // prepare listening for socket events
            handleGetSocks(rc, &_sockets);
            yielded = true;
            Fiber.yield();
            return ResolverResult(status, adresses);
        }
    }
    ///
    /// gethostbyname which wait for result (can be called w/o eventloop or inside of task)
    ///
    ResolverResult6 gethostbyname6(string hostname)
    {
        int                 status, id;
        Internet6Address[]  adresses;
        bool                done;

        _id++;

        debug tracef("start resolving %s", hostname);
        auto fiber = Fiber.getThis();
        if (fiber is null)
        {
            void cba(int s, Internet6Address[] a)
            {
                status = s;
                adresses = a;
                done = true;
                _cb6Delegates.remove(id);
                debug tracef("resolve for %s: %s, %s", hostname, ares_strerror(s), a);
            }
            id = _id;
            _cb6Delegates[_id] = &cba;
            ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET6, host_callback6, cast(void*)_id);
            if ( done )
            {
                // resolved from files
                debug tracef("return ready result");
                return ResolverResult6(status, adresses);
            }
            // called without loop/callback, we can and have to block
            int nfds, count;
            fd_set readers, writers;
            timeval tv;
            timeval *tvp;

            while (!done) {
                FD_ZERO(&readers);
                FD_ZERO(&writers);
                nfds = ares_fds(_ares_channel, &readers, &writers);
                if (nfds == 0)
                    break;
                tvp = ares_timeout(_ares_channel, null, &tv);
                count = select(nfds, &readers, &writers, null, tvp);
                ares_process(_ares_channel, &readers, &writers);
            }
            return ResolverResult6(status, adresses);
        }
        else
        {
            bool yielded;
            void cbb(int s, Internet6Address[] a)
            {
                status = s;
                adresses = a;
                done = true;
                debug tracef("resolve for %s: %s, %s, yielded: %s", hostname, ares_strerror(s), a, yielded);
                if (yielded) fiber.call();
                debug tracef("done");
            }
            if (!_loop)
            {
                _loop = getDefaultLoop();
            }
            id = _id;
            _cb6Delegates[_id] = &cbb;
            ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET6, host_callback6, cast(void*)_id);
            if ( done )
            {
                // resolved from files
                debug tracef("return ready result");
                return ResolverResult6(status, adresses);
            }
            auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
            debug tracef("getsocks: 0x%04X, %s", rc, _sockets);
            // prepare listening for socket events
            handleGetSocks(rc, &_sockets);
            yielded = true;
            Fiber.yield();
            return ResolverResult6(status, adresses);
        }
    }

    private void handleGetSocks(int rc, ares_socket_t[ARES_GETSOCK_MAXNUM] *s) @safe
    {
        for(int i; i < ARES_GETSOCK_MAXNUM;i++)
        {
            if (ARES_SOCK_READABLE(rc, i) && !_in_read[i])
            {
                debug tracef("add ares socket %s to IN events", (*s)[i]);
                _loop.startPoll((*s)[i], AppEvent.IN, this);
                _in_read[i] = true;
            }
            else if (!ARES_SOCK_READABLE(rc, i) && _in_read[i])
            {
                debug tracef("detach ares socket %s from IN events", (*s)[i]);
                _loop.stopPoll((*s)[i], AppEvent.IN);
                _in_read[i] = false;
            }
            if (ARES_SOCK_WRITABLE(rc, i) && !_in_write[i])
            {
                debug tracef("add ares socket %s to OUT events", (*s)[i]);
                _loop.startPoll((*s)[i], AppEvent.OUT, this);
                _in_write[i] = true;
            }
            else if (!ARES_SOCK_WRITABLE(rc, i) && _in_write[i])
            {
                debug tracef("detach ares socket %s from OUT events", (*s)[i]);
                _loop.stopPoll((*s)[i], AppEvent.OUT);
                _in_write[i] = true;
            }
        }
    }

    //
    // call ares_process_fd for evented socket (may call completion callback),
    // check againg for list of sockets to listen,
    // prepare to listening.
    //
    override void eventHandler(int f, AppEvent ev)
    {
        debug tracef("handler: %d, %s", f, ev);
        int socket_index;
        ares_socket_t rs = ARES_SOCKET_BAD, ws = ARES_SOCKET_BAD;

        if (f==_sockets[0])
        {
            // 99.99 %% case
            socket_index = 0;
        }
        else
        {
            for(socket_index=1;socket_index<ARES_GETSOCK_MAXNUM;socket_index++)
            if (f==_sockets[socket_index])
            {
                break;
            }
        }
        // we'll got range violation in case we didn't find socket
        // ares_process() can close socket for its own reasons
        // so we have to detach descriptor.
        // If we do not - we will have closed socket in polling system.
        if (ev & AppEvent.OUT)
        {
            _loop.stopPoll(f, AppEvent.OUT);
            _in_write[socket_index] = false;
            ws = f;
        }
        if (ev & AppEvent.IN)
        {
            _loop.stopPoll(f, AppEvent.IN);
            _in_read[socket_index] = false;
            rs = f;
        }
        ares_process_fd(_ares_channel, rs, ws);
        auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
        debug tracef("getsocks: 0x%04X, %s", rc, _sockets);
        // prepare listening for socket events
        handleGetSocks(rc, &_sockets);
    }

    ///
    /// increment request id,
    /// register callbacks in resolver,
    /// start listening on sockets.
    ///
    auto gethostbyname(F)(string hostname, hlEvLoop loop, F cb) if (isCallable!F)
    {
        assert(!_loop || _loop == loop);
        if (_loop is null)
        {
            _loop = loop;
        }
        _id++;
        static if (isDelegate!F)
        {
            _cbDelegates[_id] = cb;
        }
        else
        {
            _cbFunctions[_id] = cb;
        }
        ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET, host_callback4, cast(void*)_id);
        auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
        debug tracef("getsocks: 0x%04X, %s", rc, _sockets);
        // prepare listening for socket events
        handleGetSocks(rc, &_sockets);
    }
    auto gethostbyname6(F)(string hostname, hlEvLoop loop, F cb) if (isCallable!F)
    {
        assert(!_loop || _loop == loop);
        if (_loop is null)
        {
            _loop = loop;
        }
        _id++;
        static if (isDelegate!F)
        {
            _cb6Delegates[_id] = cb;
        }
        else
        {
            _cb6Functions[_id] = cb;
        }
        ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET6, host_callback6, cast(void*)_id);
        auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
        debug tracef("getsocks: 0x%04X, %s", rc, _sockets);
        // prepare listening for socket events
        handleGetSocks(rc, &_sockets);
    }
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/sync  INET4 ===");
    auto resolver = theResolver;
    auto r = resolver.gethostbyname("localhost");
    assert(r.status == 0);
    debug tracef("%s", r);
    r = resolver.gethostbyname("8.8.8.8");
    assert(r.status == 0);
    debug tracef("%s", r);
    r = resolver.gethostbyname("dlang.org");
    assert(r.status == 0);
    debug tracef("%s", r);
    r = resolver.gethostbyname(".......");
    assert(r.status != 0);
    debug tracef("%s", r);
    if (r.status != 0) 
    {
        tracef("status: %s", ares_statusString(r.status));
    }
    r = resolver.gethostbyname("iuytkjhcxbvkjhgfaksdjf");
    assert(r.status != 0);
    debug tracef("%s", r);
    if (r.status != 0) 
    {
        tracef("status: %s", ares_statusString(r.status));
    }
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/sync  INET6 ===");
    auto resolver = theResolver;
    auto r = resolver.gethostbyname6("localhost");
    assert(r.status == 0);
    debug tracef("%s", r);
    r = resolver.gethostbyname6("8.8.8.8");
    assert(r.status == 0);
    debug tracef("%s", r);
    r = resolver.gethostbyname6("dlang.org");
    assert(r.status == 0);
    debug tracef("%s", r);
    r = resolver.gethostbyname6(".......");
    assert(r.status != 0);
    debug tracef("%s", r);
    if (r.status != 0) 
    {
        tracef("status: %s", ares_statusString(r.status));
    }
}

unittest
{
    import std.array: array;
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/async INET4 ===");
    auto resolver = theResolver;
    auto app(string hostname)
    {
        int status;
        InternetAddress[] adresses;
        Fiber fiber = Fiber.getThis();
        bool done;
        bool yielded;

        void cb(int s, InternetAddress[] a)
        {
            status = s;
            adresses = a;
            done = true;
            debug tracef("resolve for %s: %s, %s", hostname, fromStringz(ares_strerror(s)), a);
            if (yielded)
            {
                fiber.call();
            }
        }
        auto loop = getDefaultLoop();
        resolver.gethostbyname(hostname, loop, &cb);
        if (!done)
        {
            yielded = true;
            Fiber.yield();
        }
        return adresses;
    }
    auto names = ["dlang.org", "google.com", ".."];
    auto tasks = names.map!(n => task(&app, n)).array;
    try
    {
        tasks.each!(t => t.start);
        getDefaultLoop.run(2.seconds);
        assert(tasks.all!(t => t.ready));
    }
    catch (Throwable e)
    {
        errorf("%s", e);
    }
}
unittest
{
    import std.array: array;
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/async INET6 ===");
    auto resolver = theResolver;
    auto app(string hostname)
    {
        int status;
        Internet6Address[] adresses;
        Fiber fiber = Fiber.getThis();
        bool done;
        bool yielded;

        void cb(int s, Internet6Address[] a)
        {
            status = s;
            adresses = a;
            done = true;
            debug tracef("resolve for %s: %s, %s", hostname, fromStringz(ares_strerror(s)), a);
            if (yielded)
            {
                fiber.call();
            }
        }
        auto loop = getDefaultLoop();
        resolver.gethostbyname6(hostname, loop, &cb);
        if (!done)
        {
            yielded = true;
            Fiber.yield();
        }
        return adresses;
    }
    auto names = ["dlang.org", "google.com", "cloudflare.com", ".."];
    auto tasks = names.map!(n => task(&app, n)).array;
    try
    {
        tasks.each!(t => t.start);
        getDefaultLoop.run(2.seconds);
        assert(tasks.all!(t => t.ready));
    }
    catch (Throwable e)
    {
        errorf("%s", e);
    }
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/App   INET4 ===");
    App({
        import std.array: array;
        auto resolve(string name)
        {
            auto r = theResolver.gethostbyname(name);
            debug tracef("app resolved %s=%s", name, r);
            return r;
        }
        auto names = [
            "dlang.org",
            "google.com",
            "a.root-servers.net.",
            "b.root-servers.net.",
            "c.root-servers.net.",
            "d.root-servers.net.",
            "e.root-servers.net.",
            "...",
        ];
        auto tasks = names.map!(n => task(&resolve, n)).array;
        tasks.each!(t => t.start);
        tasks.each!(t => t.wait);
    });
}
unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/App   INET6 ===");
    App({
        import std.array: array;
        auto resolve(string name)
        {
            auto r = theResolver.gethostbyname6(name);
            debug tracef("app resolved %s=%s", name, r);
            return r;
        }
        auto names = [
            "dlang.org",
            "google.com",
            "a.root-servers.net.",
            "b.root-servers.net.",
            "c.root-servers.net.",
            "d.root-servers.net.",
            "e.root-servers.net.",
            ".....",
        ];
        auto tasks = names.map!(n => task(&resolve, n)).array;
        tasks.each!(t => t.start);
        tasks.each!(t => t.wait);
        //tasks.each!(t => writeln(t.result.status));
    });
}