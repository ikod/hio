module hio.resolver.ares;

import std.socket;
import std.datetime;
import std.format;
import std.array;
import std.algorithm;
import std.typecons;
import std.string;

import std.experimental.logger;

import core.thread;

import core.sys.posix.sys.select;
import core.sys.posix.netdb;

import hio.events;
import hio.loop;
import hio.common;
import hio.scheduler;

import ikod.containers.hashmap;

public:
    enum ARES_EMPTY = -1;
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


package:

    enum MaxFilesTTL = 60;          // 60 secs
    enum MaxDNSTTL = 24*3600;       // 86400 secs
    enum MaxNegTTL = 30;            // negative resolving TTL
    enum ResolverCacheSize = 512;   // cache that number of entries

    struct ares_channeldata;
    alias ares_channel = ares_channeldata*;
    alias ares_socket_t = int;

    enum ARES_OPT_FLAGS = (1 << 0);
    enum ARES_FLAG_STAYOPEN = (1 << 4);
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
    struct ares_options {
        int flags;
    };
    static ares_options opts = {flags:ARES_FLAG_STAYOPEN};
    private extern(C)
    {
        alias    ares_host_callback = void function(void *arg, int status, int timeouts, hostent *he);
        alias    ares_callback =      void function(void *arg, int status, int timeouts, ubyte *abuf, int alen);
        int      ares_init(ares_channel*) @trusted;
        int      ares_init_options(ares_channel* channel,
                      ares_options *options,
                      int optmask) @trusted;

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

    private struct DNS4CacheEntry
    {
        int                 _status = ARES_ENODATA;
        long                _timestamp;
        long                _ttl;       // in hnsecs
        uint[]              _addresses; // in host order
        // string toString()
        // {
        //     return "status: '%s', ttl: %ssec addr: [%(%s,%)]".format(ares_statusString(_status), _ttl/10_000_000,
        //                 _addresses.map!(i => fromStringz(inet_ntoa(cast(in_addr)htonl(i)))));
        // }
    }

    private struct DNS6CacheEntry
    {
        int                 _status = ARES_ENODATA;
        long                _timestamp;
        long                _ttl;       // in hnsecs
        ubyte[16][]         _addresses;
    }

    private class ResolverCache
    {
        private:
            HashMap!(string, DNS4CacheEntry)   cache4;
            HashMap!(string, DNS6CacheEntry)   cache6;
        package:
            synchronized auto get4(string host) @trusted
            {
                auto f = (cast(HashMap!(string, DNS4CacheEntry))cache4).fetch(host);
                if ( !f.ok )
                {
                    return f;
                }
                // check if it is expired
                immutable now = Clock.currStdTime;
                auto v = f.value;
                if ( v._timestamp + v._ttl >= now )
                {
                    // it's fresh
                    return f;
                }
                // clear expired entry, return empty response
                (cast(HashMap!(string, DNS4CacheEntry))cache4).remove(host);
                f.ok = false;
                f.value = DNS4CacheEntry();
                return f;
            }
            synchronized void put4(string host, DNS4CacheEntry e) @trusted
            {
                (cast(HashMap!(string, DNS4CacheEntry))cache4)[host] = e;
            }
            synchronized auto get6(string host) @trusted
            {
                auto f = (cast(HashMap!(string, DNS6CacheEntry))cache6).fetch(host);
                if ( !f.ok )
                {
                    return f;
                }
                // check if it is expired
                immutable now = Clock.currStdTime;
                auto v = f.value;
                if ( v._timestamp + v._ttl >= now )
                {
                    // it's fresh
                    return f;
                }
                // clear expired entry, return empty response
                (cast(HashMap!(string, DNS6CacheEntry))cache4).remove(host);
                f.ok = false;
                f.value = DNS6CacheEntry();
                return f;
            }
            synchronized void put6(string host, DNS6CacheEntry e) @trusted
            {
                (cast(HashMap!(string, DNS6CacheEntry))cache6)[host] = e;
            }
            synchronized void clear() @trusted
            {
                (cast(HashMap!(string, DNS4CacheEntry))cache4).clear;
                (cast(HashMap!(string, DNS4CacheEntry))cache6).clear;
            }
            // XXX add cache cleanup
    }

    private shared ResolverCache resolverCache;
    private static Resolver theResolver;

    void _check_init_resolverCache() @safe
    {
        if ( resolverCache is null )
        {
            resolverCache = new shared ResolverCache();
        }
    }
    shared static ~this()
    {
        if ( resolverCache )
        {
            resolverCache.clear();
        }
    }
    void _check_init_theResolver() @safe
    {
        if ( theResolver is null )
        {
            theResolver = new Resolver();
        }
    }
    private static bool exiting;
    static ~this()
    {
        exiting = true;
        if ( theResolver )
        {
            if (theResolver._ares_channel )
            {
                ares_destroy(theResolver._ares_channel);
            }
            theResolver._dns4QueryInprogress.clear();
            theResolver._dns6QueryInprogress.clear();
        }
    }
    //
    // This is called inside from c-ares when we received server response.
    // 1. check that we have this quiery id in queryInProgress dictionary
    // 2. convert server response to dns cache entry and store it in cache
    // 3. convert cache entrty to resolve result and pass it to callback
    //
    private extern(C) void ares_callback4(void *arg, int status, int timeouts, ubyte *abuf, int alen)
    {
        if ( exiting )
        {
            return;
        }
        int              id = cast(int)arg;
        int              naddrttls = 32;
        ares_addrttl[32] addrttls;
        hostent*         he;
        long             min_ttl = long.max;

        DNS4CacheEntry   cache_entry;
        cache_entry._status = status;
        cache_entry._ttl = MaxNegTTL * sec2hnsec;

        assert(theResolver);

        auto f = theResolver._dns4QueryInprogress.fetch(id);
        if ( !f.ok )
        {
            debug(hioresolve) tracef("dns4queryinprogr[%d] not found", id);
            return;
        }


        theResolver._dns4QueryInprogress.remove(id);

        auto port = f.value._port;
        auto callback = f.value._callback;
        if ( f.value._timer ) 
        {
            debug(hioresolve) tracef("stop timer %s", f.value._timer);
            getDefaultLoop.stopTimer(f.value._timer);
        }

        debug(hioresolve) tracef("got callback from ares for INET query id %d, hostname %s",
            id, f.value._hostname);

        if ( status != ARES_SUCCESS)
        {
            callback(ResolverResult4(cache_entry, port));
            return;
        }
        immutable parse_status = ares_parse_a_reply(abuf, alen, &he, addrttls.ptr, &naddrttls);
        scope(exit)
        {
            if ( he ) ares_free_hostent(he);
        }
        cache_entry._status = parse_status;
        if (parse_status != ARES_SUCCESS)
        {
            callback(ResolverResult4(cache_entry, port));
            return;
        }
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
        callback(ResolverResult4(cache_entry, port));
    }
    private extern(C) void ares_callback6(void *arg, int status, int timeouts, ubyte *abuf, int alen)
    {
        if ( exiting )
        {
            return;
        }
        int               id = cast(int)arg;
        int               naddrttls = 32;
        hostent*          he;
        int naddr6ttls =  32;
        ares_addr6ttl[32] addr6ttls;
        long              min_ttl = long.max;
        ubyte[16][]       result;

        DNS6CacheEntry   cache_entry;
        cache_entry._status = status;
        cache_entry._ttl = MaxNegTTL * sec2hnsec;

        assert(theResolver);

        auto f = theResolver._dns6QueryInprogress.fetch(id);
        if ( !f.ok )
        {
            debug(hioresolve) tracef("dns6queryinprogr[%d] not found", id);
            return;
        }

        auto port = f.value._port;
        auto callback = f.value._callback;
        theResolver._dns6QueryInprogress.remove(id);

        if ( f.value._timer ) getDefaultLoop.stopTimer(f.value._timer);

        debug(hioresolve) tracef("got callback from ares for INET query id %d, hostname %s, status: %s",
            id, f.value._hostname, resolver_errno(status));

        if ( status != ARES_SUCCESS)
        {
            callback(ResolverResult6(cache_entry, port));
            return;
        }
        immutable parse_status = ares_parse_aaaa_reply(abuf, alen, &he, addr6ttls.ptr, &naddr6ttls);
        scope(exit)
        {
            if ( he ) ares_free_hostent(he);
        }
        cache_entry._status = parse_status;
        if (parse_status == ARES_SUCCESS)
        {
            foreach(ref a; addr6ttls[0..naddr6ttls])
            {
                min_ttl = min(a.ttl, min_ttl);
                auto addr = a.ip6addr;
                result ~= addr;
            }
            cache_entry._ttl = max(min_ttl,1) * sec2hnsec;
            cache_entry._addresses = result;
        }
        cache_entry._ttl = max(min_ttl, 1) * sec2hnsec;
        cache_entry._addresses = result;
        debug(hioresolve) tracef("result: %s", cache_entry);
        callback(ResolverResult6(cache_entry, port));
    }

    struct DNS4QueryInProgress
    {
        string                          _hostname;
        ushort                          _port;
        int                             _query_id;
        Timer                           _timer;
        void delegate(ResolverResult4)  _callback;
    }

    struct DNS6QueryInProgress
    {
        string                          _hostname;
        ushort                          _port;
        int                             _query_id;
        Timer                           _timer;
        void delegate(ResolverResult6)  _callback;
    }

    private class Resolver : FileEventHandler
    {
    private:

        //hlEvLoop                            _loop;
        ares_channel                        _ares_channel;
        int                                 _query_id;
        bool[ARES_GETSOCK_MAXNUM]           _in_read;
        bool[ARES_GETSOCK_MAXNUM]           _in_write;
        ares_socket_t[ARES_GETSOCK_MAXNUM]  _sockets;
        HashMap!(int, DNS4QueryInProgress)  _dns4QueryInprogress;
        HashMap!(int, DNS6QueryInProgress)  _dns6QueryInprogress;

    package:

        this() @safe
        {
            immutable init_opts = ares_init_options(&_ares_channel, &opts, ARES_OPT_FLAGS);
            assert(init_opts == ARES_SUCCESS);
        }
        void close()
        {
            foreach(p;_dns4QueryInprogress.byPair)
            {
                Timer t = p.value._timer;
                if ( t )
                {
                    getDefaultLoop.stopTimer(t);
                }
            }
            foreach(p;_dns6QueryInprogress.byPair)
            {
                Timer t = p.value._timer;
                if ( t )
                {
                    getDefaultLoop.stopTimer(t);
                }
            }
            if (_ares_channel)
            {
                ares_destroy(_ares_channel);
            }
        }
        DNS4CacheEntry resolve4FromFile(string hostname) @safe
        {
            // try to resolve from files
            DNS4CacheEntry dnsInfo;
            uint[] result;
            hostent* he;
            immutable status = () @trusted {
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

        private void handleGetSocks(int rc, ares_socket_t[ARES_GETSOCK_MAXNUM] *s) @safe
        {
            for(int i; i < ARES_GETSOCK_MAXNUM;i++)
            {
                if (ARES_SOCK_READABLE(rc, i) && !_in_read[i])
                {
                    debug(hioresolve) tracef("add ares socket %s to IN events", (*s)[i]);
                    getDefaultLoop().startPoll((*s)[i], AppEvent.IN, this);
                    _in_read[i] = true;
                }
                else if (!ARES_SOCK_READABLE(rc, i) && _in_read[i])
                {
                    debug(hioresolve) tracef("detach ares socket %s from IN events", (*s)[i]);
                    getDefaultLoop.stopPoll((*s)[i], AppEvent.IN);
                    _in_read[i] = false;
                }
                if (ARES_SOCK_WRITABLE(rc, i) && !_in_write[i])
                {
                    debug(hioresolve) tracef("add ares socket %s to OUT events", (*s)[i]);
                    getDefaultLoop.startPoll((*s)[i], AppEvent.OUT, this);
                    _in_write[i] = true;
                }
                else if (!ARES_SOCK_WRITABLE(rc, i) && _in_write[i])
                {
                    debug(hioresolve) tracef("detach ares socket %s from OUT events", (*s)[i]);
                    getDefaultLoop.stopPoll((*s)[i], AppEvent.OUT);
                    _in_write[i] = true;
                }
            }
        }
        private ResolverResult4 resolveSync4(string hostname, ushort port, Duration timeout)
        {
            ResolverResult4 result;
            int id = _query_id++;
            void callback(ResolverResult4 r)
            {
                result = r;
            }
            DNS4QueryInProgress qip = {
                _hostname: hostname,
                _port: port,
                _query_id: id,
                _timer: null,
                _callback: &callback
            };
            _dns4QueryInprogress[id] = qip;
            debug(hioresolve) tracef("handle sync resolve for %s", hostname);
            ares_query(_ares_channel, toStringz(hostname), ns_c_in, ns_t_a, &ares_callback4, cast(void*)id);
            if ( !result.isEmpty )
            {
                return result;
            }
            debug(hioresolve) tracef("wait on select for sync resolve for %s", hostname);
            int nfds, count;
            fd_set readers, writers;
            timeval tv;
            timeval *tvp;
            auto started = Clock.currTime;
            while ( Clock.currTime - started < timeout ) {
                FD_ZERO(&readers);
                FD_ZERO(&writers);
                nfds = ares_fds(theResolver._ares_channel, &readers, &writers);
                if (nfds == 0)
                    break;
                tvp = ares_timeout(theResolver._ares_channel, null, &tv);
                debug(hioresolve) tracef("select sleep for %s", tv);
                count = select(nfds, &readers, &writers, null, tvp);
                debug(hioresolve) tracef("select returned %d events %s, %s", count, readers, writers);
                ares_process(theResolver._ares_channel, &readers, &writers);
            }
            auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
            debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, _sockets);
            // prepare listening for socket events
            handleGetSocks(rc, &_sockets);
            return result;
        }

        private ResolverResult6 resolveSync6(string hostname, ushort port, Duration timeout)
        {
            ResolverResult6 result;
            int id = _query_id++;
            void callback(ResolverResult6 r)
            {
                result = r;
            }
            DNS6QueryInProgress qip = {
                _hostname: hostname,
                _port: port,
                _query_id: id,
                _timer: null,
                _callback: &callback
            };
            _dns6QueryInprogress[id] = qip;
            debug(hioresolve) tracef("handle sync resolve for %s", hostname);
            ares_query(_ares_channel, toStringz(hostname), ns_c_in, ns_t_aaaa, &ares_callback6, cast(void*)id);
            if ( !result.isEmpty )
            {
                return result;
            }
            debug(hioresolve) tracef("wait on select for sync resolve for %s", hostname);
            int nfds, count;
            fd_set readers, writers;
            timeval tv;
            timeval *tvp;
            auto started = Clock.currTime;
            while ( Clock.currTime - started < timeout ) {
                FD_ZERO(&readers);
                FD_ZERO(&writers);
                nfds = ares_fds(theResolver._ares_channel, &readers, &writers);
                if (nfds == 0)
                    break;
                tvp = ares_timeout(theResolver._ares_channel, null, &tv);
                debug(hioresolve) tracef("select sleep for %s", tv);
                count = select(nfds, &readers, &writers, null, tvp);
                debug(hioresolve) tracef("select returned %d events %s, %s", count, readers, writers);
                ares_process(theResolver._ares_channel, &readers, &writers);
            }
            auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
            debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, _sockets);
            // prepare listening for socket events
            handleGetSocks(rc, &_sockets);
            return result;
        }

        void send_IN_A_Query(string hostname, ushort port,
                    void delegate(ResolverResult4) @safe callback,
                    Duration timeout) @safe
        {
            int id = _query_id++;
            Timer t = new Timer(timeout,(AppEvent e) @safe
            {
                // handle timeout
                // remove this query from the InProgress and call calback
                theResolver._dns4QueryInprogress.remove(id);
                ResolverResult4 result = ResolverResult4(ARES_ETIMEOUT, new InternetAddress[](0));
                callback(result);
            });
            DNS4QueryInProgress qip = {
                _hostname: hostname,
                _port: port,
                _query_id: id,
                _timer: t,
                _callback: callback
            };
            _dns4QueryInprogress[id] = qip;
            getDefaultLoop.startTimer(t);
            () @trusted
            {
                ares_query(_ares_channel, toStringz(hostname), ns_c_in, ns_t_a, &ares_callback4, cast(void*)id);
            }();
        }
        void send_IN_AAAA_Query(string hostname, ushort port,
                    void delegate(ResolverResult6) @safe callback,
                    Duration timeout) @safe
        {
            int id = _query_id++;
            Timer t = new Timer(timeout,(AppEvent e) @safe
            {
                // handle timeout
                // remove this query from the InProgress and call calback
                theResolver._dns6QueryInprogress.remove(id);
                ResolverResult6 result = ResolverResult6(ARES_ETIMEOUT, new Internet6Address[](0));
                callback(result);
            });
            DNS6QueryInProgress qip = {
                _hostname: hostname,
                _port: port,
                _query_id: id,
                _timer: t,
                _callback: callback
            };
            _dns6QueryInprogress[id] = qip;
            getDefaultLoop.startTimer(t);
            () @trusted
            {
                ares_query(_ares_channel, toStringz(hostname), ns_c_in, ns_t_aaaa, &ares_callback6, cast(void*)id);
            }();
        }

    public:

        override void eventHandler(int f, AppEvent ev)
        {
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
            auto loop = getDefaultLoop();
            if (ev & AppEvent.OUT)
            {
                loop.stopPoll(f, AppEvent.OUT);
                loop.detach(f);
                _in_write[socket_index] = false;
                ws = f;
            }
            if (ev & AppEvent.IN)
            {
                loop.stopPoll(f, AppEvent.IN);
                loop.detach(f);
                _in_read[socket_index] = false;
                rs = f;
            }
            debug(hioresolve) tracef("handle event on %s,%s", rs, ws);
            ares_process_fd(_ares_channel, rs, ws);
            auto rc = ares_getsock(_ares_channel, &_sockets[0], ARES_GETSOCK_MAXNUM);
            debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, _sockets);
            // prepare listening for socket events
            handleGetSocks(rc, &_sockets);
        }
        override string describe()
        {
            return "newares";
        }
    }

    ResolverResult4 tryLocalResolve4(string host, short port) @safe
    {
        _check_init_resolverCache();
        _check_init_theResolver();
        ResolverResult4 result;

        int addr;
        int p = () @trusted 
        {
            return inet_pton(AF_INET, toStringz(host), &addr);
        }();

        if (p > 0)
        {
            debug(hioresolve) tracef("address converetd from %s", host, p);
            return ResolverResult4(ARES_SUCCESS, [new InternetAddress(ntohl(addr), port)]);
        }
        // string is not addr, check cache
        assert(resolverCache);
        auto cache_entry = resolverCache.get4(host);
        if ( cache_entry.ok )
        {
            debug(hioresolve) tracef("resolved %s from cache", host);
            return ResolverResult4(cache_entry.value, port);
        }
        // entry not in cache, try resolve from file
        assert(theResolver);
        auto file_entry = theResolver.resolve4FromFile(host);
        if ( file_entry._status == ARES_SUCCESS )
        {
            resolverCache.put4(host, file_entry);
            return ResolverResult4(file_entry, port);
        }
        return result;
    }
    ResolverResult6 tryLocalResolve6(string host, short port) @safe
    {
        _check_init_resolverCache();
        _check_init_theResolver();
        ResolverResult6 result;

        ubyte[16] addr;
        int p = () @trusted 
        {
            return inet_pton(AF_INET6, toStringz(host), addr.ptr);
        }();

        if (p > 0)
        {
            debug(hioresolve) tracef("address converetd from %s", host, p);
            return ResolverResult6(ARES_SUCCESS, [new Internet6Address(addr, port)]);
        }
        // string is not addr, check cache
        assert(resolverCache);
        auto cache_entry = resolverCache.get6(host);
        if ( cache_entry.ok )
        {
            debug(hioresolve) tracef("resolved %s from cache", host);
            return ResolverResult6(cache_entry.value, port);
        }
        // entry not in cache, try resolve from file
        assert(theResolver);
        auto file_entry = theResolver.resolve6FromFile(host);
        if ( file_entry._status == ARES_SUCCESS )
        {
            resolverCache.put6(host, file_entry);
            return ResolverResult6(file_entry, port);
        }
        return result;
    }

public:
    ///
    string resolver_errno(int r) @trusted
    {
        import std.conv: to;
        return to!string(ares_strerror(r));
    }

    ///
    struct ResolverResult4
    {
        private:
            int         _status = ARES_EMPTY;
            Address[]   _addresses;

        public:
        this(int s, Address[] a) @safe
        {
            _status = s;
            _addresses = a;
        }
        this(DNS4CacheEntry entry, ushort port) @safe
        {
            _status = entry._status;
            _addresses = entry._addresses
                .map!(a => new InternetAddress(a, port))
                .map!(a => cast(Address)a).array;
        }
        bool isEmpty() @safe
        {
            return _status == ARES_EMPTY;
        }
        auto status() inout @safe @nogc
        {
            return _status;
        }
        auto addresses() inout @safe @nogc
        {
            return _addresses;
        }
    }
    ///
    struct ResolverResult6
    {
        private:
            int         _status = ARES_EMPTY;
            Address[]   _addresses;

        public:
        this(int s, Address[] a) @safe
        {
            _status = s;
            _addresses = a;
        }
        this(DNS6CacheEntry entry, ushort port) @safe
        {
            _status = entry._status;
            _addresses = entry._addresses
                .map!(a => new Internet6Address(a, port))
                .map!(a => cast(Address)a).array;
        }
        bool isEmpty() @safe
        {
            return _status == ARES_EMPTY;
        }
        auto status() inout @safe @nogc
        {
            return _status;
        }
        auto addresses() inout @safe @nogc
        {
            return _addresses;
        }
    }
    ///
    ResolverResult4 hio_gethostbyname(string host, ushort port = InternetAddress.PORT_ANY, Duration timeout = 5.seconds)
    {
        bool yielded;
        ResolverResult4 cb_result, result;

        auto fiber = Fiber.getThis();
        if ( fiber is null )
        {
            result = tryLocalResolve4(host, port);
            if ( !result.isEmpty )
            {
                return result;
            }
            return theResolver.resolveSync4(host, port, timeout);
        }

        // resolve using ares and/or loop
        debug(hioresolve) tracef("resolve %s using ares", host);
        void resolveCallback(ResolverResult4 r) @safe
        {
            debug(hioresolve) tracef("received result %s", r);
            cb_result = r;
            if ( yielded )
            {
                debug(hioresolve) tracef("calling back with %s", cb_result);
                () @trusted{fiber.call();}();
            }
        }
        result = hio_gethostbyname(host, &resolveCallback, port, timeout);
        if ( !cb_result.isEmpty )
        {
            return cb_result;
        }
        if ( !result.isEmpty )
        {
            return result;
        }
        // wait for callback
        debug(hioresolve) tracef("yeilding for resolving");
        yielded = true;
        Fiber.yield();
        debug(hioresolve) tracef("returned from wait");
        return cb_result;
    }
    ///
    ResolverResult4 hio_gethostbyname(C)(string hostname, C callback, ushort port = InternetAddress.PORT_ANY, Duration timeout = 5.seconds) @safe
    {
        ResolverResult4 result = tryLocalResolve4(hostname, port);
        if ( !result.isEmpty )
        {
            return result;
        }
        // local methods failed, 
        // prepare request and send it, wait for response
        void handler(ResolverResult4 r) @safe
        {
            result = r;
            callback(r);
        }
        theResolver.send_IN_A_Query(hostname, port, &handler, timeout);
        auto rc = ares_getsock(theResolver._ares_channel, &theResolver._sockets[0], ARES_GETSOCK_MAXNUM);
        debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, theResolver._sockets);
        // prepare listening for socket events
        theResolver.handleGetSocks(rc, &theResolver._sockets);
        return result;
    }
    ///
    ResolverResult6 hio_gethostbyname6(string host, ushort port = InternetAddress.PORT_ANY, Duration timeout = 5.seconds)
    {
        bool yielded;
        ResolverResult6 result;

        auto fiber = Fiber.getThis();
        if ( fiber is null )
        {
            result = tryLocalResolve6(host, port);
            if ( !result.isEmpty )
            {
                return result;
            }
            return theResolver.resolveSync6(host, port, timeout);
        }

        // resolve using ares and/or loop
        debug(hioresolve) tracef("resolve %s using ares", host);
        void resolveCallback(ResolverResult6 r) @safe
        {
            debug(hioresolve) tracef("received result %s", r);
            result = r;
            if ( yielded )
            {
                () @trusted{fiber.call();}();
            }
        }
        result = hio_gethostbyname6(host, &resolveCallback, port, timeout);
        if ( result.isEmpty )
        {
            // wait for callback
            debug(hioresolve) tracef("yeilding for resolving");
            yielded = true;
            Fiber.yield();
            debug(hioresolve) tracef("returned from wait");
        }
        return result;
    }
    ///
    ResolverResult6 hio_gethostbyname6(C)(string hostname, C callback, ushort port = InternetAddress.PORT_ANY, Duration timeout = 5.seconds) @safe
    {
        ResolverResult6 result = tryLocalResolve6(hostname, port);
        if ( !result.isEmpty )
        {
            return result;
        }
        // local methods failed, 
        // prepare request and send it, wait for response
        void handler(ResolverResult6 r) @safe
        {
            result = r;
            debug(hioresolve) tracef("callback 6, %s", r);
            callback(r);
        }
        debug(hioresolve) tracef("send AAAA query for %s", hostname);
        theResolver.send_IN_AAAA_Query(hostname, port, &handler, timeout);
        auto rc = ares_getsock(theResolver._ares_channel, &theResolver._sockets[0], ARES_GETSOCK_MAXNUM);
        debug(hioresolve) tracef("getsocks: 0x%04X, %s", rc, theResolver._sockets);
        // prepare listening for socket events
        theResolver.handleGetSocks(rc, &theResolver._sockets);
        return result;
    }

unittest
{
    infof("=== Testing resolver shared cache");
    _check_init_resolverCache();
    assert(resolverCache ! is null);
    DNS4CacheEntry e;
    e._ttl = 100000;
    e._timestamp = Clock.currStdTime;
    resolverCache.put4("testhost", e);
    auto v = resolverCache.get4("testhost");
    assert(v.ok);
    resolverCache.clear();
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver INET4 sync/no loop ===");
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
    tracef("status: %s", resolver_errno(r.status));
    r = hio_gethostbyname(".......");
    assert(r.status != 0);
    r = hio_gethostbyname("iuytkjhcxbvkjhgfaksdjf");
    assert(r.status != 0);
    debug(hioresolve) tracef("%s", r);
    debug(hioresolve) tracef("status: %s", resolver_errno(r.status));
    r = hio_gethostbyname("iuytkjhcxbvkjhgfaksdjf");
    assert(r.status != 0);
    debug(hioresolve) tracef("%s", r);
    debug(hioresolve) tracef("status: %s", resolver_errno(r.status));

    DNS4CacheEntry e;
    e._status = ARES_SUCCESS;
    e._ttl = 1000000;
    e._timestamp = Clock.currStdTime;
    e._addresses = [0x7f_00_00_01];
    resolverCache.put4("testhost", e);

    // check resolve "127.0.0.1"
    r = hio_gethostbyname("127.0.0.1", InternetAddress.PORT_ANY, 5.seconds);
    assert(r._status == ARES_SUCCESS);
    assert(r._addresses.length >= 1);
    Address localhost = getAddress("127.0.0.1", InternetAddress.PORT_ANY)[0];
    Address resolved = r._addresses[0];
    assert(resolved.addressFamily == AF_INET);
    assert((cast(sockaddr_in*)resolved.name).sin_addr == (cast(sockaddr_in*)localhost.name).sin_addr);
    globalLogLevel = LogLevel.info;
}

unittest
{
    import std.array: array;
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver INET4 async/callback ===");
    auto app(string hostname)
    {
        int status;
        Address[] addresses;
        Fiber fiber = Fiber.getThis();
        bool done;
        bool yielded;

        void cb(ResolverResult4 r) @trusted
        {
            status = r.status;
            addresses = r.addresses;
            done = true;
            debug(hioresolve) tracef("resolve for %s: %s, %s", hostname, fromStringz(ares_strerror(status)), r);
            if (yielded)
            {
                fiber.call();
            }
        }
        auto r = hio_gethostbyname(hostname, &cb);
        if (r.isEmpty)
        {
            yielded = true;
            Fiber.yield();
        }
        return r.addresses;
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
    // theResolver.close();
    // theResolver = null;
}

unittest
{
    info("=== Testing resolver INET4 sync/task ===");
    globalLogLevel = LogLevel.info;
    DNS4CacheEntry e;
    e._status = ARES_SUCCESS;
    e._ttl = 1000000;
    e._timestamp = Clock.currStdTime;
    e._addresses = [0x7f_00_00_01];
    resolverCache.put4("testhost", e);
    App({
        // test cached resolve
        auto r = hio_gethostbyname("testhost", 12345);
        assert(r.status == ARES_SUCCESS);
        assert(r.addresses.length == 1);
        assert((cast(InternetAddress)r.addresses[0]).addr == 0x7f000001);
        assert((cast(InternetAddress)r.addresses[0]).port == 12345);
        //
        auto lh = hio_gethostbyname("localhost");

        auto resolve(string hostname)
        {
            auto r = hio_gethostbyname(hostname, 12345);
            debug(hioresolve) tracef("%s -> %s", hostname, r);
            return r;
        }
        auto names = [
            "dlang.org",
            "google.com",
            "cloudflare.com",
            "a.root-servers.net.",
            "b.root-servers.net.",
            "c.root-servers.net.",
            "d.root-servers.net.",
            "e.root-servers.net.",
            "...",
            "127.0.0.1"
        ];
        auto tasks = names.map!(n => task(&resolve, n)).array;
        tasks.each!(t => t.start);
        tasks.each!(t => t.wait);
    });
    globalLogLevel = LogLevel.info;
}

unittest
{
    infof("=== Testing resolver timeouts ===");
    globalLogLevel = LogLevel.info;
    auto v = App({
        resolverCache.clear();
        auto resolve(string hostname)
        {
            auto r = hio_gethostbyname(hostname, 12345, 3.msecs);
            debug(hioresolve) tracef("%s -> %s", hostname, r);
            return r;
        }
        auto names = [
            "dlang.org",
            "google.com",
            "cloudflare.com",
            "a.root-servers.net.",
            "b.root-servers.net.",
            "c.root-servers.net.",
            "d.root-servers.net.",
            "e.root-servers.net.",
            "...",
            "127.0.0.1"
        ];
        auto tasks = names.map!(n => task(&resolve, n)).array;
        tasks.each!(t => t.start);
        tasks.each!(t => t.wait);
        return tasks.map!"a.result".array;
    });
    globalLogLevel = LogLevel.info;
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver INET6 ares/sync ===");
    // auto r = resolver.gethostbyname6("ip6-localhost");
    // assert(r.status == 0);
    // debug(hioresolve) tracef("%s", r);
    // r = resolver.gethostbyname6("8.8.8.8");
    // assert(r.status == 0);
    // debug(hioresolve) tracef("%s", r);
    auto r = hio_gethostbyname6("dlang.org");
    assert(r.status == 0);
    tracef("%s", r);
    r = hio_gethostbyname6(".......");
    assert(r.status != 0);
    tracef("status: %s", resolver_errno(r.status));
    r = hio_gethostbyname6(".......");
    assert(r.status != 0);
    globalLogLevel = LogLevel.info;
}
unittest
{
    import std.array: array;
    globalLogLevel = LogLevel.info;
    info("=== Testing resolver INET6 ares/async ===");
    auto app(string hostname)
    {
        int status;
        bool yielded;

        Internet6Address[] addresses;
        Fiber fiber = Fiber.getThis();

        void cb(ResolverResult6 r) @trusted
        {
            status = r.status;
            addresses = r.addresses.map!(a => cast(Internet6Address)a).array;
            if (yielded)
            {
                fiber.call();
            }
        }
        auto r = hio_gethostbyname6(hostname, &cb);
        if (r.isEmpty)
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
}
