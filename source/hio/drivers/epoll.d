module hio.drivers.epoll;

version(linux):

import std.datetime;
import std.string;
import std.container;
import std.exception;
import std.experimental.logger;
import std.typecons;
import std.traits;
import std.algorithm: min, max;

import std.experimental.allocator;
import std.experimental.allocator.mallocator;

import core.memory: GC;

import std.algorithm.comparison: max;
import core.stdc.string: strerror;
import core.stdc.errno: errno, EAGAIN, EINTR;

import core.sys.linux.epoll;
import core.sys.linux.timerfd;
import core.sys.linux.sys.signalfd;

import core.sys.posix.unistd: close, read;
import core.sys.posix.time : itimerspec, CLOCK_MONOTONIC , timespec;

import core.memory;

import timingwheels;

import hio.events;
import hio.common;

private enum InExpTimersSize = 16;
private alias TW = TimingWheels!Timer;
private alias TWAdvanceResult = ReturnType!(TW.advance!(TW));

struct NativeEventLoopImpl {
    immutable bool   native = true;
    immutable string _name = "epoll";
    private {
        bool                    stopped = false;
        enum                    MAXEVENTS = 1024;
        int                     epoll_fd = -1;
        int                     signal_fd = -1;
        sigset_t                mask;

        align(1)                epoll_event[MAXEVENTS] events;

        Duration                tick = 5.msecs;
        TW                      timingwheels;

        TWAdvanceResult         advancedTimersHash;
        long                    advancedTimersHashLength;

        Timer[InExpTimersSize]  advancedTimersArray;
        long                    advancedTimersArrayLength;

        Timer[]                 overdue;    // timers added with expiration in past
        Signal[][int]           signals;
        FileEventHandler[]      fileHandlers;

    }
    @disable this(this) {}

    void initialize() @trusted nothrow {
        if ( epoll_fd == -1 ) {
            epoll_fd = (() @trusted  => epoll_create(MAXEVENTS))();
        }
        fileHandlers = Mallocator.instance.makeArray!FileEventHandler(16*1024);
        GC.addRange(&fileHandlers[0], fileHandlers.length * FileEventHandler.sizeof);
        timingwheels.init();
    }
    void deinit() @trusted {
        if (epoll_fd>=0)
        {
            close(epoll_fd);
            epoll_fd = -1;
        }
        if (signal_fd>=0)
        {
            close(signal_fd);
            signal_fd = -1;
        }
        //precise_timers = null;
        if (fileHandlers !is null)
        {
            GC.removeRange(&fileHandlers[0]);
            Mallocator.instance.dispose(fileHandlers);
            fileHandlers = null;
        }
        timingwheels = TimingWheels!(Timer)();
        timingwheels.init();
        advancedTimersHash = TWAdvanceResult.init;
    }

    void stop() @safe {
        stopped = true;
    }

    int _calculate_timeout(SysTime deadline) {
        auto now_real = Clock.currTime;
        Duration delta = deadline - now_real;
        debug(hioepoll) safe_tracef("deadline - now_real: %s", delta);
        auto nextTWtimer = timingwheels.timeUntilNextEvent(tick, now_real.stdTime);
        debug(hioepoll) safe_tracef("nextTWtimer: %s", nextTWtimer);
        delta = min(delta, nextTWtimer);

        delta = max(delta, 0.seconds);
        return cast(int)delta.total!"msecs";
    }
    private void execute_overdue_timers()
    {
        while (overdue.length > 0)
        {
            // execute timers which user requested with negative delay
            Timer t = overdue[0];
            overdue = overdue[1..$];
            debug(hioepoll) safe_tracef("execute overdue %s", t);
            HandlerDelegate h = t._handler;
            try {
                h(AppEvent.TMO);
            } catch (Exception e) {
                errorf("Uncaught exception: %s", e);
            }
        }
    }
    /**
    *
    **/
    void run(Duration d) {

        immutable bool runInfinitely = (d == Duration.max);

        /**
         * eventloop will exit when we reach deadline
         * it is allowed to have d == 0.seconds,
         * which mean we wil run events once
        **/
        SysTime deadline = Clock.currTime + d;
        debug(hioepoll) tracef("evl run %s",runInfinitely? "infinitely": "for %s".format(d));
        scope ( exit )
        {
            stopped = false;
        }

        while( !stopped ) {
            debug(hioepoll) tracef("event loop iteration");

            if (stopped) {
                break;
            }

            int timeout_ms = _calculate_timeout(deadline);

            debug(hioepoll) safe_tracef("wait in poll for %s.ms", timeout_ms);

            int ready = epoll_wait(epoll_fd, &events[0], MAXEVENTS, timeout_ms);

            debug(hioepoll) tracef("got %d events", ready);

            SysTime now_real = Clock.currTime;

            if ( ready == -1 && errno == EINTR) {
                continue;
            }
            if ( ready < 0 ) {
                errorf("epoll_wait returned error %s", fromStringz(strerror(errno)));
                // throw new Exception("epoll errno");
            }

            debug(hioepoll) tracef("events: %s", events[0..ready]);
            foreach(i; 0..ready) {
                auto e = events[i];
                debug(hioepoll) tracef("got event %s", e);
                int fd = e.data.fd;

                if ( fd == signal_fd ) {
                    enum siginfo_items = 8;
                    signalfd_siginfo[siginfo_items] info;
                    debug(hioepoll) trace("got signal");
                    assert(signal_fd != -1);
                    while (true) {
                        auto rc = read(signal_fd, &info, info.sizeof);
                        if ( rc < 0 && errno == EAGAIN ) {
                            break;
                        }
                        enforce(rc > 0);
                        auto got_signals = rc / signalfd_siginfo.sizeof;
                        debug(hioepoll) tracef("read info %d, %s", got_signals, info[0..got_signals]);
                        foreach(si; 0..got_signals) {
                            auto signum = info[si].ssi_signo;
                            debug(hioepoll) tracef("signum: %d", signum);
                            foreach(s; signals[signum]) {
                                debug(hioepoll) tracef("processing signal handler %s", s);
                                try {
                                    SigHandlerDelegate h = s._handler;
                                    h(signum);
                                } catch (Exception e) {
                                    errorf("Uncaught exception: %s", e);
                                }
                            }
                        }
                    }
                    continue;
                }
                AppEvent ae;
                if ( e.events & EPOLLIN ) {
                    ae |= AppEvent.IN;
                }
                if (e.events & EPOLLOUT) {
                    ae |= AppEvent.OUT;
                }
                if (e.events & EPOLLERR) {
                    ae |= AppEvent.ERR;
                }
                if (e.events & EPOLLHUP) {
                    ae |= AppEvent.HUP;
                }
                debug(hioepoll) tracef("process event %02x on fd: %s, handler: %s", e.events, e.data.fd, fileHandlers[fd]);
                if ( fileHandlers[fd] !is null ) {
                    try {
                        fileHandlers[fd].eventHandler(e.data.fd, ae);
                    }
                    catch (Exception e) {
                        errorf("On file handler: %d, %s", fd, e);
                        throw e;
                    }
                }
            }
            auto toCatchUp = timingwheels.ticksToCatchUp(tick, now_real.stdTime);
            if(toCatchUp>0)
            {
                /*
                ** Some timers expired.
                ** --------------------
                ** Most of the time the number of this timers is  low, so  we optimize for
                ** this case: copy this small number of timers into small array, then ite-
                ** rate over this array.
                **
                ** Another case - number of expired timers > InExpTimersSize, so  we can't
                ** copy timers to this array. Then we just iterate over the result.
                **
                ** Why  do we need random access to any expired timer (so we have  to save 
                ** it in array or in map)  - because any timer handler may wish  to cancel
                ** another timer (and this another timer can also be in 'advance' result).
                ** Example - expired timer wakes up some task which cancel socket io timer.
                */
                advancedTimersHash = timingwheels.advance(toCatchUp);
                if (advancedTimersHash.length < InExpTimersSize)
                {
                    //
                    // this case happens most of the time - low number of timers per tick
                    // save expired timers into small array.
                    //
                    int j = 0;
                    foreach(t; advancedTimersHash.timers)
                    {
                        advancedTimersArray[j++] = t;
                    }
                    advancedTimersArrayLength = j;
                    for(j=0;j < advancedTimersArrayLength; j++)
                    {
                        Timer t = advancedTimersArray[j];
                        if ( t is null )
                        {
                            continue;
                        }
                        HandlerDelegate h = t._handler;
                        assert(t._armed);
                        t._armed = false;
                        try {
                            h(AppEvent.TMO);
                        } catch (Exception e) {
                            errorf("Uncaught exception: %s", e);
                        }
                    }
                }
                else
                {
                    advancedTimersHashLength = advancedTimersHash.length;
                    foreach (t; advancedTimersHash.timers)
                    {
                        HandlerDelegate h = t._handler;
                        assert(t._armed);
                        t._armed = false;
                        try {
                            h(AppEvent.TMO);
                        } catch (Exception e) {
                            errorf("Uncaught exception: %s", e);
                        }
                    }
                }
                advancedTimersArrayLength = 0;
                advancedTimersHashLength = 0;
            }
            execute_overdue_timers();
            if (!runInfinitely && now_real >= deadline)
            {
                debug(hioepoll) safe_tracef("reached deadline, return");
                return;
            }
        }
    }
    void start_timer(Timer t) @safe {
        debug(hioepoll) safe_tracef("insert timer: %s", t);
        auto now = Clock.currTime;
        auto d = t._expires - now;
        d = max(d, 0.seconds);
        if ( d < tick ) {
            overdue ~= t;
            return;
        }
        assert(!t._armed);
        t._armed = true;
        ulong twNow = timingwheels.currStdTime(tick);
        Duration twdelay = (now.stdTime - twNow).hnsecs;
        debug(hioepoll) safe_tracef("tw delay: %s", (now.stdTime - twNow).hnsecs);
        timingwheels.schedule(t, (d + twdelay)/tick);
    }

    void stop_timer(Timer t) @safe {
        debug(hioepoll) safe_tracef("remove timer %s", t);
        if ( advancedTimersArrayLength > 0)
        {
            for(int j=0; j<advancedTimersArrayLength;j++)
            {
                if ( t is advancedTimersArray[j])
                {
                    advancedTimersArray[j] = null;
                    return;
                }
            }
        }
        else if (advancedTimersHashLength>0 && advancedTimersHash.contains(t.id))
        {
            advancedTimersHash.remove(t.id);
            return;
        }

        if (timingwheels.totalTimers() > 0)
        {
            // static destructors can try to stop timers after loop deinit
            timingwheels.cancel(t);
        }
    }

    //
    // signals
    //
    void start_signal(Signal s) {
        debug(hioepoll) tracef("start signal %s", s);
        debug(hioepoll) tracef("signals: %s", signals);
        auto r = s._signum in signals;
        if ( r is null || r.length == 0 ) {
            // enable signal only through kevent
            _add_kernel_signal(s);
        }
        signals[s._signum] ~= s;
    }
    void stop_signal(Signal s) {
        debug(hioepoll) trace("stop signal");
        auto r = s._signum in signals;
        if ( r is null ) {
            throw new NotFoundException("You tried to stop signal that was not started");
        }
        Signal[] new_row;
        foreach(a; *r) {
            if (a._id == s._id) {
                continue;
            }
            new_row ~= a;
        }
        if ( new_row.length == 0 ) {
            *r = null;
            _del_kernel_signal(s);
            // reenable old signal behaviour
        } else {
            *r = new_row;
        }
        debug(hioepoll) tracef("new signals %d row %s", s._signum, new_row);
    }
    void _add_kernel_signal(Signal s) {
        debug(hioepoll) tracef("add kernel signal %d, id: %d", s._signum, s._id);
        sigset_t m;
        sigemptyset(&m);
        sigaddset(&m, s._signum);
        pthread_sigmask(SIG_BLOCK, &m, null);

        sigaddset(&mask, s._signum);
        if ( signal_fd == -1 ) {
            signal_fd = signalfd(-1, &mask, SFD_NONBLOCK|SFD_CLOEXEC);
            debug(hioepoll) tracef("signalfd %d", signal_fd);
            epoll_event e;
            e.events = EPOLLIN|EPOLLET;
            e.data.fd = signal_fd;
            auto rc = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, signal_fd, &e);
            enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, fromStringz(strerror(errno))));
        } else {
            signalfd(signal_fd, &mask, 0);
        }

    }
    void _del_kernel_signal(Signal s) {
        debug(hioepoll) tracef("del kernel signal %d, id: %d", s._signum, s._id);
        sigset_t m;
        sigemptyset(&m);
        sigaddset(&m, s._signum);
        pthread_sigmask(SIG_UNBLOCK, &m, null);
        sigdelset(&mask, s._signum);
        assert(signal_fd != -1);
        signalfd(signal_fd, &mask, 0);
    }
    void wait_for_user_event(int event_id, FileEventHandler handler) @safe {
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = event_id;
        auto rc = (() @trusted => epoll_ctl(epoll_fd, EPOLL_CTL_ADD, event_id, &e))();
        enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, s_strerror(errno)));
        fileHandlers[event_id] = handler;
    }
    void stop_wait_for_user_event(int event_id, FileEventHandler handler) @safe {
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = event_id;
        auto rc = (() @trusted => epoll_ctl(epoll_fd, EPOLL_CTL_DEL, event_id, &e))();
        fileHandlers[event_id] = null;
    }

    int get_kernel_id() pure @safe nothrow @nogc {
        return epoll_fd;
    }

    //
    // files/sockets
    //
    void detach(int fd) @safe {
        debug(hioepoll) tracef("detaching fd(%d) from fileHandlers[%d]", fd, fileHandlers.length);
        fileHandlers[fd] = null;
    }
    void start_poll(int fd, AppEvent ev, FileEventHandler f) @trusted {
        assert(epoll_fd != -1);
        epoll_event e;
        e.events = appEventToSysEvent(ev);
        if ( ev & AppEvent.EXT_EPOLLEXCLUSIVE )
        {
            e.events |= EPOLLEXCLUSIVE;
        }
        e.data.fd = fd;
        auto rc = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd, &e);
        enforce(rc >= 0, "epoll_ctl add(%d, %s): %s".format(fd, e, fromStringz(strerror(errno))));
        fileHandlers[fd] = f;
    }

    void stop_poll(int fd, AppEvent ev) @trusted {
        assert(epoll_fd != -1);
        epoll_event e;
        e.events = appEventToSysEvent(ev);
        e.data.fd = fd;
        auto rc = epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, &e);
    }
    auto appEventToSysEvent(AppEvent ae) pure @safe {
        import core.bitop;
        // clear EXT_ flags
        ae &= AppEvent.ALL;
        assert( popcnt(ae) == 1, "Set one event at a time, you tried %x, %s".format(ae, appeventToString(ae)));
        assert( ae <= AppEvent.CONN, "You can ask for IN,OUT,CONN events");
        switch ( ae ) {
            case AppEvent.IN:
                return EPOLLIN;
            case AppEvent.OUT:
                return EPOLLOUT;
            //case AppEvent.CONN:
            //    return EVFILT_READ;
            default:
                throw new Exception("You can't wait for event %X".format(ae));
        }
    }
}

