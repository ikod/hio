module hio.resolver.ares;

import core.sys.posix.sys.select;
import core.sys.posix.netdb;

import std.socket;
import std.string;
import std.experimental.logger;

import core.thread;

import hio.events;
import hio.loop;
import hio.common;

struct ares_channeldata;
alias ares_channel = ares_channeldata*;
extern (C) alias ares_host_callback = void function(void *arg, int status, int timeouts, hostent *he);

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
    int      ares_init(ares_channel*);
    int      ares_fds(ares_channel, fd_set* reads_fds, fd_set* writes_fds);
    timeval* ares_timeout(ares_channel channel, timeval *maxtv, timeval *tv);
    void     ares_process(ares_channel channel, fd_set *read_fds, fd_set *write_fds);
    char*    ares_strerror(int);
    void     ares_gethostbyname(ares_channel channel, const char *name, int family, ares_host_callback callback, void *arg);
}

alias ResolverCallback = void function();


struct Resolver
{
    private
    {
        ares_channel        _ares_channel;
        bool                _in_progress;
        int                 _status;
        InternetAddress[]   _gethostbyName4result;
    }

    private void maybe_init()
    {
        if (_ares_channel is null)
        {
            immutable init_res = ares_init(&_ares_channel);
            assert(init_res == ARES_SUCCESS, "Can't initialise ares.");
        }
    }

    ares_host_callback host_callback4 = (void *arg, int status, int timeouts, hostent* he)
    {
        debug tracef("got callback s:\"%s\" t:%d h:%s", fromStringz(ares_strerror(status)), timeouts, he);
        Resolver* resolver = cast(Resolver*)arg;
        resolver._status = status;
        if ( status == 0 )
        {
            debug tracef("he=%s", he);
            resolver._in_progress = false;
            if (he is null)
            {
                return;
            }
            assert(he.h_addrtype == AF_INET);
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
                resolver._gethostbyName4result ~= new InternetAddress(addr, InternetAddress.PORT_ANY);
                a++;
            }
        }
        else
        {
            debug tracef("callback failed: %d", status);
        }
    };

    InternetAddress[] gethostbyname(string hostname)
    {
        maybe_init();
        assert(!_in_progress, "Previous resolving in progress");
        _gethostbyName4result.length = 0;
        _in_progress = true;
        _status = -1;
        ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET, host_callback4, cast(void*)&this);
        if ( ! _in_progress )
        {
            // resolved from files
            return _gethostbyName4result;
        }
        auto fiber = Fiber.getThis();
        if (fiber is null)
        {
            // we called this not inside task and without loop/callback, we have to block
            int nfds, count;
            fd_set readers, writers;
            timeval tv;
            timeval *tvp;

            while (_in_progress) {
                FD_ZERO(&readers);
                FD_ZERO(&writers);
                nfds = ares_fds(_ares_channel, &readers, &writers);
                if (nfds == 0)
                    break;
                tvp = ares_timeout(_ares_channel, null, &tv);
                count = select(nfds, &readers, &writers, null, tvp);
                ares_process(_ares_channel, &readers, &writers);
            }
        }
        return _gethostbyName4result;
    }
    auto gethostbyname(string hostname, hlEvLoop loop, ResolverCallback cb)
    {
        maybe_init();
        assert(!_in_progress, "Previous resolving in progress");
        _gethostbyName4result.length = 0;
        _in_progress = true;
        _status = -1;
        ares_gethostbyname(_ares_channel, toStringz(hostname), AF_INET, host_callback4, cast(void*)&this);
        if ( ! _in_progress )
        {
            // resolved from files
            cb();
            return;
        }

    }
}

unittest
{
    globalLogLevel = LogLevel.trace;
    info("=== Testing ares ===");
    auto resolver = Resolver();
    auto r = resolver.gethostbyname("localhost");
    debug tracef("%s", r);
    r = resolver.gethostbyname("8.8.8.8");
    debug tracef("%s", r);
    r = resolver.gethostbyname("dlang.org");
    debug tracef("%s", r);
    r = resolver.gethostbyname(".......");
    debug tracef("%s", r);
}