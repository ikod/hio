module hio.drivers.select;

import std.datetime;
import std.container;
import std.experimental.logger;

import std.experimental.allocator;
import std.experimental.allocator.mallocator;
import std.typecons;

import std.string;
import std.algorithm.comparison: min, max;
import std.exception: enforce;
import core.thread;

version(Windows) {
    import core.sys.windows.winsock2;
}
version(Posix) {
    import core.sys.posix.sys.select;
}

import core.stdc.string: strerror;
import core.stdc.errno;
import core.stdc.signal;

import timingwheels;

import hio.events;
import hio.common;

//
// TODO add support for multiple select event loops
//
private enum                            sig_array_length = 256;
private static int[sig_array_length]    last_signal;
private static int                      last_signal_index;

extern(C) void sig_catcher(int signum) nothrow @nogc {
    last_signal[last_signal_index++] = signum;
}

private struct FileDescriptor {
    package {
        AppEvent            _polling = AppEvent.NONE;
    }
    string toString() const @safe {
        import std.format: format;
        return appeventToString(_polling);
        //return "FileDescriptor: filehandle: %d, events: %s".format(_fileno, appeventToString(_polling));
    }
}

struct FallbackEventLoopImpl {
    immutable string _name = "select";
    immutable numberOfDescriptors = 1024;

    private {
        fd_set                  read_fds;
        fd_set                  write_fds;
        fd_set                  err_fds;

        bool                    stopped = false;

        Signal[][int]           signals;

        FileDescriptor[numberOfDescriptors]    fileDescriptors;
        FileEventHandler[]      fileHandlers;

        Timer[]                 overdue;    // timers added with expiration in past or with cicks==0

        RedBlackTree!Timer      precise_timers;     // precise timers
        TimingWheels!Timer      timingwheels;       // timing wheels
        Duration                tick = 5.msecs;
        //CircBuff!Notification   notificationsQueue;
    }

    @disable this(this) {};

    void initialize() @safe nothrow {
        precise_timers = new RedBlackTree!Timer();
        fileHandlers = new FileEventHandler[](1024);
        timingwheels.init();
    }
    void deinit() @trusted {
        precise_timers = null;
        timingwheels = TimingWheels!(Timer)();
        timingwheels.init();
    }
    void stop() @safe {
        debug(hioselect) safe_tracef("mark eventloop as stopped");
        stopped = true;
    }

    private Duration timeUntilNextTimer()
    out(r;r>=0.seconds)
    {
        Duration result = Duration.max;
        ulong nowRT = Clock.currStdTime;

        if ( ! precise_timers.empty )
        {
            result = min(result, precise_timers.front._expires - SysTime(nowRT));
        }
        auto nextTWtimer = timingwheels.timeUntilNextEvent(tick, nowRT);
        nextTWtimer = max(nextTWtimer, 0.seconds);
        debug(hioselect) safe_tracef("prec: %s, timingwheel: %s", result, nextTWtimer);
        result = min(result, nextTWtimer);
        return result;
    }
    private timeval* _calculate_timeval(Duration d, timeval* tv)
    {
        if (d < 0.seconds)
        {
            d = 0.seconds;
        }
        immutable converted = d.split!("seconds", "usecs");
        tv.tv_sec  = cast(typeof(tv.tv_sec))converted.seconds;
        tv.tv_usec = cast(typeof(tv.tv_usec))converted.usecs;
        return tv;
    }
    private void execute_overdue_timers()
    {
        while (overdue.length > 0)
        {
            // execute timers which user requested with negative delay
            Timer t = overdue[0];
            overdue = overdue[1..$];
            debug(hioselect) safe_tracef("execute overdue %s", t);
            HandlerDelegate h = t._handler;
            try {
                h(AppEvent.TMO);
            } catch (Exception e) {
                errorf("Uncaught exception: %s", e);
            }
        }
    }
    // /**
    //  * Find shortest interval between now->deadline, now->earliest timer
    //  * If deadline expired or timer in past - set zero wait time
    //  */
    // timeval* _calculate_timeval(SysTime deadline, timeval* tv) {
    //     SysTime now = Clock.currTime;
    //     Duration d = deadline - now;
    //     if ( ! precise_timers.empty ) {
    //         d = min(d, precise_timers.front._expires - now);
    //     }
    //     d = min(d, timingwheels.timeUntilNextEvent(tick));
    //     d = max(d, 0.seconds);
    //     auto converted = d.split!("seconds", "usecs");
    //     tv.tv_sec  = cast(typeof(tv.tv_sec))converted.seconds;
    //     tv.tv_usec = cast(typeof(tv.tv_usec))converted.usecs;
    //     return tv;
    // }
    // timeval* _calculate_timeval(timeval* tv) {
    //     SysTime  now = Clock.currTime;
    //     Duration d;
    //     d = timers.front._expires - now;
    //     d = max(d, 0.seconds);
    //     auto converted = d.split!("seconds", "usecs");
    //     tv.tv_sec  = cast(typeof(tv.tv_sec))converted.seconds;
    //     tv.tv_usec = cast(typeof(tv.tv_usec))converted.usecs;
    //     return tv;
    // }
    void run(Duration d) {

        immutable bool runIndefinitely = (d == Duration.max);
        SysTime now = Clock.currTime;
        SysTime deadline;
        timeval tv;
        timeval* wait;

        if ( ! runIndefinitely ) {
            deadline = now + d;
        }

        debug(hioselect) safe_tracef("evl run %s",d);

        scope(exit) {
            stopped = false;
        }

        while (!stopped) {

            int fdmax = -1;

            execute_overdue_timers();

            if (stopped) {
                break;
            }

            while ( !precise_timers.empty && precise_timers.front._expires <= now) {
                debug(hioselect) safe_tracef("processing overdue from precise %s, lag: %s",
                        precise_timers.front, Clock.currTime - precise_timers.front._expires);
                Timer t = precise_timers.front;
                HandlerDelegate h = t._handler;
                precise_timers.removeFront;
                try {
                    h(AppEvent.TMO);
                } catch (Exception e) {
                    errorf("Uncaught exception: %s", e);
                }
                now = Clock.currTime;
            }
            if (stopped) {
                break;
            }

            FD_ZERO(&read_fds);
            FD_ZERO(&write_fds);
            FD_ZERO(&err_fds);

            foreach(int fd; 0..numberOfDescriptors) {
                AppEvent e = fileDescriptors[fd]._polling;
                if ( e == AppEvent.NONE ) {
                    continue;
                }
                debug(hioselect) safe_tracef("poll %d for %s", fd, fileDescriptors[fd]);
                if ( e & AppEvent.IN ) {
                    FD_SET(fd, &read_fds);
                }
                if ( e & AppEvent.OUT ) {
                    FD_SET(fd, &write_fds);
                }
                fdmax = max(fdmax, fd);
            }

            //
            // Next limits for wait time:
            // - deadline (user ask loop run duration d)
            // - or requested to run indefinitely
            // - next precise_timer
            // - next timingwheel timer
            //
            immutable untilTimer = timeUntilNextTimer();
            immutable untilDeadline = runIndefinitely ? Duration.max : deadline - Clock.currTime;
            immutable nextStop = min(untilTimer, untilDeadline);
            debug(hioselect) safe_tracef("untilTimer: %s, untilDeadline: %s", untilTimer, untilDeadline);
            if ( nextStop == Duration.max )
            {
                wait = null;
            }
            else
            {
                wait = _calculate_timeval(nextStop, &tv);
            }

            debug(hioselect) safe_tracef("waiting for events %s", wait is null?"forever":"%s".format(*wait));
            auto ready = select(fdmax+1, &read_fds, &write_fds, &err_fds, wait);
            debug(hioselect) safe_tracef("returned %d events", ready);
            if ( ready < 0 && errno == EINTR ) {
                int s_ind;
                while(s_ind < last_signal_index) {
                    int signum = last_signal[s_ind];
                    assert(signals[signum].length > 0);
                    foreach(s; signals[signum]) {
                        debug(hioselect) safe_tracef("processing signal handler %s", s);
                        try {
                            SigHandlerDelegate h = s._handler;
                            h(signum);
                        } catch (Exception e) {
                            errorf("Uncaught exception: %s", e);
                        }
                    }
                    s_ind++;
                }
                last_signal_index = 0;
                continue;
            }
            if ( ready < 0 )
            {
                errorf("on call: (%s, %s, %s, %s)", fdmax+1, read_fds, write_fds, tv);
                errorf("select returned error %s", fromStringz(strerror(errno)));
            }
            enforce(ready >= 0);
            if ( ready == 0 ) {
                ulong nowRT = Clock.currStdTime;
                // Timedout
                // check timingweels
                auto toCatchUp = timingwheels.ticksToCatchUp(tick, nowRT);
                if(toCatchUp>0)
                {
                    auto wr = timingwheels.advance(toCatchUp);
                    foreach(t; wr.timers)
                    {
                        HandlerDelegate h = t._handler;
                        try {
                            h(AppEvent.TMO);
                        } catch (Exception e) {
                            errorf("Uncaught exception: %s", e);
                        }
                    }
                }

                if ( precise_timers.length > 0 && precise_timers.front._expires <= now) do {
                    debug(hioselect) safe_tracef("processing %s, lag: %s",
                        precise_timers.front, Clock.currTime - precise_timers.front._expires);
                    Timer t = precise_timers.front;
                    HandlerDelegate h = t._handler;
                    assert(t._armed);
                    t._armed = false;
                    try {
                        h(AppEvent.TMO);
                    } catch (Exception e) {
                        errorf("Uncaught exception: %s", e);
                    }
                    // timer event handler can try to stop exactly this timer,
                    // so when we returned from handler we can have different front
                    // and we do not have to remove it.
                    if ( !precise_timers.empty && precise_timers.front == t ) {
                        precise_timers.removeFront;
                    }
                    now = Clock.currTime;
                } while (!precise_timers.empty && precise_timers.front._expires <= now );

                // handlers can install some late timers, so...
                execute_overdue_timers();

                now = Clock.currTime;
                if ( !runIndefinitely && now >= deadline ) {
                    debug(hioselect) safe_tracef("deadline reached");
                    return;
                }
            }
            if ( ready > 0 ) {
                foreach(int fd; 0..numberOfDescriptors) {
                    AppEvent e = fileDescriptors[fd]._polling;
                    if ( e == AppEvent.NONE ) {
                        continue;
                    }
                    debug(hioselect) safe_tracef("check %d for %s", fd, fileDescriptors[fd]);
                    if ( e & AppEvent.IN && FD_ISSET(fd, &read_fds) ) {
                        debug(hioselect) safe_tracef("got IN event on file %d", fd);
                        fileHandlers[fd].eventHandler(fd, AppEvent.IN);
                    }
                    if ( e & AppEvent.OUT && FD_ISSET(fd, &write_fds) ) {
                        debug(hioselect) safe_tracef("got OUT event on file %d", fd);
                        fileHandlers[fd].eventHandler(fd, AppEvent.OUT);
                    }
                }
            }
        }
    }

    void start_timer(Timer t) @trusted {
        debug(hioselect) safe_tracef("insert timer: %s", t);
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
        debug(hioselect) safe_tracef("tw delay: %s", (now.stdTime - twNow).hnsecs);
        timingwheels.schedule(t, (d + twdelay)/tick);
    }

    void stop_timer(Timer t) @trusted {
        debug(hioselect) safe_tracef("remove timer %s", t);
        {
            // static destructors can try to stop timers after loop deinit
            timingwheels.cancel(t);
        }
    }

    void start_precise_timer(Timer t) @trusted {
        debug(hioselect) safe_tracef("insert timer: %s", t);
        auto d = t._expires - Clock.currTime;
        d = max(d, 0.seconds);
        if ( d == 0.seconds ) {
            overdue ~= t;
            return;
        }
        precise_timers.insert(t);
    }

    void stop_precise_timer(Timer t) @trusted {
        assert(!precise_timers.empty, "You are trying to remove timer %s, but timer list is empty".format(t));
        debug(hioselect) safe_tracef("remove timer %s", t);
        auto r = precise_timers.equalRange(t);
        precise_timers.remove(r);
    }

    void start_poll(int fd, AppEvent ev, FileEventHandler h) pure @safe {
        enforce(fd >= 0, "fileno can't be negative");
        enforce(fd < numberOfDescriptors, "Can't use such big fd, recompile with larger numberOfDescriptors");
        debug(hioselect) safe_tracef("start poll on fd %d for events %s", fd, appeventToString(ev));
        fileDescriptors[fd]._polling |= ev;
        fileHandlers[fd] = h;
    }
    void stop_poll(int fd, AppEvent ev) @safe {
        enforce(fd >= 0, "fileno can't be negative");
        enforce(fd < numberOfDescriptors, "Can't use such big fd, recompile with larger numberOfDescriptors");
        debug(hioselect) safe_tracef("stop poll on fd %d for events %s", fd, appeventToString(ev));
        fileDescriptors[fd]._polling &= ev ^ AppEvent.ALL;
    }

    int get_kernel_id() @safe @nogc {
        return -1;
    }

    void wait_for_user_event(int event_id, FileEventHandler handler) @safe {
    
    }
    void stop_wait_for_user_event(int event_id, FileEventHandler handler) @safe {
    
    }

    void detach(int fd) @safe {
        fileHandlers[fd] = null;
    }

//    pragma(inline)
//    void processNotification(Notification ue) @safe {
//        ue.handler();
//    }

//    void postNotification(Notification notification, Broadcast broadcast = No.broadcast) @safe {
//        debug trace("posting notification");
//        if ( !notificationsQueue.full )
//        {
//            notificationsQueue.put(notification);
//            return;
//        }
//        // now try to find space for next notification
//        auto retries = 10 * notificationsQueue.Size;
//        while(notificationsQueue.full && retries > 0)
//        {
//            retries--;
//            auto _n = notificationsQueue.get();
//            processNotification(_n);
//        }
//        enforce(!notificationsQueue.full, "Can't clear space for next notification in notificatioinsQueue");
//        notificationsQueue.put(notification);
//    }
    void flush() {
    }
    void start_signal(Signal s) {
        debug(hioselect) safe_tracef("start signal %s", s);
        debug(hioselect) safe_tracef("signals: %s", signals);
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
        debug(hioselect) safe_tracef("new signals %d row %s", s._signum, new_row);
    }
    void _add_kernel_signal(Signal s) {
        signal(s._signum, &sig_catcher);
        debug(hioselect) safe_tracef("adding handler for signum %d: %x", s._signum, &this);
    }
    void _del_kernel_signal(Signal s) {
        signal(s._signum, SIG_DFL);
        debug(hioselect) safe_tracef("deleted handler for signum %d: %x", s._signum, &this);
    }
}
