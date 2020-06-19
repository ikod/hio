module hio.loop;

import std.traits;
import std.datetime;
import std.container;
import std.exception;
import std.experimental.logger;
import std.typecons;
import hio.drivers;
import hio.events;
import core.time;

import core.sys.posix.sys.socket;

enum Mode:int {NATIVE = 0, FALLBACK}

shared Mode globalLoopMode = Mode.NATIVE;

private static hlEvLoop[Mode.FALLBACK+1] _defaultLoop;

hlEvLoop getDefaultLoop(Mode mode = globalLoopMode) @safe nothrow {
    if ( _defaultLoop[mode] is null ) {
        _defaultLoop[mode] = new hlEvLoop(mode);
    }
    return _defaultLoop[mode];
}

shared static this() {
    uninitializeLoops();
};

shared static ~this() {
    uninitializeLoops();
};

package void uninitializeLoops() {
    if (_defaultLoop[Mode.NATIVE])
    {
        _defaultLoop[Mode.NATIVE].deinit();
        _defaultLoop[Mode.NATIVE] = null;
    }
    if (_defaultLoop[Mode.FALLBACK])
    {
        _defaultLoop[Mode.FALLBACK].deinit();
        _defaultLoop[Mode.FALLBACK] = null;
    }
}

version (unittest)
{
    // XXX remove when https://issues.dlang.org/show_bug.cgi?id=20256 fixed
    extern (C) __gshared string[] rt_options = ["gcopt=parallel:0"];
}

///
/// disable default signal handling if you plan to handle signal in
/// child threads
///
void ignoreSignal(int signum) {
    version (linux) {
        import core.sys.posix.signal;

        sigset_t m;
        sigemptyset(&m);
        sigaddset(&m, signum);
        pthread_sigmask(SIG_BLOCK, &m, null);
    }
    version (OSX) {
        import core.sys.posix.signal;

        sigset_t m;
        sigemptyset(&m);
        sigaddset(&m, signum);
        pthread_sigmask(SIG_BLOCK, &m, null);
    }
}

final class hlEvLoop {
    package:
        NativeEventLoopImpl           _nimpl;
        FallbackEventLoopImpl         _fimpl;
        string                        _name;

    public:
        void delegate(scope Duration = Duration.max)       run;
        @safe void delegate()                              stop;
        @safe void delegate(Timer)                         startTimer;
        @safe void delegate(Timer)                         stopTimer;
        void delegate(Signal)                              startSignal;
        void delegate(Signal)                              stopSignal;
        @safe void delegate(int, AppEvent, FileEventHandler)   startPoll; // start listening to some events
        @safe void delegate(int, AppEvent)                 stopPoll;  // stop listening to some events
        @safe void delegate(int)                           detach;    // detach file from loop
        //@safe void delegate(Notification, Broadcast)       postNotification;
        @safe void delegate()                              deinit;
        @safe void delegate(int, FileEventHandler)         waitForUserEvent;
        @safe void delegate(int, FileEventHandler)         stopWaitForUserEvent;
        @safe @nogc int delegate()                         getKernelId;


    public:
        string name() const pure nothrow @safe @property {
            return _name;
        }
        this(Mode m = Mode.NATIVE) @safe nothrow {
            switch(m) {
            case Mode.NATIVE:
                _name = _nimpl._name;
                _nimpl.initialize();
                run = &_nimpl.run;
                stop = &_nimpl.stop;
                startTimer = &_nimpl.start_timer;
                stopTimer = &_nimpl.stop_timer;
                startSignal = &_nimpl.start_signal;
                stopSignal = &_nimpl.stop_signal;
                startPoll = &_nimpl.start_poll;
                stopPoll = &_nimpl.stop_poll;
                detach = &_nimpl.detach;
                //postNotification = &_nimpl.postNotification;
                deinit = &_nimpl.deinit;
                waitForUserEvent = &_nimpl.wait_for_user_event;
                stopWaitForUserEvent = &_nimpl.stop_wait_for_user_event;
                getKernelId = &_nimpl.get_kernel_id;
                break;
            case Mode.FALLBACK:
                _name = _fimpl._name;
                _fimpl.initialize();
                run = &_fimpl.run;
                stop = &_fimpl.stop;
                startTimer = &_fimpl.start_timer;
                stopTimer = &_fimpl.stop_timer;
                startSignal = &_fimpl.start_signal;
                stopSignal = &_fimpl.stop_signal;
                startPoll = &_fimpl.start_poll;
                stopPoll = &_fimpl.stop_poll;
                detach = &_fimpl.detach;
                //postNotification = &_fimpl.postNotification;
                deinit = &_fimpl.deinit;
                waitForUserEvent = &_fimpl.wait_for_user_event;
                stopWaitForUserEvent = &_fimpl.stop_wait_for_user_event;
                getKernelId = &_fimpl.get_kernel_id;
                break;
            default:
                assert(0, "Unknown loop mode");
            }
        }
}

unittest {
    import std.stdio;
    globalLogLevel = LogLevel.info;
    auto best_loop = getDefaultLoop();
    auto fallback_loop = getDefaultLoop(Mode.FALLBACK);
    writefln("Native   event loop: %s", best_loop.name);
    writefln("Fallback event loop: %s", fallback_loop.name);
}

unittest {
    info(" === test 'stop before start' ===");
    // stop before start
    auto native = new hlEvLoop();
    auto fallb = new hlEvLoop(Mode.FALLBACK);
    auto loops = [native, fallb];
    foreach(loop; loops)
    {
        infof(" --- '%s' loop ---", loop.name);
        auto now = Clock.currTime;
        loop.stop();
        loop.run(1.seconds);
        assert(Clock.currTime - now < 1.seconds);
    }
    native.deinit();
    fallb.deinit();
}

unittest {
    info(" === Testing timers ===");
}
@safe unittest {
    int i1, i2;
    HandlerDelegate h1 = delegate void(AppEvent e) {tracef("h1 called");i1++;};
    HandlerDelegate h2 = delegate void(AppEvent e) {tracef("h2 called");i2++;};
    {
        auto now = Clock.currTime;
        Timer a = new Timer(now, h1);
        Timer b = new Timer(now, h1);
        assert(b>a);
    }
    {
        auto now = Clock.currTime;
        Timer a = new Timer(now, h1);
        Timer b = new Timer(now + 1.seconds, h1);
        assert(b>a);
    }
}

unittest {
    import core.thread;
    import std.format;
    int i1, i2;
    HandlerDelegate h1 = delegate void(AppEvent e) {tracef("h1 called");i1++;};
    HandlerDelegate h2 = delegate void(AppEvent e) {tracef("h2 called");i2++;};
    auto native = new hlEvLoop();
    auto fallb = new hlEvLoop(Mode.FALLBACK);
    auto loops = [native, fallb];
    foreach(loop; loops)
    {
        globalLogLevel = LogLevel.info;
        infof(" --- '%s' loop ---", loop.name);
        i1 = i2 = 0;
        info("test start/stop timer before loop run");
        /** test startTimer, and then stopTimer before runLoop */
        auto now = Clock.currTime;
        Timer a = new Timer(now + 100.msecs, h1);
        Timer b = new Timer(now + 1000.msecs, h2);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.stopTimer(b);
        loop.run(200.msecs);
        assert(i1==1);
        assert(i2==0);

        /** stop event loop inside from timer **/
        infof("stop event loop inside from timer");
        now = Clock.currTime;

        i1 = 0;
        a = new Timer(10.msecs, (AppEvent e) @safe {
            loop.stop();
        });
        b = new Timer(110.msecs, h1);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.run(Duration.max);
        assert(i1 == 0);
        loop.stopTimer(b);

        info("test pending timer events");
        loop.run(50.msecs);
        i1 = 0;
        a = new Timer(50.msecs, h1);
        loop.startTimer(a);
        loop.run(10.msecs);
        assert(i1==0, "i1 expected 0, got %d".format(i1));
        Thread.sleep(45.msecs);
        loop.run(0.seconds);
        assert(i1==1, "i1 expected 1, got %d".format(i1));

        info("testing overdue timers");
        int[]   seq;
        auto    slow = delegate void(AppEvent e) @trusted {Thread.sleep(20.msecs); seq ~= 1;};
        auto    fast = delegate void(AppEvent e) @safe {seq ~= 2;};
        a = new Timer(50.msecs, slow);
        b = new Timer(60.msecs, fast);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.run(100.msecs);
        assert(seq == [1,2]);

        a = new Timer(-5.seconds, fast);
        loop.startTimer(a);
        loop.run(0.seconds);

        assert(seq == [1,2,2]);

        seq = new int[](0);
        /** test setting overdue timer inside from overdue timer **/
        auto set_next = delegate void(AppEvent e) {
            b = new Timer(-10.seconds, fast);
            loop.startTimer(b);
        };
        a = new Timer(-5.seconds, set_next);
        loop.startTimer(a);
        loop.run(10.msecs);
        assert(seq == [2]);

        seq = new int[](0);
        /** test setting overdue timer inside from normal timer **/
        set_next = delegate void(AppEvent e) {
            b = new Timer(-10.seconds, fast);
            loop.startTimer(b);
        };
        a = new Timer(50.msecs, set_next);
        loop.startTimer(a);
        loop.run(60.msecs);
        assert(seq == [2]);

        info("timer execution order");
        now = Clock.currTime;
        seq.length = 0;
        HandlerDelegate sh1 = delegate void(AppEvent e) {seq ~= 1;};
        HandlerDelegate sh2 = delegate void(AppEvent e) {seq ~= 2;};
        HandlerDelegate sh3 = delegate void(AppEvent e) {seq ~= 3;};
        assertThrown(new Timer(SysTime.init, null));
        a = new Timer(now + 500.msecs, sh1);
        b = new Timer(now + 500.msecs, sh2);
        Timer c = new Timer(now + 300.msecs, sh3);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.startTimer(c);
        loop.run(510.msecs);
        //assert(seq == [3, 1, 2]); // this should work only with precise

        // info("exception handling in timer");
        // HandlerDelegate throws = delegate void(AppEvent e){throw new Exception("test exception");};
        // a = new Timer(50.msecs, throws);
        // loop.startTimer(a);
        // auto logLevel = globalLogLevel;
        // globalLogLevel = LogLevel.fatal;
        // loop.run(100.msecs);
        // globalLogLevel = logLevel;
        // infof(" --- end ---");
    }
    native.deinit();
    fallb.deinit();
}

unittest {
    info("=== Testing signals ===");
    auto savedloglevel = globalLogLevel;
    //globalLogLevel = LogLevel.trace;
    import core.sys.posix.signal;
    import core.thread;
    import core.sys.posix.unistd;
    import core.sys.posix.sys.wait;

    int i1, i2;
    auto native = new hlEvLoop();
    auto fallb = new hlEvLoop(Mode.FALLBACK);
    auto loops = [native, fallb];
    SigHandlerDelegate h1 = delegate void(int signum) {
        i1++;
    };
    SigHandlerDelegate h2 = delegate void(int signum) {
        i2++;
    };
    foreach(loop; loops) {
        infof("testing loop '%s'", loop.name);
        i1 = i2 = 0;
        auto sighup1 = new Signal(SIGHUP, h1);
        auto sighup2 = new Signal(SIGHUP, h2);
        auto sigint1 = new Signal(SIGINT, h2);
        foreach(s; [sighup1, sighup2, sigint1]) {
            loop.startSignal(s);
        }
        auto parent_pid = getpid();
        auto child_pid = fork();
        if ( child_pid == 0 ) {
            Thread.sleep(500.msecs);
            kill(parent_pid, SIGHUP);
            kill(parent_pid, SIGINT);
            _exit(0);
        } else {
            loop.run(1.seconds);
            waitpid(child_pid, null, 0);
        }
        assert(i1 == 1);
        assert(i2 == 2);
        foreach(s; [sighup1, sighup2, sigint1]) {
            loop.stopSignal(s);
        }
        loop.run(1.msecs); // send stopSignals to kernel
    }
    native.deinit();
    fallb.deinit();
    globalLogLevel = savedloglevel;
}

unittest {
    globalLogLevel = LogLevel.info;
    info(" === Testing sockets ===");
    import std.string, std.stdio;
    import hio.socket;

    auto native = new hlEvLoop();
    auto fallb = new hlEvLoop(Mode.FALLBACK);
    auto loops = [native, fallb];
    foreach(loop; loops) {
        infof("testing loop '%s'", loop.name);
        immutable limit = 1;
        int requests = 0;
        int responses = 0;
        hlSocket client, server;
        immutable(ubyte)[] input;
        immutable(ubyte)[] response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".representation;
        string request = "GET / HTTP/1.1\r\nId: %d\r\n\r\n";
    
        void server_handler(AsyncSocketLike so) @safe {
            auto s = cast(hlSocket)so;
            tracef("server accepted on %s", s.fileno());
            IORequest iorq;
            iorq.to_read = 512;
            iorq.callback = (IOResult r) {
                if ( r.timedout ) {
                    s.close();
                    return;
                }
                s.send(response);
                s.close();
            };
            s.io(loop, iorq, dur!"seconds"(10));
        }
    
        void client_handler(AppEvent e) @safe {
            tracef("connection app handler");
            if ( e & (AppEvent.ERR|AppEvent.HUP) ) {
                tracef("error on %s", client);
                client.close();
                return;
            }
            tracef("sending to %s", client);
            auto rc = client.send(request.format(requests).representation());
            if ( rc == -1 ) {
                tracef("error on %s", client);
                client.close();
                return;
            }
            tracef("send returned %d", rc);
            IORequest iorq;
            iorq.to_read = 512;
            iorq.callback = (IOResult r) {
                if ( r.timedout ) {
                    info("Client timeout waiting for response");
                    client.close();
                    return;
                }
                // client received response from server
                responses++;
                client.close();
                if ( ++requests < limit ) {
                    client = new hlSocket();
                    client.open();
                    client.connect("127.0.0.1:16000", loop, &client_handler, dur!"seconds"(5));
                }
            };
            client.io(loop, iorq, 10.seconds);
        }
    
        server = new hlSocket();
        server.open();
        assert(server.fileno() >= 0);
        scope(exit) {
            debug tracef("closing server socket %s", server);
            server.close();
        }
        tracef("server listen on %d", server.fileno());
        server.bind("0.0.0.0:16000");
        server.listen();
        server.accept(loop, Duration.max, &server_handler);
    
        loop.startTimer(new Timer(50.msecs,  (AppEvent e) @safe {
            client = new hlSocket();
            client.open();
            client.connect("127.0.0.1:16000", loop, &client_handler, 5.seconds);
        }));

        loop.startTimer(new Timer(100.msecs,  (AppEvent e) @safe {
            client = new hlSocket();
            client.open();
            client.connect("127.0.0.1:16001", loop, &client_handler, 5.seconds);
        }));
    
        loop.run(1.seconds);
        assert(responses == limit, "%s != %s".format(responses, limit));
        globalLogLevel = LogLevel.info;
    }
    native.deinit();
    fallb.deinit();
}
