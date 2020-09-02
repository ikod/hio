module hio.resolver.ares;

import core.sys.posix.sys.select;
import core.sys.posix.netdb;

import std.socket;
import std.string;
import std.typecons;
import std.algorithm;
import std.traits;
import std.bitmanip;
import std.array;
import std.datetime;
import std.exception: assumeUnique;
import std.experimental.logger;

import core.thread;

import ikod.containers.hashmap: HashMap;


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

struct ares_addrttl {
    in_addr   ipaddr;
    int       ttl;
}

alias ares_in6_addr = ubyte[16];
struct ares_addr6ttl {
    ares_in6_addr ip6addr;
    int           ttl;
}

enum sec2hnsec = 10_000_000;
enum ns_c_in = 1;
enum ns_t_a  = 1;
enum ns_t_aaaa = 28;

string resolver_errno(int r) @trusted
{
    import std.conv: to;
    return to!string(ares_strerror(r));
}

private extern(C)
{
    alias    ares_host_callback = void function(void *arg, int status, int timeouts, hostent *he);
    alias    ares_callback =      void function(void *arg, int status, int timeouts, ubyte *abuf, int alen);
    int      ares_init(ares_channel*) @trusted;
    void     ares_destroy(ares_channel);
    timeval* ares_timeout(ares_channel channel, timeval *maxtv, timeval *tv);
    char*    ares_strerror(int);
    void     ares_gethostbyname(ares_channel channel, const char *name, int family, ares_host_callback callback, void *arg);
    int      ares_gethostbyname_file(ares_channel channel, const char *name, int family, hostent **host);
    void     ares_free_hostent(hostent *host) @trusted;
    void     ares_query(ares_channel channel, const char *name, int dnsclass, int type, ares_callback callback, void *arg);
    int      ares_parse_a_reply(ubyte *abuf, int alen, hostent **host, ares_addrttl *addrttls, int *naddrttls);
    int      ares_parse_aaaa_reply(ubyte *abuf, int alen, hostent **host, ares_addr6ttl *addrttls, int *naddrttls);
    int      ares_fds(ares_channel, fd_set* reads_fds, fd_set* writes_fds);
    int      ares_getsock(ares_channel channel, ares_socket_t* socks, int numsocks) @trusted @nogc nothrow;

    void     ares_process(ares_channel channel, fd_set *read_fds, fd_set *write_fds);
    void     ares_process_fd(ares_channel channel, ares_socket_t read_fd, ares_socket_t write_fd) @trusted @nogc nothrow;
    void     ares_library_init();
    void     ares_library_cleanup();
}

alias ResolverCallbackFunction = void function(int status, uint[] addresses);
alias ResolverCallbackDelegate = void delegate(int status, uint[] addresses);
alias ResolverCallbackFunction6 = void function(int status, ubyte[16][] addresses);
alias ResolverCallbackDelegate6 = void delegate(int status, ubyte[16][] addresses);

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
///
// lazy singleton per thread
// allocated on first call to any of hio_gethostbyname*
// when variant with callback used - default event loop drives socket non-blocking ops
///
package static Resolver theResolver;

static ~this()
{
    if (theResolver)
    {
        if (theResolver._cacheCleaner)
        {
            // can't call stopTimer from dtor (no nogc)
            //getDefaultLoop().stopTimer(theResolver._cacheCleaner);
            theResolver._cacheCleaner = null;
        }
        theResolver.close();
        theResolver = null;
    }
}

/// gethostbyname IPv4 "blocking" variant
public ResolverResult4 hio_gethostbyname(string host, ushort port=InternetAddress.PORT_ANY)
{
    if ( theResolver is null)
    {
        theResolver = new Resolver();
        theResolver._loop = getDefaultLoop();
    }
    return gethostbyname(host, port);
}
/// gethostbyname IPv4 "non-blocking" variant
public void hio_gethostbyname(F)(string host, F callback, ushort port=InternetAddress.PORT_ANY) if (isCallable!F)
{
    if ( theResolver is null)
    {
        theResolver = new Resolver();
    }
    void cb(int s, uint[] a) @safe
    {
        InternetAddress[] addresses;
        foreach (ia; a) {
            addresses ~= new InternetAddress(ia, port);
        }
        callback(s, addresses);
    }
    if ( theResolver._loop is null )
    {
        theResolver._loop = getDefaultLoop();
    }
    gethostbyname(host, &cb);
}

/// gethostbyname IPv6 "blocking" variant
public ResolverResult6 hio_gethostbyname6(string host, ushort port=Internet6Address.PORT_ANY)
{
    if ( theResolver is null)
    {
        theResolver = new Resolver();
        theResolver._loop = getDefaultLoop();
    }
    return gethostbyname6(host, port);
}

/// gethostbyname IPv6 "non-blocking" variant
public void hio_gethostbyname6(F)(string host, F callback, ushort port=InternetAddress.PORT_ANY) if (isCallable!F)
{
    if ( theResolver is null)
    {
        theResolver = new Resolver();
    }
    void cb(int s, ubyte[16][] a) @safe
    {
        Internet6Address[] addresses;
        foreach (ia; a) {
            addresses ~= new Internet6Address(ia, port);
        }
        callback(s, addresses);
    }
    if ( theResolver._loop is null )
    {
        theResolver._loop = getDefaultLoop();
    }
    gethostbyname6(host, &cb);
}

package ResolverResult4 gethostbyname(string hostname, ushort port=InternetAddress.PORT_ANY)
in(theResolver !is null)
{
    int                 status, id;
    InternetAddress[]   addresses;
    bool                done;
    auto                now = Clock.currStdTime;
    DNSCacheEntry       dnsInfo;

    // try to convert string to addr
    int addr;
    int p = inet_pton(AF_INET, toStringz(hostname), &addr);
    if (p > 0)
    {
        debug(hioresolve) tracef("address converetd from %s", hostname, p);
        return ResolverResult4(ARES_SUCCESS, [new InternetAddress(ntohl(addr), port)]);
    }
    // lookup in cache
    auto f = theResolver._cache.fetch(hostname);
    if ( f.ok && (now - f.value._timestamp < f.value._ttl) )
    {
        debug(hioresolve) tracef("return cached resolve for \"%s\" with status %s", hostname, ares_statusString(f.value._status));
        foreach(ia; f.value._addresses)
        {
            addresses ~= new InternetAddress(ia, port);
        }
        return ResolverResult4(f.value._status, addresses);
    }
    // resolve from /etc/hosts
    dnsInfo = theResolver.resolve4FromFile(hostname);
    if (dnsInfo._status == ARES_SUCCESS)
    {
        debug(hioresolve) tracef("return resolved from file for \"%s\" with status %s", hostname, ares_statusString(dnsInfo._status));
        foreach(ia; dnsInfo._addresses)
        {
            addresses ~= new InternetAddress(ia, port);
        }
        theResolver._cache.put(hostname, dnsInfo);
        return ResolverResult4(ARES_SUCCESS, addresses);
    }

    debug(hioresolve) tracef("start resolving %s", hostname);
    //
    id = ++theResolver._id;
    auto fiber = Fiber.getThis();
    if (fiber is null)
    {
        void cba(int s, uint[] a)
        {
            status = s;
            foreach(ia; a)
            {
                addresses ~= new InternetAddress(ia, port);
            }
            done = true;
            theResolver._cb4d.remove(id);
            debug(hioresolve) tracef("resolve for %s: %s, %s", hostname, ares_statusString(s), a);
        }
        theResolver._cb4d[id] = Callback4InfoD(hostname, &cba);
        ares_query(theResolver._ares_channel, toStringz(hostname), ns_c_in, ns_t_a, theResolver.ares_callback4, cast(void*)id);
        if ( done )
        {
            // resolved from files
            debug(hioresolve) tracef("return ready result");
            return ResolverResult(status, addresses);
        }
        // called without loop/callback, we can and have to block
        int nfds, count;
        fd_set readers, writers;
        timeval tv;
        timeval *tvp;

        while (!done) {
            FD_ZERO(&readers);
            FD_ZERO(&writers);
            nfds = ares_fds(theResolver._ares_channel, &readers, &writers);
            if (nfds == 0)
                break;
            tvp = ares_timeout(theResolver._ares_channel, null, &tv);
            count = select(nfds, &readers, &writers, null, tvp);
            ares_process(theResolver._ares_channel, &readers, &writers);
        }
        return ResolverResult(status, addresses);
    }
    else
    {
        assert(theResolver._loop !is null, "Improper call, probably you have to use hio_gethostbyname variant");
        bool yielded;
        void cbb(int s, uint[] a)
        {
            status = s;
            foreach (ia; a) {
                addresses ~= new InternetAddress(ia, port);
            }
            done = true;
            theResolver._cb4d.remove(id);
            debug(hioresolve) tracef("resolve for %s: %s, %s, yielded: %s", hostname, ares_strerror(s), a, yielded);
            if (yielded) fiber.call();
        }
        // handleLockedFibers call callbacks for concurrent resolves
        // when first resolution completes
        void handleLockedFibers()
        {
            if ( theResolver._lockingEnabled )
            {
                auto inActiveResolving = theResolver._activeResolves4d.fetch(hostname);
                assert(inActiveResolving.ok);
                foreach (cb; inActiveResolving.value)
                {
                    debug(hioresolve) tracef("wakeup resolving waitor");
                    cb(status, addresses.map!"a.addr".array);
                }
                theResolver._activeResolves4d.remove(hostname);
            }
        }

        // if locking enabled we can put current fiber on hold in case
        // resolving for `hostname` already started. It will be called when
        // firts resoluthion completes
        if ( theResolver._lockingEnabled )
        {
            auto inActiveResolving = theResolver._activeResolves4d.fetch(hostname);
            if ( !inActiveResolving.ok )
            {
                // first enter
                theResolver._activeResolves4d.put(hostname, new ResolverCallbackDelegate[](0));
            }
            else
            {
                // some follower, add to list of waitors
                debug(hioresolve) tracef("have to lock on resolving");
                auto waitors = inActiveResolving.value;
                waitors ~= &cbb;
                theResolver._activeResolves4d.put(hostname, waitors);
                yielded = true;
                Fiber.yield();
                return ResolverResult(status, addresses);
            }
        }
        // call ares
        theResolver._cb4d[id] = Callback4InfoD(hostname, &cbb);
        ares_query(theResolver._ares_channel, toStringz(hostname), ns_c_in, ns_t_a, theResolver.ares_callback4, cast(void*)id);
        if ( done )
        {
            // resolved from files
            debug(hioresolve) tracef("return ready result");
            handleLockedFibers();
            return ResolverResult(status, addresses);
        }
        auto rc = ares_getsock(theResolver._ares_channel, &theResolver._sockets[0], ARES_GETSOCK_MAXNUM);
        debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, theResolver._sockets);
        // prepare listening for socket events
        theResolver.handleGetSocks(rc, &theResolver._sockets);
        yielded = true;
        Fiber.yield();
        handleLockedFibers();
        return ResolverResult(status, addresses);
    }
}

package ResolverResult6 gethostbyname6(string hostname, ushort port=InternetAddress.PORT_ANY)
in(theResolver !is null)
{
    int                 status, id;
    Internet6Address[]  addresses;
    bool                done;
    auto                now = Clock.currStdTime;
    DNS6CacheEntry      dnsInfo;

    // try to convert string to addr
    ubyte[16] addr;
    int p = inet_pton(AF_INET6, toStringz(hostname), addr.ptr);
    if (p > 0)
    {
        debug(hioresolve) tracef("address converetd from %s", hostname, p);
        return ResolverResult6(ARES_SUCCESS, [new Internet6Address(addr, port)]);
    }

    auto f = theResolver._cache6.fetch(hostname);
    if ( f.ok && (now - f.value._timestamp < f.value._ttl) )
    {
        debug(hioresolve) tracef("return cached resolve status '%s' for \"%s\"", ares_statusString(f.value._status), hostname);
        foreach(ia; f.value._addresses)
        {
            addresses ~= new Internet6Address(ia, port);
        }
        return ResolverResult6(f.value._status, addresses);
    }

    dnsInfo = theResolver.resolve6FromFile(hostname);
    if (dnsInfo._status == ARES_SUCCESS)
    {
        debug(hioresolve) tracef("return resolved from file for \"%s\" with status %s", hostname, ares_statusString(dnsInfo._status));
        foreach(ia; dnsInfo._addresses)
        {
            addresses ~= new Internet6Address(ia, port);
        }
        theResolver._cache6.put(hostname, dnsInfo);
        return ResolverResult6(ARES_SUCCESS, addresses);
    }

    debug(hioresolve) tracef("start resolving %s", hostname);
    //
    id = ++theResolver._id;
    auto fiber = Fiber.getThis();
    if (fiber is null)
    {
        void cba(int s, ubyte[16][] a)
        {
            status = s;
            foreach(ia; a)
            {
                addresses ~= new Internet6Address(ia, port);
            }
            done = true;
            theResolver._cb6d.remove(id);
            debug(hioresolve) tracef("resolve for %s: %s, %s", hostname, ares_statusString(s), a);
        }
        theResolver._cb6d[id] = Callback6InfoD(hostname, &cba);
        ares_query(theResolver._ares_channel, toStringz(hostname), ns_c_in, ns_t_aaaa, theResolver.ares_callback6, cast(void*)id);
        if ( done )
        {
            // resolved from files
            debug(hioresolve) tracef("return ready result");
            return ResolverResult6(status, addresses);
        }
        // called without loop/callback, we can and have to block
        int nfds, count;
        fd_set readers, writers;
        timeval tv;
        timeval *tvp;

        while (!done) {
            FD_ZERO(&readers);
            FD_ZERO(&writers);
            nfds = ares_fds(theResolver._ares_channel, &readers, &writers);
            if (nfds == 0)
                break;
            tvp = ares_timeout(theResolver._ares_channel, null, &tv);
            count = select(nfds, &readers, &writers, null, tvp);
            ares_process(theResolver._ares_channel, &readers, &writers);
        }
        debug(hioresolve) tracef("return received result");
        return ResolverResult6(status, addresses);
    }
    else
    {
        assert(theResolver._loop !is null, "Improper call, probably you have to use hio_gethostbyname6 variant");
        bool yielded;
        void cbb(int s, ubyte[16][] a)
        {
            status = s;
            foreach (ia; a) {
                addresses ~= new Internet6Address(ia, port);
            }
            done = true;
            theResolver._cb6d.remove(id);
            debug(hioresolve) tracef("resolve for %s: %s, %s, yielded: %s", hostname, ares_strerror(s), a, yielded);
            if (yielded) fiber.call();
        }
        // handleLockedFibers call callbacks for concurrent resolves
        // when first resolution completes
        void handleLockedFibers()
        {
            if ( theResolver._lockingEnabled )
            {
                auto inActiveResolving = theResolver._activeResolves6d.fetch(hostname);
                assert(inActiveResolving.ok);
                foreach (cb; inActiveResolving.value)
                {
                    debug(hioresolve) tracef("wakeup resolving waitor");
                    cb(status, addresses.map!"a.addr".array);
                }
                theResolver._activeResolves6d.remove(hostname);
            }
        }
        // if locking enabled we can put current fiber on hold in case
        // resolving for `hostname` already started. It will be called when
        // firts resoluthion completes
        if ( theResolver._lockingEnabled )
        {
            auto inActiveResolving = theResolver._activeResolves6d.fetch(hostname);
            if ( !inActiveResolving.ok )
            {
                // first enter
                theResolver._activeResolves6d.put(hostname, new ResolverCallbackDelegate6[](0));
            }
            else
            {
                // some follower, add to list of waitors
                debug(hioresolve) tracef("have to lock on resolving");
                auto waitors = inActiveResolving.value;
                waitors ~= &cbb;
                theResolver._activeResolves6d.put(hostname, waitors);
                yielded = true;
                Fiber.yield();
                return ResolverResult6(status, addresses);
            }
        }
        theResolver._cb6d[id] = Callback6InfoD(hostname, &cbb);
        ares_query(theResolver._ares_channel, toStringz(hostname), ns_c_in, ns_t_aaaa, theResolver.ares_callback6, cast(void*)id);
        if ( done )
        {
            // resolved from files
            debug(hioresolve) tracef("return ready result");
            handleLockedFibers();
            return ResolverResult6(status, addresses);
        }
        auto rc = ares_getsock(theResolver._ares_channel, &theResolver._sockets[0], ARES_GETSOCK_MAXNUM);
        debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, theResolver._sockets);
        // prepare listening for socket events
        theResolver.handleGetSocks(rc, &theResolver._sockets);
        yielded = true;
        Fiber.yield();
        handleLockedFibers();
        return ResolverResult6(status, addresses);
    }
}

///
/// increment request id,
/// register callbacks in resolver,
/// start listening on sockets.
///
package auto gethostbyname(F)(string hostname, F cb) @safe if (isCallable!F)
in(theResolver !is null)
in(theResolver._loop !is null)
{
    debug(hioresolve) tracef("resolving %s", hostname);
    int addr;
    int p = () @trusted {return inet_pton(AF_INET, toStringz(hostname), &addr);}();
    if (p > 0)
    {
        debug(hioresolve) tracef("address converetd from %s", hostname, p);
        cb(ARES_SUCCESS, [ntohl(addr)]);
        return;
    }
    DNSCacheEntry dnsInfo;
    immutable now = Clock.currStdTime;
    auto f = theResolver._cache.fetch(hostname);
    if ( f.ok && ( now - f.value._timestamp < f.value._ttl))
    {
        cb(f.value._status, f.value._addresses);
        return;
    }
    // try to resolve from files
    dnsInfo = theResolver.resolve4FromFile(hostname);
    if ( dnsInfo._status == ARES_SUCCESS)
    {
        theResolver._cache.put(hostname, dnsInfo);
        debug(hioresolve) tracef("return dns from file for \"%s\"", hostname);
        cb(dnsInfo._status, dnsInfo._addresses);
        return;
    }

    auto id = ++theResolver._id;
    static if (isDelegate!F)
    {
        theResolver._cb4d[id] = Callback4InfoD(hostname, cb);
    }
    else
    {
        theResolver._cb4f[id] = Callback4InfoF(hostname, cb);
    }
    // request for A records
    () @trusted {
        ares_query(theResolver._ares_channel, toStringz(hostname), ns_c_in, ns_t_a, theResolver.ares_callback4, cast(void*)id);
    }();
    auto rc = ares_getsock(theResolver._ares_channel, &theResolver._sockets[0], ARES_GETSOCK_MAXNUM);
    debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, theResolver._sockets);
    // prepare listening for socket events
    theResolver.handleGetSocks(rc, &theResolver._sockets);
}
package auto gethostbyname6(F)(string hostname, F cb) @safe if (isCallable!F)
in(theResolver !is null)
in(theResolver._loop !is null)
{
    DNS6CacheEntry dnsInfo;
    auto now = Clock.currStdTime;
    auto f = theResolver._cache6.fetch(hostname);
    if ( f.ok && ( now - f.value._timestamp < f.value._ttl) )
    {
        cb(f.value._status, f.value._addresses);
        return;
    }
    // try to resolve from files
    dnsInfo = theResolver.resolve6FromFile(hostname);
    if ( dnsInfo._status == ARES_SUCCESS )
    {
        theResolver._cache6.put(hostname, dnsInfo);
        debug(hioresolve) tracef("return dns from file for \"%s\"", hostname);
        cb(dnsInfo._status, dnsInfo._addresses);
        return;
    }

    auto id = ++theResolver._id;
    static if (isDelegate!F)
    {
        theResolver._cb6d[id] = Callback6InfoD(hostname, cb);
    }
    else
    {
        theResolver._cb6f[id] = Callback6InfoF(hostname, cb);
    }
    // request for A records
    ()@trusted {
        ares_query(theResolver._ares_channel, toStringz(hostname), ns_c_in, ns_t_aaaa, theResolver.ares_callback6, cast(void*)id);
    }();
    auto rc = ares_getsock(theResolver._ares_channel, &theResolver._sockets[0], ARES_GETSOCK_MAXNUM);
    debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, theResolver._sockets);
    // prepare listening for socket events
    theResolver.handleGetSocks(rc, &theResolver._sockets);
}


///
auto ares_statusString(int status) @trusted
{
    return fromStringz(ares_strerror(status)).idup;
}

enum MaxFilesTTL = 60;          // 60 secs
enum MaxDNSTTL = 24*3600;       // 86400 secs
enum MaxNegTTL = 30;            // negative resolving TTL
enum ResolverCacheSize = 512;   // cache that number of entries

private struct DNSCacheEntry
{
    int                 _status = ARES_ENODATA;
    long                _timestamp;
    long                _ttl;       // in hnsecs
    uint[]              _addresses;
    string toString()
    {
        return "status: '%s', ttl: %ssec addr: [%(%s,%)]".format(ares_statusString(_status), _ttl/10_000_000,
                    _addresses.map!(i => fromStringz(inet_ntoa(cast(in_addr)htonl(i)))));
    }
}
private struct DNS6CacheEntry
{
    int                 _status = ARES_ENODATA;
    long                _timestamp;
    long                _ttl;       // in hnsecs
    ubyte[16][]         _addresses;
}

struct Callback4InfoF
{
    string                      hostname;
    ResolverCallbackFunction    callback;
}
struct Callback4InfoD
{
    string                      hostname;
    ResolverCallbackDelegate    callback;
}
struct Callback6InfoF
{
    string                      hostname;
    ResolverCallbackFunction6   callback;
}
struct Callback6InfoD
{
    string                      hostname;
    ResolverCallbackDelegate6   callback;
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

        HashMap!(int, Callback4InfoF)       _cb4f;
        HashMap!(int, Callback4InfoD)       _cb4d;
        HashMap!(int, Callback6InfoF)       _cb6f;
        HashMap!(int, Callback6InfoD)       _cb6d;
        int                                 _maxFilesTTL = MaxFilesTTL;  // reread /etc/files once per
        int                                 _maxDNSTTL = MaxDNSTTL;      // limit TTL returned from DNS
        int                                 _resolverCacheSize = ResolverCacheSize;
        HashMap!(string, DNSCacheEntry)     _cache;
        HashMap!(string, DNS6CacheEntry)    _cache6;
        Timer                               _cacheCleaner;
        HandlerDelegate                     _cacheTimerHandler;
        bool                                _lockingEnabled = true;

        HashMap!(string, ResolverCallbackDelegate[])
                                            _activeResolves4d;
        HashMap!(string, ResolverCallbackDelegate6[])
                                            _activeResolves6d;
    }

    override string describe()
    {
        return "resolver";
    }
    enum CleanupFrequency = 15.seconds;
    this() @safe
    {
        immutable init_res = ares_init(&_ares_channel);
        assert(init_res == ARES_SUCCESS, "Can't initialise ares.");
        _cacheTimerHandler = (AppEvent e)
        {
            debug(hioresolve) tracef("got %s", e);
            if (e & AppEvent.SHUTDOWN)
            {
                return;
            }
            debug(hioresolve) trace("run dns cache cleanup");
            auto now = Clock.currStdTime;
            foreach(name, dnsCacheEntry; _cache.byPair())
            {
                if (now - dnsCacheEntry._timestamp > dnsCacheEntry._ttl)
                {
                    debug(hioresolve) tracef("remove from cache expired entry %s", name);
                    _cache.remove(name);
                }
            }
            foreach(name, dnsCacheEntry; _cache6.byPair())
            {
                if (now - dnsCacheEntry._timestamp > dnsCacheEntry._ttl)
                {
                    debug(hioresolve) tracef("remove from cache6 expired entry %s", name);
                    _cache6.remove(name);
                }
            }

            // handle timeouts
            if (_ares_channel !is null)
            {
                ares_process_fd(_ares_channel, ARES_SOCKET_BAD, ARES_SOCKET_BAD);
            }

            _cacheCleaner.rearm(CleanupFrequency);
            getDefaultLoop().startTimer(_cacheCleaner);
        };
        _cacheCleaner = new Timer(CleanupFrequency, _cacheTimerHandler);
        getDefaultLoop().startTimer(_cacheCleaner);
    }
    ~this()
    {
        close();
    }
    void close()
    {
        if (_ares_channel)
        {
            ares_process_fd(_ares_channel, ARES_SOCKET_BAD, ARES_SOCKET_BAD);
            ares_destroy(_ares_channel);
            _ares_channel = null;
        }
        _cache.clear;
        _cache6.clear;
        _cb4f.clear;
        _cb4d.clear;
        _cb6f.clear;
        _cb6d.clear;
        assert(_activeResolves4d.length == 0);
        assert(_activeResolves6d.length == 0);
    }


    private void handleGetSocks(int rc, ares_socket_t[ARES_GETSOCK_MAXNUM] *s) @safe
    {
        for(int i; i < ARES_GETSOCK_MAXNUM;i++)
        {
            if (ARES_SOCK_READABLE(rc, i) && !_in_read[i])
            {
                debug(hioresolve) tracef("add ares socket %s to IN events", (*s)[i]);
                _loop.startPoll((*s)[i], AppEvent.IN, this);
                _in_read[i] = true;
            }
            else if (!ARES_SOCK_READABLE(rc, i) && _in_read[i])
            {
                debug(hioresolve) tracef("detach ares socket %s from IN events", (*s)[i]);
                _loop.stopPoll((*s)[i], AppEvent.IN);
                _in_read[i] = false;
            }
            if (ARES_SOCK_WRITABLE(rc, i) && !_in_write[i])
            {
                debug(hioresolve) tracef("add ares socket %s to OUT events", (*s)[i]);
                _loop.startPoll((*s)[i], AppEvent.OUT, this);
                _in_write[i] = true;
            }
            else if (!ARES_SOCK_WRITABLE(rc, i) && _in_write[i])
            {
                debug(hioresolve) tracef("detach ares socket %s from OUT events", (*s)[i]);
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
        if ( ev & AppEvent.SHUTDOWN)
        {
            throw new LoopShutdownException("shutdown loop received");
        }
        debug(hioresolve) tracef("handler: %d, %s", f, ev);
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
            _loop.detach(f);
            _in_write[socket_index] = false;
            ws = f;
        }
        if (ev & AppEvent.IN)
        {
            _loop.stopPoll(f, AppEvent.IN);
            _loop.detach(f);
            _in_read[socket_index] = false;
            rs = f;
        }
        ares_process_fd(_ares_channel, rs, ws);
        auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
        debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, _sockets);
        // prepare listening for socket events
        handleGetSocks(rc, &_sockets);
    }


    private ares_callback ares_callback4 = (void *arg, int status, int timeouts, ubyte *abuf, int alen)
    {
        Resolver resolver = theResolver;
        int id = cast(int)arg;

        DNSCacheEntry cache_entry;
        cache_entry._status = status;
        cache_entry._timestamp = Clock.currStdTime;
        debug(hioresolve) tracef("got ares_callback from ares s:\"%s\" t:%d, id: %d", fromStringz(ares_strerror(status)), timeouts, id);
        if ( status == ARES_SUCCESS)
        {
            int naddrttls = 32;
            ares_addrttl[32] addrttls;
            hostent*         he;
            int parse_status = ares_parse_a_reply(abuf, alen, &he, addrttls.ptr, &naddrttls);
            cache_entry._status = parse_status;
            if (parse_status == ARES_SUCCESS)
            {
                long min_ttl = long.max;
                uint[] result;
                foreach(ref a; addrttls[0..naddrttls])
                {
                    //debug(hioresolve) tracef("record %s ttl: %d", a.ipaddr.s_addr, a.ttl);
                    min_ttl = min(a.ttl, min_ttl);
                    auto addr = a.ipaddr.s_addr;
                    result ~= ntohl(addr);
                }
                cache_entry._ttl = max(min_ttl, 1) * sec2hnsec;
                cache_entry._addresses = result;
            }
            if ( he )
            {
                ares_free_hostent(he);
            }
        }
        if ( cache_entry._status != ARES_SUCCESS)
        {
            debug(hioresolve) tracef("set ttl for neg resolve");
            cache_entry._ttl = MaxNegTTL * sec2hnsec;
        }
        auto f = resolver._cb4f.fetch(id);
        if ( f.ok )
        {
            resolver._cb4f.remove(id);
            debug(hioresolve) tracef("put resolve into cache for \"%s\" %s", f.value.hostname, cache_entry);
            resolver._cache.put(f.value.hostname, cache_entry);
            f.value.callback(status, cache_entry._addresses);
            return;
        }
        auto d = resolver._cb4d.fetch(id);
        if ( d.ok )
        {
            resolver._cb4d.remove(id);
            debug(hioresolve) tracef("put into DNS cache \"%s\" -> %s", d.value.hostname, cache_entry);
            resolver._cache.put(d.value.hostname, cache_entry);
            d.value.callback(status, cache_entry._addresses);
            return;
        }
        errorf("impossible on s:\"%s\" t:%d, id: %d", fromStringz(ares_strerror(status)), timeouts, id);
        assert(0);
    };
    private ares_callback ares_callback6 = (void *arg, int status, int timeouts, ubyte *abuf, int alen)
    {
        Resolver resolver = theResolver;
        int id = cast(int)arg;

        DNS6CacheEntry cache_entry;
        cache_entry._status = status;
        cache_entry._timestamp = Clock.currStdTime;
        debug(hioresolve) tracef("got ares_callback from ares s:\"%s\" t:%d, id: %d", fromStringz(ares_strerror(status)), timeouts, id);
        if ( status == ARES_SUCCESS)
        {
            int naddr6ttls =  32;
            ares_addr6ttl[32] addr6ttls;
            hostent*          he;
            int parse_status = ares_parse_aaaa_reply(abuf, alen, &he, addr6ttls.ptr, &naddr6ttls);
            cache_entry._status = parse_status;
            if (parse_status == ARES_SUCCESS)
            {
                long min_ttl = long.max;
                ubyte[16][] result;
                foreach(ref a; addr6ttls[0..naddr6ttls])
                {
                    min_ttl = min(a.ttl, min_ttl);
                    auto addr = a.ip6addr;
                    result ~= addr;
                }
                cache_entry._ttl = max(min_ttl,1) * sec2hnsec;
                cache_entry._addresses = result;
            }
            if ( he )
            {
                ares_free_hostent(he);
            }
        }
        if ( cache_entry._status != ARES_SUCCESS)
        {
            debug(hioresolve) tracef("set ttl for neg resolve");
            cache_entry._ttl = MaxNegTTL * sec2hnsec;
        }
        auto f = resolver._cb6f.fetch(id);
        if ( f.ok )
        {
            resolver._cb6f.remove(id);
            debug(hioresolve) tracef("put resolve into cache for \"%s\"", f.value.hostname);
            resolver._cache6.put(f.value.hostname, cache_entry);
            f.value.callback(status, cache_entry._addresses);
            return;
        }
        auto d = resolver._cb6d.fetch(id);
        if ( d.ok )
        {
            resolver._cb6d.remove(id);
            debug(hioresolve) tracef("put resolve into cache for \"%s\": %s", d.value.hostname, cache_entry);
            resolver._cache6.put(d.value.hostname, cache_entry);
            d.value.callback(status, cache_entry._addresses);
            return;
        }
        assert(0);
    };

    DNSCacheEntry resolve4FromFile(string hostname) @safe
    {
        // try to resolve from files
        DNSCacheEntry dnsInfo;
        uint[] result;
        hostent* he;
        auto status = () @trusted {
            return ares_gethostbyname_file(_ares_channel, toStringz(hostname), AF_INET, &he);
        }();
        if ( status == ARES_SUCCESS )
        {
            debug(hioresolve) tracef("he=%s", fromStringz(he.h_name));
            debug(hioresolve) tracef("h_length=%X", he.h_length);
            auto a = he.h_addr_list;
            () @trusted {
                while( *a )
                {
                    uint addr;
                    for (int i; i < he.h_length; i++)
                    {
                        addr = addr << 8;
                        addr += (*a)[i];
                    }
                    result ~= addr;
                    a++;
                }
            }();
            dnsInfo._status = ARES_SUCCESS;
            dnsInfo._timestamp = Clock.currStdTime;
            dnsInfo._ttl = MaxFilesTTL * sec2hnsec; // -> hnsecs
            dnsInfo._addresses = result;
        }
        if ( he )
        {
            ares_free_hostent(he);
        }
        return dnsInfo;
    }

    DNS6CacheEntry resolve6FromFile(string hostname) @safe
    {
        // try to resolve from files
        DNS6CacheEntry dnsInfo;
        ubyte[16][] result;
        hostent* he;
        auto status = () @trusted {
            return ares_gethostbyname_file(_ares_channel, toStringz(hostname), AF_INET6, &he);
        }();
        if ( status == ARES_SUCCESS )
        {
            debug(hioresolve) tracef("he=%s", fromStringz(he.h_name));
            debug(hioresolve) tracef("h_length=%X", he.h_length);
            auto a = he.h_addr_list;
            () @trusted
            {
                while( *a )
                {
                    result ~= *(cast(ubyte[16]*)*a);
                    a++;
                }
            }();
            dnsInfo._status = ARES_SUCCESS;
            dnsInfo._timestamp = Clock.currStdTime;
            dnsInfo._ttl = MaxFilesTTL * sec2hnsec; // -> hnsecs
            dnsInfo._addresses = result;
        }
        if ( he )
        {
            ares_free_hostent(he);
        }
        return dnsInfo;
    }
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/sync  INET4 ===");
    auto r = hio_gethostbyname("localhost");
    assert(r.status == 0);
    debug(hioresolve) tracef("%s", r);
    r = hio_gethostbyname("8.8.8.8");
    assert(r.status == 0);
    debug(hioresolve) tracef("%s", r);
    r = hio_gethostbyname("dlang.org");
    assert(r.status == 0);
    debug(hioresolve) tracef("%s", r);
    r = hio_gethostbyname(".......");
    assert(r.status != 0);
    tracef("status: %s", ares_statusString(r.status));
    r = hio_gethostbyname(".......");
    assert(r.status != 0);
    r = hio_gethostbyname("iuytkjhcxbvkjhgfaksdjf");
    assert(r.status != 0);
    debug(hioresolve) tracef("%s", r);
    debug(hioresolve) tracef("status: %s", ares_statusString(r.status));
    r = hio_gethostbyname("iuytkjhcxbvkjhgfaksdjf");
    assert(r.status != 0);
    debug(hioresolve) tracef("%s", r);
    debug(hioresolve) tracef("status: %s", ares_statusString(r.status));
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/sync  INET6 ===");
    // auto r = resolver.gethostbyname6("ip6-localhost");
    // assert(r.status == 0);
    // debug(hioresolve) tracef("%s", r);
    // r = resolver.gethostbyname6("8.8.8.8");
    // assert(r.status == 0);
    // debug(hioresolve) tracef("%s", r);
    auto r = hio_gethostbyname6("dlang.org");
    assert(r.status == 0);
    debug(hioresolve) tracef("%s", r);
    r = hio_gethostbyname6(".......");
    assert(r.status != 0);
    tracef("status: %s", ares_statusString(r.status));
    r = hio_gethostbyname6(".......");
    assert(r.status != 0);
}

unittest
{
    import std.array: array;
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/async INET4 ===");
    theResolver = new Resolver();
    theResolver._loop = getDefaultLoop();
    auto app(string hostname)
    {
        int status;
        InternetAddress[] adresses;
        Fiber fiber = Fiber.getThis();
        bool done;
        bool yielded;

        void cb(int s, uint[] a) @trusted
        {
            status = s;
            foreach (ia; a) {
                adresses ~= new InternetAddress(ia, InternetAddress.PORT_ANY);
            }
            done = true;
            debug(hioresolve) tracef("resolve for %s: %s, %s", hostname, fromStringz(ares_strerror(s)), a);
            if (yielded)
            {
                fiber.call();
            }
        }
        gethostbyname(hostname, &cb);
        if (!done)
        {
            yielded = true;
            Fiber.yield();
        }
        return adresses;
    }
    auto names = [
        "localhost",
        "localhost", // should get cached
        "dlang.org",
        "google.com",
        "..",
        "dlang.org",  // should get cached
        "..",         // should get cached negative
    ];
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
    theResolver.close();
    theResolver = null;
}
unittest
{
    import std.array: array;
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/async INET6 ===");
    theResolver = new Resolver();
    theResolver._loop = getDefaultLoop();
    auto app(string hostname)
    {
        int status;
        Internet6Address[] addresses;
        Fiber fiber = Fiber.getThis();
        bool done;
        bool yielded;

        void cb(int s, ubyte[16][] a) @trusted
        {
            status = s;
            foreach (ia; a)
            {
                addresses ~= new Internet6Address(ia, Internet6Address.PORT_ANY);
            }
            done = true;
            debug(hioresolve) tracef("resolve for %s: %s, %s", hostname, fromStringz(ares_strerror(s)), a);
            if (yielded)
            {
                fiber.call();
            }
        }
        gethostbyname6(hostname, &cb);
        if (!done)
        {
            yielded = true;
            Fiber.yield();
        }
        return addresses;
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
    theResolver.close();
    theResolver = null;
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/App   INET4 ===");
    if ( theResolver )
    {
        theResolver.close();
    }
    theResolver = new Resolver();
    theResolver._loop = getDefaultLoop();
    App({
        import std.array: array;
        auto resolve(string name)
        {
            auto r = hio_gethostbyname(name);
            debug(hioresolve) tracef("app resolved %s=%s", name, r);
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
    theResolver.close();
    theResolver = null;
}
unittest
{
    if ( theResolver )
    {
        theResolver.close();
    }
    theResolver = new Resolver();
    theResolver._loop = getDefaultLoop();

    globalLogLevel = LogLevel.info;
    info("=== Testing resolver ares/App   INET6 ===");
    App({
        import std.array: array;
        auto resolve(string name)
        {
            auto r = hio_gethostbyname6(name);
            debug(hioresolve) tracef("app resolved %s=%s", name, r);
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
    theResolver.close();
    theResolver = null;
}
unittest
{
    info("=== Testing resolver locking ===");
    if ( theResolver )
    {
        theResolver.close();
    }
    theResolver = new Resolver();
    theResolver._loop = getDefaultLoop();

    globalLogLevel = LogLevel.info;
    App({
        import std.stdio;
        auto hostnames = [
            "ns.od.ua",
            "ns.od.ua",
            "ns.od.ua",
            "cloudflare.com",
            "cloudflare.com",
        ];
        void resolve(string host)
        {
            auto r4 = hio_gethostbyname(host);
            tracef("r4: %s", r4);
            auto r6 = hio_gethostbyname6(host);
            tracef("r6: %s", r6);
        }
        auto tasks = hostnames.map!(h => task(&resolve, h)).array;
        tasks.each!(t => t.start);
        tasks.each!(t => t.wait);
    });
    theResolver.close();
    theResolver = null;
}