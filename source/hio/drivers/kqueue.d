module hio.drivers.kqueue;

version(OSX):

import std.algorithm;
import std.datetime;
import std.conv;
import std.string;
import std.container;
import std.stdio;
import std.exception;
import std.experimental.logger;
import std.typecons;
import std.experimental.allocator;
import std.experimental.allocator.mallocator;

import core.memory;

import std.algorithm.comparison: max;
import core.sys.posix.fcntl: open, O_RDONLY;
import core.sys.posix.unistd: close;

import core.sys.darwin.sys.event;

import core.sys.posix.signal;
import core.stdc.stdint : intptr_t, uintptr_t;
import core.stdc.string: strerror;
import core.stdc.errno: errno;

import timingwheels;

import hio.events;
import hio.common;

//enum : short {
//    EVFILT_READ =      (-1),
//    EVFILT_WRITE =     (-2),
//    EVFILT_AIO =       (-3),    /* attached to aio requests */
//    EVFILT_VNODE =     (-4),    /* attached to vnodes */
//    EVFILT_PROC =      (-5),    /* attached to struct proc */
//    EVFILT_SIGNAL =    (-6),    /* attached to struct proc */
//    EVFILT_TIMER =     (-7),    /* timers */
//    EVFILT_MACHPORT =  (-8),    /* Mach portsets */
//    EVFILT_FS =        (-9),    /* Filesystem events */
//    EVFILT_USER =      (-10),   /* User events */
//            /* (-11) unused */
//    EVFILT_VM =        (-12)   /* Virtual memory events */
//}

//enum : ushort {
///* actions */
//    EV_ADD  =                0x0001,          /* add event to kq (implies enable) */
//    EV_DELETE =              0x0002,          /* delete event from kq */
//    EV_ENABLE =              0x0004,          /* enable event */
//    EV_DISABLE =             0x0008          /* disable event (not reported) */
//}

//struct kevent_t {
//    uintptr_t       ident;          /* identifier for this event */
//    short           filter;         /* filter for event */
//    ushort          flags;          /* general flags */
//    uint            fflags;         /* filter-specific flags */
//    intptr_t        data;           /* filter-specific data */
//    void*           udata;
//}

//extern(C) int kqueue() @safe @nogc nothrow;
//extern(C) int kevent(int kqueue_fd, const kevent_t *events, int ne, const kevent_t *events, int ne,timespec* timeout) @safe @nogc nothrow;

auto s_kevent(A...)(A args) @trusted @nogc nothrow {
    return kevent(args);
}

Timer udataToTimer(T)(T udata) @trusted {
    return cast(Timer)udata;
}

struct NativeEventLoopImpl {
    immutable bool   native = true;
    immutable string _name = "kqueue";
    @disable this(this) {}
    private {
        bool stopped = false;
        enum MAXEVENTS = 512;

        int  kqueue_fd = -1;  // interface to kernel
        int  in_index;
        int  ready;

        timespec    ts;

        kevent_t[MAXEVENTS]     in_events;
        kevent_t[MAXEVENTS]     out_events;

        Duration                tick = 5.msecs;
        TimingWheels!Timer      timingwheels;
        Timer[]                 overdue;   // timers added with expiration in past placed here

        Signal[][int]           signals;   // this is signals container

        FileEventHandler[]      fileHandlers;

    }
    void initialize() @trusted nothrow
    {
        if ( kqueue_fd == -1) {
            kqueue_fd = kqueue();
        }
        debug(hiokqueue) safe_tracef("kqueue_fd=%d", kqueue_fd);
        fileHandlers = Mallocator.instance.makeArray!FileEventHandler(16*1024);
        GC.addRange(fileHandlers.ptr, fileHandlers.length*FileEventHandler.sizeof);
        timingwheels.init();
    }
    void deinit() @trusted {
        debug tracef("deinit");
        if ( kqueue_fd != -1 )
        {
            close(kqueue_fd);
            kqueue_fd = -1;
        }
        in_index = 0;
        GC.removeRange(&fileHandlers[0]);
        Mallocator.instance.dispose(fileHandlers);
    }
    int get_kernel_id() pure @safe nothrow @nogc {
        return kqueue_fd;
    }
    void stop() @safe pure {
        debug trace("mark eventloop as stopped");
        stopped = true;
    }

    timespec _calculate_timespec(SysTime deadline) @safe {
        timespec ts;

        auto now_real = Clock.currTime;
        Duration delta = deadline - now_real;
        debug(hiokqueue) safe_tracef("deadline - now_real: %s", delta);
        auto nextTWtimer = timingwheels.timeUntilNextEvent(tick, now_real.stdTime);
        debug(hiokqueue) safe_tracef("nextTWtimer: %s", nextTWtimer);
        delta = min(delta, nextTWtimer);

        delta = max(delta, 0.seconds);

        debug(hiokqueue) safe_tracef("delta = %s", delta);
        auto ds = delta.split!("seconds", "nsecs");
        ts.tv_sec = cast(typeof(timespec.tv_sec))ds.seconds;
        ts.tv_nsec = cast(typeof(timespec.tv_nsec))ds.nsecs;
        return ts;
    }

    private void execute_overdue_timers() @safe
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
                throw e;
                //errorf("Uncaught exception: %s", e);
            }
        }
    }

    void run(Duration d) @safe {

        immutable bool runInfinitely = (d == Duration.max);
        SysTime     deadline;

        if ( !runInfinitely ) {
            deadline = Clock.currTime + d;
        }
        else
        {
            deadline = SysTime.max;
        }

        debug tracef("evl run for %s", d);

        scope(exit) {
            stopped = false;
        }

        while(!stopped)
        {
            // handle overdue timers
            execute_overdue_timers();

            if (stopped) {
                break;
            } 
            ts = _calculate_timespec(deadline);

            debug(hiokqueue) safe_tracef("waiting for %s", ts);
            debug(hiokqueue) safe_tracef("waiting events %s", in_events[0..in_index]);

            ready = s_kevent(kqueue_fd,
                                cast(kevent_t*)&in_events[0], in_index,
                                cast(kevent_t*)&out_events[0], MAXEVENTS,
                                &ts);
            SysTime now_real = Clock.currTime;
            in_index = 0;
            debug tracef("kevent returned %d events", ready);
            debug tracef("");


            if ( ready < 0 ) {
                error("kevent returned error %s".format(s_strerror(errno)));
            }
            //
            // handle kernel events
            //
            foreach(i; 0..ready) {
                if ( stopped ) {
                    break;
                }
                auto e = out_events[i];
                debug tracef("got kevent[%d] %s, data: %d, udata: %0x", i, e, e.data, e.udata);

                switch (e.filter) {
                    case EVFILT_READ:
                        debug tracef("Read on fd %d", e.ident);
                        AppEvent ae = AppEvent.IN;
                        if ( e.flags & EV_ERROR) {
                            ae |= AppEvent.ERR;
                        }
                        if ( e.flags & EV_EOF) {
                            ae |= AppEvent.HUP;
                        }
                        int fd = cast(int)e.ident;
                        fileHandlers[fd].eventHandler(cast(int)e.ident, ae);
                        continue;
                    case EVFILT_WRITE:
                        debug tracef("Write on fd %d", e.ident);
                        AppEvent ae = AppEvent.OUT;
                        if ( e.flags & EV_ERROR) {
                            ae |= AppEvent.ERR;
                        }
                        if ( e.flags & EV_EOF) {
                            ae |= AppEvent.HUP;
                        }
                        int fd = cast(int)e.ident;
                        fileHandlers[fd].eventHandler(cast(int)e.ident, ae);
                        continue;
                    case EVFILT_SIGNAL:
                        assert(signals.length != 0);
                        auto signum = cast(int)e.ident;
                        debug tracef("received signal %d", signum);
                        assert(signals[signum].length > 0);
                        foreach(s; signals[signum]) {
                            debug tracef("processing signal handler %s", s);
                            try {
                                SigHandlerDelegate h = s._handler;
                                h(signum);
                            } catch (Exception e) {
                                errorf("Uncaught exception: %s", e.msg);
                            }
                        }
                        continue;
                    case EVFILT_USER:
                        handle_user_event(e);
                        continue;
                    default:
                        break;
                }
            }
            auto toCatchUp = timingwheels.ticksToCatchUp(tick, now_real.stdTime);
            if(toCatchUp>0)
            {
                auto wr = timingwheels.advance(toCatchUp);
                foreach(t; wr.timers)
                {
                    HandlerDelegate h = t._handler;
                    try {
                        h(AppEvent.TMO);
                    } catch (Exception e) {
                        throw e;
                        //errorf("Uncaught exception: %s", e);
                    }
                }
            }
            execute_overdue_timers();
            if (!runInfinitely && now_real >= deadline)
            {
                debug(hioepoll) safe_tracef("reached deadline, return");
                return;
            }
        }
    }

    void start_timer(Timer t) @trusted {
        debug(hiokqueue) safe_tracef("insert timer: %s", t);
        auto now = Clock.currTime;
        auto d = t._expires - now;
        d = max(d, 0.seconds);
        if ( d == 0.seconds ) {
            overdue ~= t;
            return;
        }
        ulong twNow = timingwheels.currStdTime(tick);
        Duration twdelay = (now.stdTime - twNow).hnsecs;
        debug(hiokqueue) safe_tracef("tw delay: %s", (now.stdTime - twNow).hnsecs);
        timingwheels.schedule(t, (d + twdelay)/tick);
    }

    // bool timer_cleared_from_out_events(kevent_t e) @safe pure nothrow @nogc {
    //     foreach(ref o; out_events[0..ready]) {
    //         if ( o.ident == e.ident && o.filter == e.filter && o.udata == e.udata ) {
    //             o.ident = 0;
    //             o.filter = 0;
    //             o.udata = null;
    //             return true;
    //         }
    //     }
    //     return false;
    // }

    void stop_timer(Timer t) @safe {
        debug(hiokqueue) safe_tracef("remove timer %s", t);
        timingwheels.cancel(t);
    }

    void flush() @trusted {
        if ( in_index == 0 ) {
            return;
        }
        // flush
        int rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
        enforce(rc>=0, "flush: kevent %s, %s".format(fromStringz(strerror(errno)), in_events[0..in_index]));
        in_index = 0;
    }

    bool fd_cleared_from_out_events(kevent_t e) @safe pure nothrow @nogc {
        foreach(ref o; out_events[0..ready]) {
            if ( o.ident == e.ident && o.filter == e.filter ) {
                o.ident = 0;
                o.filter = 0;
                return true;
            }
        }
        return false;
    }

    void detach(int fd) @safe {
        fileHandlers[fd] = null;
    }
    void start_poll(int fd, AppEvent ev, FileEventHandler h) @safe {
        assert(fd>=0);
        immutable filter = appEventToSysEvent(ev);
        debug tracef("start poll on fd %d for events %s", fd, appeventToString(ev));
        kevent_t e;
        e.ident = fd;
        e.filter = filter;
        e.flags = EV_ADD;
        if ( in_index == MAXEVENTS ) {
            flush();
        }
        in_events[in_index++] = e;
        fileHandlers[fd] = h;
    }
    void stop_poll(int fd, AppEvent ev) @safe {
        assert(fd>=0);
        immutable filter = appEventToSysEvent(ev);
        debug tracef("stop poll on fd %d for events %s", fd, appeventToString(ev));
        kevent_t e;
        e.ident = fd;
        e.filter = filter;
        e.flags = EV_DELETE|EV_DISABLE;
        fd_cleared_from_out_events(e);
        if ( in_index == MAXEVENTS ) {
            flush();
        }
        in_events[in_index++] = e;
        flush();
    }

    pragma(inline, true)
    void handle_user_event(kevent_t e) @safe {
        import core.thread;
        debug tracef("Got user event thread.id:%s event.id:%d", Thread.getThis().id(), e.ident);
        disable_user_event(e);
        auto h = fileHandlers[e.ident];
        h.eventHandler(kqueue_fd, AppEvent.USER);
    }

    void wait_for_user_event(int event_id, FileEventHandler handler) @safe {
        debug tracef("start waiting for user_event %s", event_id);
        fileHandlers[event_id] = handler;
        kevent_t e;
        e.ident = event_id;
        e.filter = EVFILT_USER;
        e.flags = EV_ADD;
        if ( in_index == MAXEVENTS ) {
            flush();
        }
        in_events[in_index++] = e;
    }
    void stop_wait_for_user_event(int event_id, FileEventHandler handler) @safe {
        debug tracef("start waiting for user_event %s", event_id);
        fileHandlers[event_id] = null;
        kevent_t e;
        e.ident = event_id;
        e.filter = EVFILT_USER;
        e.flags = EV_DELETE;
        if ( in_index == MAXEVENTS ) {
            flush();
        }
        in_events[in_index++] = e;
    }
    void disable_user_event(kevent_t e) @safe {
        e.flags = EV_DISABLE;
        if ( in_index == MAXEVENTS ) {
            flush();
        }
        in_events[in_index++] = e;
    }
    void _add_kernel_timer(in Timer t, in Duration d) @trusted {
        debug tracef("add kernel timer %s, delta %s", t, d);
        assert(d >= 0.seconds);
        intptr_t delay_ms;
        if ( d < 36500.days)
        {
            delay_ms = d.split!"msecs".msecs;
        }
        else
        {
            // https://github.com/opensource-apple/xnu/blob/master/bsd/kern/kern_event.c#L1188
            // OSX kerner refuses to set too large timer interwal with errno ERANGE
            delay_ms = 36500.days.split!"msecs".msecs;
        }
        kevent_t e;
        e.ident = 0;
        e.filter = EVFILT_TIMER;
        e.flags = EV_ADD | EV_ONESHOT;
        e.data = delay_ms;
        e.udata = cast(void*)t;
        if ( in_index == MAXEVENTS ) {
            flush();
        }
        in_events[in_index++] = e;
    }

    alias _mod_kernel_timer = _add_kernel_timer;

    void _del_kernel_timer() @safe {
        debug trace("del kernel timer");
        kevent_t e;
        e.ident = 0;
        e.filter = EVFILT_TIMER;
        e.flags = EV_DELETE;
        if ( in_index == MAXEVENTS ) {
            flush();
        }
        in_events[in_index++] = e;
    }

    /*
     * signal functions
     */

    void start_signal(Signal s) {
        debug tracef("start signal %s", s);
        debug tracef("signals: %s", signals);
        auto r = s._signum in signals;
        if ( r is null || r.length == 0 ) {
            // enable signal only through kevent
            _add_kernel_signal(s);
        }
        signals[s._signum] ~= s;
    }

    void stop_signal(Signal s) {
        debug trace("stop signal");
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
        debug tracef("new signals %d row %s", s._signum, new_row);
    }

    void _add_kernel_signal(in Signal s) {
        debug tracef("add kernel signal %d, id: %d", s._signum, s._id);
        signal(s._signum, SIG_IGN);

        kevent_t e;
        e.ident = s._signum;
        e.filter = EVFILT_SIGNAL;
        e.flags = EV_ADD;
        if ( in_index == MAXEVENTS ) {
            // flush
            int rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
            enforce(rc>=0, "_add_kernel_signal: kevent %s, %s".format(fromStringz(strerror(errno)), in_events[0..in_index]));
            in_index = 0;
        }
        in_events[in_index++] = e;
    }

    void _del_kernel_signal(in Signal s) {
        debug tracef("del kernel signal %d, id: %d", s._signum, s._id);

        signal(s._signum, SIG_DFL);

        kevent_t e;
        e.ident = s._signum;
        e.filter = EVFILT_SIGNAL;
        e.flags = EV_DELETE;
        if ( in_index == MAXEVENTS ) {
            // flush
            int rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
            enforce(rc>=0, "_add_kernel_signal: kevent %s, %s".format(fromStringz(strerror(errno)), in_events[0..in_index]));
            in_index = 0;
        }
        in_events[in_index++] = e;
    }
}

auto appEventToSysEvent(AppEvent ae) {
    import core.bitop;
    // clear EXT_ flags
    ae &= AppEvent.ALL;
    assert( popcnt(ae) == 1, "Set one event at a time, you tried %x, %s".format(ae, appeventToString(ae)));
    assert( ae <= AppEvent.CONN, "You can ask for IN,OUT,CONN events");
    switch ( ae ) {
        case AppEvent.IN:
            return EVFILT_READ;
        case AppEvent.OUT:
            return EVFILT_WRITE;
        case AppEvent.CONN:
            return EVFILT_READ;
        default:
            throw new Exception("You can't wait for event %X".format(ae));
    }
}
AppEvent sysEventToAppEvent(short se) {
    final switch ( se ) {
        case EVFILT_READ:
            return AppEvent.IN;
        case EVFILT_WRITE:
            return AppEvent.OUT;
        // default:
        //     throw new Exception("Unexpected event %d".format(se));
    }
}
unittest {
    import std.exception;
    import core.exception;

    assert(appEventToSysEvent(AppEvent.IN)==EVFILT_READ);
    assert(appEventToSysEvent(AppEvent.OUT)==EVFILT_WRITE);
    assert(appEventToSysEvent(AppEvent.CONN)==EVFILT_READ);
    //assertThrown!AssertError(appEventToSysEvent(AppEvent.IN | AppEvent.OUT));
    assert(sysEventToAppEvent(EVFILT_READ) == AppEvent.IN);
    assert(sysEventToAppEvent(EVFILT_WRITE) == AppEvent.OUT);
}
