module hio.drivers.kqueue;

version(OSX):

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

        RedBlackTree!Timer      timers;    // this is timers contaiers
        Timer[]                 overdue;   // timers added with expiration in past placed here

        Signal[][int]           signals;   // this is signals container

        FileEventHandler[]      fileHandlers;

//        CircBuff!NotificationDelivery
//                                notificationsQueue;

        //HandlerDelegate[]       userEventHandlers;
    }
    void initialize() @trusted nothrow {
        if ( kqueue_fd == -1) {
            kqueue_fd = kqueue();
        }
        debug try{tracef("kqueue_fd=%d", kqueue_fd);}catch(Exception e){}
        timers = new RedBlackTree!Timer();
        fileHandlers = Mallocator.instance.makeArray!FileEventHandler(16*1024);
        GC.addRange(fileHandlers.ptr, fileHandlers.length*FileEventHandler.sizeof);
    }
    void deinit() @trusted {
        debug tracef("deinit");
        if ( kqueue_fd != -1 )
        {
            close(kqueue_fd);
            kqueue_fd = -1;
        }
        in_index = 0;
        timers = null;
        GC.removeRange(&fileHandlers[0]);
        Mallocator.instance.dispose(fileHandlers);
        //Mallocator.instance.dispose(userEventHandlers);
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
        Duration delta = deadline - Clock.currTime;
        delta = max(delta, 0.seconds);
        debug tracef("delta = %s", delta);
        auto ds = delta.split!("seconds", "nsecs");
        ts.tv_sec = cast(typeof(timespec.tv_sec))ds.seconds;
        ts.tv_nsec = cast(typeof(timespec.tv_nsec))ds.nsecs;
        return ts;
    }

    void run(Duration d) @safe {

        immutable bool runIndefinitely = (d == Duration.max);
        SysTime     deadline;
        timespec*   wait;

        if ( !runIndefinitely ) {
            deadline = Clock.currTime + d;
        }

        debug tracef("evl run for %s", d);

        scope(exit) {
            stopped = false;
        }

        while(!stopped) {
            //
            // handle user events(notifications)
            //
            //auto counter = notificationsQueue.Size * 10;
            //while(!notificationsQueue.empty){
            //    auto nd = notificationsQueue.get();
            //    Notification n = nd._n;
            //    Broadcast b = nd._broadcast;
             //   n.handler(b);
            //    counter--;
            //    enforce(counter > 0, "Can't clear notificatioinsQueue");
           // }
            //
            // handle overdue timers
            //
            while (overdue.length > 0) {
                // execute timers which user requested with negative delay
                Timer t = overdue[0];
                overdue = overdue[1..$];
                debug tracef("execute overdue %s", t);
                HandlerDelegate h = t._handler;
                try {
                    h(AppEvent.TMO);
                } catch (Exception e) {
                    errorf("Uncaught exception: %s", e.msg);
                }
            }
            if (stopped) {
                break;
            } 
            ts = _calculate_timespec(deadline);

            wait = runIndefinitely ?
                      null
                    : &ts;

            debug tracef("waiting for %s", wait is null?"forever":"%s".format(*wait));
            debug tracef("waiting events %s", in_events[0..in_index]);
            ready = s_kevent(kqueue_fd,
                                cast(kevent_t*)&in_events[0], in_index,
                                cast(kevent_t*)&out_events[0], MAXEVENTS,
                                wait);
            in_index = 0;
            debug tracef("kevent returned %d events", ready);
            debug tracef("");


            if ( ready < 0 ) {
                error("kevent returned error %s".format(s_strerror(errno)));
            }
            enforce(ready >= 0);
            if ( ready == 0 ) {
                debug trace("kevent timedout and no events to process");
                return;
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
                    case EVFILT_TIMER:
                        /*
                         * Invariants for timers
                         * ---------------------
                         * timer list must not be empty at event.
                         * we have to receive event only on the earliest timer in list
                        */
                        assert(!timers.empty, "timers empty on timer event: %s".format(out_events[0..ready]));
                        if ( udataToTimer(e.udata) !is timers.front) {
                            errorf("timer event: %s != timers.front: %s", udataToTimer(e.udata), timers.front);
                            //errorf("timers=%s", to!string(timers));
                            errorf("events=%s", out_events[0..ready]);
                            assert(0);
                        }
                        /* */

                        auto now = Clock.currTime;

                        do {
                            debug tracef("processing %s, lag: %s", timers.front, Clock.currTime - timers.front._expires);
                            Timer t = timers.front;
                            HandlerDelegate h = t._handler;
                            try {
                                h(AppEvent.TMO);
                            } catch (Exception e) {
                                errorf("Uncaught exception: %s", e.msg);
                            }
                            // timer event handler can try to stop exactly this timer,
                            // so when we returned from handler we can have different front
                            // and we do not have to remove it.
                            if ( !timers.empty && timers.front is t ) {
                                timers.removeFront;
                            }
                            now = Clock.currTime;
                        } while (!timers.empty && timers.front._expires <= now );

                        if ( ! timers.empty ) {
                            Duration kernel_delta = timers.front._expires - now;
                            assert(kernel_delta > 0.seconds);
                            _mod_kernel_timer(timers.front, kernel_delta);
                        } else {
                            // kqueue do not require deletion here
                        }

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
        }
    }

    void start_timer(Timer t) @trusted {
        debug tracef("insert timer %s - %X", t, cast(void*)t);
        if ( timers.empty || t < timers.front ) {
            auto d = t._expires - Clock.currTime;
            d = max(d, 0.seconds);
            if ( d == 0.seconds ) {
                overdue ~= t;
                return;
            }
            if ( timers.empty ) {
                _add_kernel_timer(t, d);
            } else {
                _mod_kernel_timer(t, d);
            }
        }
        timers.insert(t);
    }

    bool timer_cleared_from_out_events(kevent_t e) @safe pure nothrow @nogc {
        foreach(ref o; out_events[0..ready]) {
            if ( o.ident == e.ident && o.filter == e.filter && o.udata == e.udata ) {
                o.ident = 0;
                o.filter = 0;
                o.udata = null;
                return true;
            }
        }
        return false;
    }

    void stop_timer(Timer t) @trusted {

        assert(!timers.empty, "You are trying to remove timer %s, but timer list is empty".format(t));

        debug tracef("timers: %s", timers);
        if ( t != timers.front ) {
            debug tracef("remove non-front %s", t);
            auto r = timers.equalRange(t);
            timers.remove(r);
            return;
        }

        kevent_t e;
        e.ident = 0;
        e.filter = EVFILT_TIMER;
        e.udata = cast(void*)t;
        auto cleared = timer_cleared_from_out_events(e);

        timers.removeFront();
        if ( timers.empty ) {
            if ( cleared ) {
                debug tracef("return because it is cleared");
                return;
            }
            debug tracef("we have to del this timer from kernel");
            _del_kernel_timer();
            return;
        }
        debug tracef("we have to set timer to next: %s, %s", out_events[0..ready], timers);
        // we can change kernel timer to next,
        // If next timer expired - set delta = 0 to run on next loop invocation
        auto next = timers.front;
        auto d = next._expires - Clock.currTime;
        d = max(d, 0.seconds);
        _mod_kernel_timer(timers.front, d);
        return;
    }

//    pragma(inline, true)
//    void processNotification(Notification ue, Broadcast broadcast) @safe {
//        ue.handler();
//    }

//    void postNotification(Notification notification, Broadcast broadcast = No.broadcast) @safe {
//        debug trace("posting notification");
//        if ( !notificationsQueue.full )
//        {
//            debug trace("put notification");
//            notificationsQueue.put(NotificationDelivery(notification, broadcast));
//            debug trace("put notification done");
//            return;
//        }
//        // now try to find space for next notification
//        auto retries = 10 * notificationsQueue.Size;
//        while(notificationsQueue.full && retries > 0)
//        {
//            retries--;
//            auto nd = notificationsQueue.get();
//            Notification _n = nd._n;
//            Broadcast _b = nd._broadcast;
//            processNotification(_n, _b);
//        }
//        enforce(!notificationsQueue.full, "Can't clear space for next notification in notificatioinsQueue");
//        notificationsQueue.put(NotificationDelivery(notification, broadcast));
//        debug trace("posting notification - done");
//    }
//
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
        intptr_t delay_ms = d.split!"msecs".msecs;
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
