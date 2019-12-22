module hio.scheduler;

import std.experimental.logger;

import core.thread;
import core.sync.mutex;
import std.concurrency;
import std.datetime;
import std.format;
import std.traits;
import std.exception;
import core.sync.condition;
import std.algorithm;
import std.typecons;
import std.range;

//import core.stdc.string;
//import core.stdc.errno;

//static import core.sys.posix.unistd;

import hio.events;
import hio.loop;
import hio.common;

import std.stdio;

struct TaskNotReady {
    string msg;
}

class NotReadyException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

void hlSleep(Duration d) {
    if ( d <= 0.seconds) {
        return;
    }
    auto tid = Fiber.getThis();
    assert(tid !is null);
    auto callback = delegate void (AppEvent e) @trusted
    {
        tid.call(Fiber.Rethrow.no);
    };
    auto t = new Timer(d, callback);
    getDefaultLoop().startTimer(t);
    Fiber.yield();
}

struct Box(T) {

    enum Void = is(T == void);

    static if (!Void) {
        T   _data;
    }
    SocketPair          _pair;
    Throwable   _exception;
    @disable this(this);
}

ReturnType!F App(F, A...) (F f, A args) {
    alias R = ReturnType!F;
    Box!R box;
    static if (!box.Void)
    {
        R r;
    }
    void _wrapper()
    {
        try
        {
            static if (!box.Void)
            {
                r = f(args);
                box._data = r;
            }
            else
            {
                f(args);
            }
        }
        catch (Throwable e)
        {
            debug tracef("app throwed %s", e);
            box._exception = e;
        }
        getDefaultLoop().stop();
    }

    shared void delegate() run = () {
        //
        // in the child thread:
        // 1. start new fiber (task over wrapper) with user supplied function
        // 2. start event loop forewer
        // 3. when eventLoop done(stopped inside from wrapper) the task will finish
        // 4. store value in box and use socketpair to send signal to caller thread
        //
        auto t = task(&_wrapper);
        auto e = t.start(Fiber.Rethrow.no);
        if ( box._exception is null ) { // box.exception can be filled before Fiber start
            box._exception = e;
        }
        getDefaultLoop.run(Duration.max);
        t.reset();
    };
    // Thread child = new Thread(run);
    // child.start();
    // child.join();
    run();
    if (box._exception)
    {
        throw box._exception;
    }
    static if (!box.Void)
    {
        debug tracef("joined, value = %s", box._data);
        return box._data;
    }
    else
    {
        debug tracef("joined");
    }
}
///
/// spawn thread or fiber, caal function and return value
///
// ReturnType!F callInThread(F, A...)(F f, A args) {
//     //
//     // When called inside from fiber we can and have to yield control to eventLoop
//     // when called from thread (eventLoop is not active, we can yield only to another thread)
//     // everything we can do is wait function for completion - just join cinld
//     //
//     if ( Fiber.getThis() )
//         return callFromFiber(f, args);
//     else
//         return callFromThread(f, args);
// }

// private ReturnType!F callFromFiber(F, A...)(F f, A args) {
//     auto tid = Fiber.getThis();
//     assert(tid, "You can call this function only inside from Task");

//     alias R = ReturnType!F;
//     enum  Void = is(ReturnType!F==void);
//     enum  Nothrow = [__traits(getFunctionAttributes, f)].canFind("nothrow");
//     Box!R box;
//     static if (!Void){
//         R   r;
//     }

//     // create socketpair for inter-thread signalling
//     box._pair = makeSocketPair();
//     scope(exit) {
//         box._pair.close();
//     }

//     ///
//     /// fiber where we call function, store result of exception and stop eventloop when execution completed
//     ///
//     void _wrapper() {
//         scope(exit)
//         {
//             getDefaultLoop().stop();
//         }
//         try {
//             static if (!Void) {
//                 r = f(args);
//                 box._data = r;
//             }
//             else {
//                 f(args);
//             }
//         } catch(shared(Exception) e) {
//             box._exception = e;
//         }
//     }

//     ///
//     /// this is child thread where we start fiber and event loop
//     /// when eventLoop completed signal parent thread and exit
//     ///
//     shared void delegate() run = () {
//         //
//         // in the child thread:
//         // 1. start new fiber (task over wrapper) with user supplied function
//         // 2. start event loop forewer
//         // 3. when eventLoop done(stopped inside from wrapper) the task will finish
//         // 4. store value in box and use socketpair to send signal to caller thread
//         //
//         auto t = task(&_wrapper);
//         t.call(Fiber.Rethrow.no);
//         getDefaultLoop.run(Duration.max);
//         getDefaultLoop.deinit();
//         ubyte[1] b = [0];
//         auto s = box._pair.write(1, b);
//         assert(t.ready);
//         assert(t.state == Fiber.State.TERM);
//         assert(s == 1);
//         debug trace("child thread done");
//     };

//     Thread child = new Thread(run).start();
//     //
//     // in the parent
//     // add socketpair[0] to eventloop for reading and wait for data on it
//     // yieldng until we receive data on the socketpair
//     // on event handler - sop polling on pipe and join child thread
//     //
//     final class ThreadEventHandler : FileEventHandler {
//         override void eventHandler(int fd, AppEvent e) @trusted
//         {
//             //
//             // maybe we have to read here, but actually we need only info about data availability
//             // so why read?
//             //
//             debug tracef("interthread signalling - read ready");
//             getDefaultLoop().stopPoll(box._pair[0], AppEvent.IN);
//             child.join();
//             debug tracef("interthread signalling - thread joined");
//             auto throwable = tid.call(Fiber.Rethrow.no);
//         }
//     }

//     // enable listening on socketpair[0] and yield
//     getDefaultLoop().startPoll(box._pair[0], AppEvent.IN, new ThreadEventHandler());
//     Fiber.yield();

//     // child thread completed
//     if ( box._exception ) {
//         throw box._exception;
//     }
//     static if (!Void) {
//         debug tracef("joined, value = %s", box._data);
//         return box._data;
//     } else {
//         debug tracef("joined");
//     }
// }

// private ReturnType!F callFromThread(F, A...)(F f, A args) {
//     auto tid = Fiber.getThis();
//     assert(tid is null, "You can't call this function from Task (or fiber)");

//     alias R = ReturnType!F;
//     enum  Void = is(ReturnType!F==void);
//     enum  Nothrow = [__traits(getFunctionAttributes, f)].canFind("nothrow");
//     Box!R box;
//     static if (!Void){
//         R   r;
//     }

//     void _wrapper() {
//         scope(exit)
//         {
//             getDefaultLoop().stop();
//         }
//         try {
//             static if (!Void){
//                 r = f(args);
//                 box._data = r;
//             }
//             else
//             {
//                 //writeln("calling");
//                 f(args);
//             }
//         } catch (shared(Exception) e) {
//             box._exception = e;
//         }
//     }

//     shared void delegate() run = () {
//         //
//         // in the child thread:
//         // 1. start new fiber (task over wrapper) with user supplied function
//         // 2. start event loop forewer
//         // 3. when eventLoop done(stopped inside from wrapper) the task will finish
//         // 4. store value in box and use socketpair to send signal to caller thread
//         //
//         auto t = task(&_wrapper);
//         t.call(Fiber.Rethrow.no);
//         getDefaultLoop.run(Duration.max);
//         getDefaultLoop.deinit();
//         assert(t.ready);
//         assert(t.state == Fiber.State.TERM);
//         trace("child thread done");
//     };
//     Thread child = new Thread(run).start();
//     child.join();
//     if ( box._exception ) {
//         throw box._exception;
//     }
//     static if (!Void) {
//         debug tracef("joined, value = %s", box._data);
//         return box._data;
//     } else {
//         debug tracef("joined");
//     }
// }

interface Computation {
    bool ready();
    bool wait(Duration t = Duration.max);
}

///
/// Run eventloop and task in separate thread.
/// Send what task returned or struct TaskNotReady if task not finished in time.
///
auto spawnTask(T)(T task, Duration howLong = Duration.max) {
    shared void delegate() run = () {
        Tid owner = ownerTid();
        Throwable throwable = task.call(Fiber.Rethrow.no);
        getDefaultLoop.run(howLong);
        scope (exit) {
            task.reset();
            getDefaultLoop.deinit();
        }
        if ( !task.ready) {
            owner.send(TaskNotReady("Task not finished in requested time"));
            return;
        }

        assert(task.state == Fiber.State.TERM);

        if ( throwable is null )
        {
            static if (!task.Void) {
                debug tracef("sending result %s", task.result);
                owner.send(task.result);
            }
            else
            {
                // have to send something as user code must wait for anything for non-daemons
                debug tracef("sending null");
                owner.send(null);
            }
        }
        else
        {
            immutable e = new Exception(throwable.msg);
            try
            {
                debug tracef("sending exception");
                owner.send(e);
            } catch (Exception ee)
            {
                errorf("Exception %s when sending exception %s", ee, e);
            }
        }
        debug tracef("task thread finished");
    };
    auto tid = spawn(run);
    return tid;
}

unittest
{
    globalLogLevel = LogLevel.info;
    info("test spawnTask");
    auto t0 = task(function int (){
        getDefaultLoop().stop();
        return 41;
    });
    auto t1 = task(function int (){
        hlSleep(200.msecs);
        getDefaultLoop().stop();
        return 42;
    });
    Tid tid = spawnTask(t0, 100.msecs);
    receive(
        (const int i)
        {
            assert(i == 41, "expected 41, got %s".format(i));
            // ok
        },
        (Variant v)
        {
            errorf("test wait task got variant %s of type %s", v, v.type);
            assert(0);
        }
    );
    tid = spawnTask(t1, 100.msecs);
    receive(
        (TaskNotReady e) {
            // ok
        },
        (Variant v)
        {
            errorf("test wait task got variant %s of type %s", v, v.type);
            assert(0);
        }
    );
}

enum Commands
{
    StopLoop,
    WakeUpLoop
}
///
class Threaded(F, A...) : Computation if (isCallable!F) {
    alias start = run;
    private {
        alias R = ReturnType!F;

        F           _f;
        A           _args;
        bool        _ready = false;
        Thread      _child;
        bool        _chind_joined; // did we called _child.join?
        Fiber       _parent;
        Box!R       _box;
        Timer       _t;
        enum Void = _box.Void;
        bool        _isDaemon;
        SocketPair  _commands;
    }
    final this(F f, A args) {
        _f = f;
        _args = args;
        _box._pair = makeSocketPair();
        _commands = makeSocketPair();
    }

    override bool ready() {
        return _ready;
    }
    auto isDaemon(bool v)
    {
        _isDaemon = v;
        return this;
    }
    auto isDaemon()
    {
        return _isDaemon;
    }
    static if (!Void) {
        R value() {
            if (_ready)
                return _box._data;
            throw new NotReadyException("You can't call value for non-ready task");
        }
    }
    void stopThreadLoop()
    {
        debug tracef("stopping loop in thread");
        ubyte[1] cmd = [Commands.StopLoop];
        _commands.write(1, cmd);
    }
    void wakeUpThreadLoop()
    {
        debug tracef("waking up loop in thread");
        ubyte[1] cmd = [Commands.WakeUpLoop];
        _commands.write(1, cmd);
    }
    override bool wait(Duration timeout = Duration.max) {
        if (_ready) {
            if ( !_chind_joined ) {
                _child.join();
                _chind_joined = true;
            }
            if ( _box._exception ) {
                throw _box._exception;
            }
            return true;
        }
        if ( timeout <= 0.seconds ) {
            // this is poll
            return _ready;
        }
        if ( timeout < Duration.max ) {
            // rize timer
            _t = new Timer(timeout, (AppEvent e) @trusted {
                getDefaultLoop().stopPoll(_box._pair[0], AppEvent.IN);
                debug tracef("threaded timed out");
                auto throwable = _parent.call(Fiber.Rethrow.no);
                _t = null;
            });
            getDefaultLoop().startTimer(_t);
        }
        // wait on the pair
        final class ThreadEventHandler : FileEventHandler
        {
            override void eventHandler(int fd, AppEvent e) @trusted
            {
                _box._pair.read(0, 1);
                getDefaultLoop().stopPoll(_box._pair[0], AppEvent.IN);
                debug tracef("threaded done");
                if ( _t ) {
                    getDefaultLoop.stopTimer(_t);
                    _t = null;
                }
                auto throwable = _parent.call(Fiber.Rethrow.no);
            }
        }
        _parent = Fiber.getThis();
        assert(_parent, "You can call this only trom fiber");
        debug tracef("wait - start listen on socketpair");
        //auto eh = new ThreadEventHandler();
        getDefaultLoop().startPoll(_box._pair[0], AppEvent.IN, new ThreadEventHandler());
        Fiber.yield();
        debug tracef("wait done");
        if ( _ready && !_chind_joined ) {
            _child.join();
            _chind_joined = true;
        }
        return _ready;
    }

    final auto run() {
        class CommandsHandler : FileEventHandler
        {
            override void eventHandler(int fd, AppEvent e)
            {
                assert(fd == _commands[0]);
                auto b = _commands.read(0, 1);
                final switch(b[0])
                {
                    case Commands.StopLoop:
                        debug safe_tracef("got stopLoop command");
                        getDefaultLoop.stop();
                        break;
                    case Commands.WakeUpLoop:
                        debug safe_tracef("got WakeUpLoop command");
                        break;
                }
            }
        }
        this._child = new Thread(
            {
                getDefaultLoop.deinit();
                uninitializeLoops();
                getDefaultLoop.startPoll(_commands[0], AppEvent.IN, new CommandsHandler());
                try {
                    debug safe_tracef("calling");
                    static if (!Void) {
                        _box._data = App(_f, _args);
                    }
                    else {
                        App(_f, _args);
                    }
                }
                catch (Throwable e) {
                    _box._exception = e;
                }
                ubyte[1] b = [0];
                _ready = true;
                auto s = _box._pair.write(1, b);
            }
        );
        this._child.isDaemon = _isDaemon;
        this._child.start();
        return this;
    }
}

///
/// Task. Exacute computation. Inherits from Fiber
/// you can start, wait, check for readiness.
///
class Task(F, A...) : Fiber, Computation if (isCallable!F) {
    enum  Void = is(ReturnType!F==void);
    alias start = call;
    private {
        alias R = ReturnType!F;

        F            _f;
        A            _args;
        bool         _ready;
        // Notification _done;
        Fiber        _waitor;
        Throwable    _exception;

        static if ( !Void ) {
            R       _result;
        }
    }

    final this(F f, A args)
    {
        _f = f;
        _args = args;
        _waitor = null;
        _exception = null;
        static if (!Void) {
            _result = R.init;
        }
        super(&run);
    }

    ///
    /// wait() - wait forewer
    /// wait(Duration) - wait with timeout
    /// 
    override bool wait(Duration timeout = Duration.max) {
        if ( _ready || timeout <= 0.msecs )
        {
            if ( _exception !is null ) {
                throw _exception;
            }
            return _ready;
        }
        assert(this._waitor is null, "You can't wait twice");
        this._waitor = Fiber.getThis();
        assert(_waitor !is null, "You can wait task only from another task or fiber");
        Timer t = new Timer(timeout, (AppEvent e) @trusted {
            auto w = _waitor;
            _waitor = null;
            w.call(Fiber.Rethrow.no);
        });
        getDefaultLoop().startTimer(t);
        debug tracef("yeilding task");
        Fiber.yield();
        if ( t )
        {
            getDefaultLoop().stopTimer(t);
        }
        if ( _exception !is null ) {
            throw _exception;
        }
        return _ready;
    }

    static if (!Void) {
        auto waitResult() {
            wait();
            enforce(_ready);
            return _result;
        }
    }

    override bool ready() const {
        return _ready;
    }
    static if (!Void) {
        @property
        final auto result() const {
            enforce!NotReadyException(_ready, "You can't get result from not ready task");
            return _result;
        }
        alias value = result;
    }
    private final void run() {
        static if ( Void )
        {
            try {
                _f(_args);
            } catch (Throwable e) {
                _exception = e;
                debug tracef("got throwable %s", e);
            }
            //debug tracef("run void finished, waitors: %s", this._waitor);
        }
        else 
        {
            try {
                _result = _f(_args);
            } catch(Throwable e) {
                _exception = e;
                debug tracef("got throwable %s", e);
            }
            //debug tracef("run finished, result: %s, waitor: %s", _result, this._waitor);
        }
        this._ready = true;
        if ( this._waitor ) {
            auto w = this._waitor;
            this._waitor = null;
            w.call();
        }
    }
}

auto task(F, A...)(F f, A a) {
    return new Task!(F,A)(f, a);
}

auto threaded(F, A...)(F f, A a) {
    return new Threaded!(F, A)(f, a);
}

unittest {
    int i;
    int f(int s) {
        i+=s;
        return(i);
    }
    auto t = task(&f, 1);
    t.call();
    assert(t.result == 1);
    assert(i==1, "i=%d, expected 1".format(i));
    assert(t.result == 1, "result: %d, expected 1".format(t.result));
}

unittest {
    auto v = App(function int() {
        Duration f(Duration t)
        {
            hlSleep(t);
            return t;
        }

        auto t100 = task(&f, 100.msecs);
        auto t200 = task(&f, 200.msecs);
        t100.start;
        t200.start;
        t100.wait();
        return 1;
    });
    assert(v == 1);
}

unittest
{
    // test wakeup thread loop and stop thread loop
    globalLogLevel = LogLevel.info;
    App({
        bool canary = true;
        auto t = threaded({
            hlSleep(10.seconds);
            canary = false;
        }).start;
        hlSleep(100.msecs);
        t.wakeUpThreadLoop();
        hlSleep(500.msecs);
        t.stopThreadLoop();
        assert(canary);
        t.wait();
    });
    globalLogLevel = LogLevel.info;
}

unittest
{
    globalLogLevel = LogLevel.info;
    auto v = App(function int() {
        Duration f(Duration t)
        {
            hlSleep(t);
            return t;
        }

        auto t100 = threaded(&f, 100.msecs).start;
        auto t200 = threaded(&f, 200.msecs).start;
        t200.wait(100.msecs);
        assert(!t200.ready);
        t100.wait(300.msecs);
        assert(t100.ready);
        assert(t100.value == 100.msecs);
        t200.wait();
        return 1;
    });
    assert(v == 1);
}

unittest
{
    import core.memory;
    // create lot of "daemon" tasks to check how they will survive GC collection.
    // 2019-12-01T22:38:53.301 [info] scheduler.d:783:__lambda2  create 10000 tasks
    // 2019-12-01T22:38:55.731 [info] scheduler.d:856:__unittest_L840_C1 test1 ok in FALLBACK mode
    enum tasks = 10_000;
    int N;
    void t0(int i) {
        if (i%5==0)
            hlSleep((i%1000).msecs);
        N++;
        // if (N==tasks)
        // {
        //     getDefaultLoop().stop();
        // }
    }
    App({
        infof(" create %d tasks", tasks);
        iota(tasks).each!((int i){
            auto t = task(&t0, i);
            t.start();
        });
        GC.collect();
        infof(" created, sleep and let all timers to expire");
//        globalLogLevel = LogLevel.trace;
        hlSleep(2.seconds);
    });
    assert(N==tasks);
    info("done");
}
// unittest {
//     //
//     // two tasks and spawned thread under event loop
//     //
//     globalLogLevel = LogLevel.info;
//     auto mode = globalLoopMode;
//     foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
//         globalLoopMode = m;
    
//         int counter1 = 10;
//         int counter2 = 20;
//         int f0() {
//             hlSleep(1.seconds);
//             return 1;
//         }
//         void f1() {
//             while(--counter1 > 0) {
//                 hlSleep(100.msecs);
//             }
//         }
//         void f2() {
//             while(--counter2 > 0) {
//                 hlSleep(50.msecs);
//             }
//         }
//         void f3() {
//             auto t1 = task(&f1);
//             auto t2 = task(&f2);
//             t1.start();
//             t2.start();
//             auto v = callInThread(&f0);
//             //
//             // t1 and t2 job must be done at this time
//             //
//             assert(counter1 == 0);
//             assert(counter2 == 0);
//             t1.wait();
//             t2.wait();
//             getDefaultLoop().stop();
//         }
//         auto t3 = task(&f3);
//         t3.start();
//         getDefaultLoop().run(1.seconds);
//         infof("test0 ok in %s mode", m);
//     }
//     globalLoopMode = mode;
// }

unittest {
    //
    // just to test that we received correct value at return
    //
    globalLogLevel = LogLevel.info;
    auto mode = globalLoopMode;
    scope(exit) {
        globalLoopMode = mode;
    }
    foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
        globalLoopMode = m;
        int f() {
            return 1;
        }
        auto v = App(&f);
        assert(v == 1, "expected v==1, but received v=%d".format(v));
        infof("test1 ok in %s mode", m);
    }
}

unittest {
    //
    // call sleep in spawned thread
    //
    globalLogLevel = LogLevel.info;
    auto mode = globalLoopMode;
    foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
        globalLoopMode = m;
        int f() {
            hlSleep(200.msecs);
            return 2;
        }
        auto v = App(&f);
        assert(v == 2, "expected v==2, but received v=%d".format(v));
        infof("test2 ok in %s mode", m);
    }
    globalLoopMode = mode;
}

version(unittest) {
    class TestException : Exception {
        this(string msg, string file = __FILE__, size_t line = __LINE__) {
            super(msg, file, line);
        }
    }
}

unittest {
    //
    // test exception delivery when called from thread
    //
    globalLogLevel = LogLevel.info;
    auto mode = globalLoopMode;
    foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
        globalLoopMode = m;
        int f() {
            hlSleep(200.msecs);
            throw new TestException("test exception");
        }
        assertThrown!TestException(App(&f));
        infof("test3a ok in %s mode", m);
    }
    globalLoopMode = mode;
}

unittest {
    //
    // test exception delivery when called from task
    //
    globalLogLevel = LogLevel.info;
    auto mode = globalLoopMode;
    scope(exit) {
        globalLoopMode = mode;
    }
    foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
        globalLoopMode = m;
        int f() {
            auto t = task((){
                hlSleep(200.msecs);
                throw new TestException("test exception");
            });
            t.start();
            t.wait(300.msecs);
            return 0;
        }
        assertThrown!TestException(App(&f));
        infof("test3b ok in %s mode", m);
    }
}

unittest {
    //
    // test wait with timeout
    //
    globalLogLevel = LogLevel.info;
    auto mode = globalLoopMode;
    scope(exit) {
        globalLoopMode = mode;
    }
    foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
        globalLoopMode = m;
        int f0() {
            hlSleep(100.msecs);
            return 4;
        }
        int f() {
            auto t = task(&f0);
            t.call();
            t.wait();
            return t.result;
        }
        auto r = App(&f);
        assert(r == 4, "App returned %d, expected 4".format(r));
        infof("test4 ok in %s mode", m);
    }
}

unittest {
    //
    // test calling void function
    //
    globalLogLevel = LogLevel.info;
    auto mode = globalLoopMode;
    scope(exit) {
        globalLoopMode = mode;
    }
    foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
        globalLoopMode = m;
        void f() {
            hlSleep(200.msecs);
        }
        App(&f);
        infof("test6 ok in %s mode", m);
    }
}


unittest {
    globalLogLevel = LogLevel.info;
    auto mode = globalLoopMode;
    scope(exit) {
        globalLoopMode = mode;
    }
    foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
        globalLoopMode = m;
        int f0() {
            hlSleep(100.msecs);
            tracef("sleep done");
            return 6;
        }
        int f() {
            auto v = App(&f0);
            tracef("got value %s", v);
            return v+1;
        }
        auto r = App(&f);
        assert(r == 7, "App returned %d, expected 7".format(r));
        infof("test7 ok in %s mode", m);
    }
}

////////

// unittest {
//     info("=== test wait task ===");
//     //auto oScheduler = scheduler;
//     //scheduler = new MyScheduler();

//     globalLogLevel = LogLevel.info;

//     auto mode = globalLoopMode;
//     scope(exit) {
//         globalLoopMode = mode;
//     }
//     foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
//         globalLoopMode = m;
//         int f1(Duration d) {
//             hlSleep(d);
//             return 40;
//         }
    
//         int f2(Duration d) {
//             auto t = task(&f1, d);
//             t.call();
//             t.wait();
//             return t.result;
//         }
    
//         auto t = task(&f2, 500.msecs);
    
//         auto tid = spawnTask(t, 1.seconds);
    
//         receive(
//             (const int i)
//             {
//                 assert(i == 40, "expected 40, got %s".format(i));
//             },
//             (Variant v)
//             {
//                 errorf("test wait task got variant %s of type %s", v, v.type);
//                 assert(0);
//             }
//         );
//         infof("ok in %s mode", m);
//     }
//     //
//     //scheduler = oScheduler;
// }

// unittest {
//     info("=== test wait task with timeout ===");
//     //
//     // we call f2 which start f1(sleeping for 500 msecs) and wait it for 100 msecs
//     // so 
//     globalLogLevel = LogLevel.trace;
//     auto mode = globalLoopMode;
//     scope(exit) {
//         globalLoopMode = mode;
//     }
//     foreach(m; [Mode.FALLBACK, Mode.NATIVE]) {
//         globalLoopMode = m;
    
//         int f1(Duration d) {
//             hlSleep(d);
//             return 41;
//         }
    
//         bool f2(Duration d) {
//             auto t = task(&f1, d);
//             t.call();
//             bool ready = t.wait(100.msecs);
//             assert(!t.ready);
//             return ready;
//         }
    
//         auto t = task(&f2, 500.msecs);
//         spawnTask(t, 1.seconds);
//         receive(
//             (Exception e) {tracef("got exception"); assert(0);},
//             (const bool b) {assert(!b, "got value %s instedad of false".format(b));},
//             (Variant v) {tracef("got variant %s", v); assert(0);}
//         );
//         infof("ok in %s mode", m);
//     }
// }

// class SharedNotificationChannel : FileEventHandler {
//     import containers.slist, containers.hashmap;
//     import std.experimental.logger;

//     private {
//         struct SubscriptionInfo {
//             hlEvLoop                  _loop;
//             immutable int             _loop_id; // event loop id where subscriber reside
//             immutable HandlerDelegate _h;
//         }
//         package shared int  snc_id;
//         immutable int       _id;
//         shared Mutex        _subscribers_lock;

//         SList!SubscriptionInfo            _subscribers;
//     }

//     this() @safe {
//         import core.atomic;
//         _subscribers_lock = new shared Mutex;
//         _id = atomicOp!"+="(snc_id, 1);
//     }
//     void broadcast() @safe @nogc {
//         _subscribers_lock.lock_nothrow();
//         scope(exit) {
//             _subscribers_lock.unlock_nothrow();
//         }

//         foreach(destination; _subscribers) {
//             version(OSX) {
//                 import core.sys.darwin.sys.event;

//                 kevent_t    user_event;
//                 immutable remote_kqueue_fd = destination._loop_id;
//                 with (user_event) {
//                     ident = _id;
//                     filter = EVFILT_USER;
//                     flags = 0;
//                     fflags = NOTE_TRIGGER;
//                     data = 0;
//                     udata = null;
//                 }
//                 auto rc = (() @trusted => kevent(remote_kqueue_fd, cast(kevent_t*)&user_event, 1, null, 0, null))();
//             }
//             version(linux) {
//                 import core.sys.posix.unistd: write;
//                 import core.stdc.string: strerror;
//                 import core.stdc.errno: errno;
//                 import std.string;
    
//                 auto rc = (() @trusted => write(destination._loop_id, &_id, 8))();
//                 if ( rc == -1 ) {
//                     //errorf("event_fd write to %d returned error %s", destination, fromStringz(strerror(errno)));
//                 }
//             }
//         }
//     }

//     override void eventHandler(int _loop_id, AppEvent e) {
//         tracef("process user event handler on fd %d", _loop_id);
//         version(linux) {
//             import core.sys.posix.unistd: read;
//             ulong v;
//             auto rc = (() @trusted => read(_loop_id, &v, 8))();
//         }
//         _subscribers_lock.lock_nothrow();
//         scope(exit) {
//             _subscribers_lock.unlock_nothrow();
//         }
//         foreach(s; _subscribers) {
//             if ( _loop_id != s._loop_id ) {
//                 continue;
//             }
//             auto h = s._h;
//             h(e);
//         }
//     }

//     void signal() @trusted {
//         _subscribers_lock.lock_nothrow();
//         scope(exit) {
//             _subscribers_lock.unlock_nothrow();
//         }
//         if ( _subscribers.empty ) {
//             trace("send signal - no subscribers");
//             return;
//         }
//         auto destination = _subscribers.front();

//         version(OSX) {
//             import core.sys.darwin.sys.event;
//             kevent_t user_event;
//             immutable remote_kqueue_fd = destination._loop_id;
//             with (user_event) {
//                 ident = _id;
//                 filter = EVFILT_USER;
//                 flags = 0;
//                 fflags = NOTE_TRIGGER;
//                 data = 0;
//                 udata = null;
//             }
//             int rc = (() @trusted => kevent(remote_kqueue_fd, cast(kevent_t*)&user_event, 1, null, 0, null))();
//             tracef("signal trigger rc to remote_kqueue_fd %d: %d", remote_kqueue_fd, rc);
//             enforce(rc>=0, "Failed to trigger event");
//         }
//         version(linux) {
//             import core.sys.posix.unistd: write;
//             import core.stdc.string: strerror;
//             import core.stdc.errno: errno;
//             import std.string;

//             auto rc = (() @trusted => write(destination._loop_id, &_id, 8))();
//             debug tracef("event_fd %d write = %d", destination._loop_id, rc);
//             if ( rc == -1 ) {
//                 errorf("event_fd write to %d returned error %s", destination, fromStringz(strerror(errno)));
//             }
//         }
//     }
//     auto subscribe(hlEvLoop loop, HandlerDelegate handler) @safe {
//         version(OSX) {
//             immutable event_fd = getDefaultLoop().getKernelId();
//             //import core.sys.posix.fcntl: open;
//             //immutable event_fd = (() @trusted => open("/dev/null", 0))();
//             SubscriptionInfo s = SubscriptionInfo(loop, event_fd, handler);
//             loop.waitForUserEvent(_id, this);
//         }
//         version(linux) {
//             import core.sys.linux.sys.eventfd;
//             immutable event_fd = (() @trusted => eventfd(0,EFD_NONBLOCK))();
//             SubscriptionInfo s = SubscriptionInfo(loop, event_fd, handler);
//             loop.waitForUserEvent(event_fd, this);
//         }
//         synchronized(_subscribers_lock) {
//             _subscribers.put(s);
//         }
//         tracef("subscribers length = %d", _subscribers.length());
//         return s;
//     }

//     void unsubscribe(in SubscriptionInfo s) {
//         s._loop.stopWaitForUserEvent(_id, this);
//         synchronized(_subscribers_lock) {
//             _subscribers.remove(s);
//             version(linux) {
//                 import core.sys.posix.unistd: close;
//                 close(s._loop_id);
//             }
//         }
//     }

//     auto register(hlEvLoop loop, HandlerDelegate handler) {
//         return subscribe(loop, handler);
//     }

//     void deregister(SubscriptionInfo s) {
//         unsubscribe(s);
//     }

//     void close() @safe @nogc {
//     }
// }

// unittest {
//     //
//     // we call f2 which start f1(sleeping for 500 msecs) and wait it for 100 msecs
//     // so 
//     globalLogLevel = LogLevel.info;
//     auto mode = globalLoopMode;
//     scope(exit) {
//         globalLoopMode = mode;
//     }
//     foreach(m; [Mode.NATIVE]) {
//         globalLoopMode = m;
//         infof("=== test shared notification channel signal in %s mode ===", m);
//         auto snc = new SharedNotificationChannel();
//         scope(exit) {
//             snc.close();
//         }
//         int  test_value;
//         void signal_poster() {
//             hlSleep(100.msecs);
//             tracef("send signal");
//             snc.signal();
//         }
//         int signal_receiver() {
//             int test = 0;
//             HandlerDelegate h = (AppEvent e) {
//                 tracef("shared notificatioin delivered");
//                 test = 1;
//             };
//             hlEvLoop loop = getDefaultLoop();
//             auto s = snc.register(loop, h);
//             hlSleep(200.msecs);
//             snc.deregister(s);
//             return test;
//         }
//         auto tp = task({
//             callInThread(&signal_poster);
//         });
//         auto tr = task({
//             test_value = callInThread(&signal_receiver);
//             getDefaultLoop().stop();
//         });
//         tp.call();
//         tr.call();
//         getDefaultLoop().run(3000.msecs);
//         assert(test_value == 1, "expected 1, got %s".format(test_value));
//     }
// }

// unittest {
//     info("=== test shared notification channel broacast ===");
//     //
//     // we call f2 which start f1(sleeping for 500 msecs) and wait it for 100 msecs
//     // so 
//     globalLogLevel = LogLevel.info;
//     auto snc = new SharedNotificationChannel();
//     scope(exit) {
//         snc.close();
//     }
//     int   test_value;
//     shared Mutex lock = new shared Mutex;

//     void signal_poster() {
//         hlSleep(100.msecs);
//         snc.broadcast();
//         tracef("shared notificatioin broadcasted");
//     }
//     void signal_receiver1() {
//         HandlerDelegate h = (AppEvent e) {
//             synchronized(lock) {
//                 test_value++;
//             }
//             tracef("shared notificatioin delivered 1 - %d", test_value);
//         };
//         //class nHandler : FileEventHandler {
//         //    override void eventHandler(int fd, AppEvent e) {
//         //    tracef("shared notificatioin delivered 1");
//         //        synchronized(lock) {
//         //            test_value++;
//         //        }
//         //    }
//         //}
//         //auto h = new nHandler();
//         hlEvLoop loop = getDefaultLoop();
//         auto s = snc.register(loop, h);
//         hlSleep(200.msecs);
//         snc.deregister(s);
//     }
//     void signal_receiver2() {
//         HandlerDelegate h = (AppEvent e) {
//             synchronized(lock) {
//                 test_value++;
//             }
//             tracef("shared notificatioin delivered 2 - %d", test_value);
//         };
//         //class nHandler : FileEventHandler {
//         //    override void eventHandler(int fd, AppEvent e) {
//         //        tracef("shared notificatioin delivered 2");
//         //        synchronized(lock) {
//         //            test_value++;
//         //        }
//         //    }
//         //}
//         //auto h = new nHandler();
//         hlEvLoop loop = getDefaultLoop();
//         auto s = snc.register(loop, h);
//         hlSleep(200.msecs);
//         snc.deregister(s);
//     }
//     auto tp = task({
//         callInThread(&signal_poster);
//     });
//     auto tr1 = task({
//         callInThread(&signal_receiver1);
//     });
//     auto tr2 = task({
//         callInThread(&signal_receiver2);
//     });
//     tp.call();
//     tr1.call();
//     tr2.call();
//     getDefaultLoop().run(500.msecs);
//     assert(test_value == 2);
// }

//
// split array on N balanced chunks
// (not on chunks with N members)
//
private auto splitn(T)(T a, size_t slices) {
    T[] r;
    if (a.length == 0) {
        return r;
    }
    if (a.length % slices == 0) {
        return chunks(a, a.length / slices).array;
    }
    int n;
    while (n < a.length) {
        auto rest = a.length - n;
        auto done = slices - r.length;
        auto size = rest % done ? (rest / done + 1) : rest / done;
        r ~= a[n .. n + size];
        n += size;
    }
    return r;
}
unittest {
    for(int n=1; n<100; n++) {
        for (int slices = 1; slices < n; slices++) {
            auto r = splitn(iota(n).array, slices);
            assert(r.length == slices);
            assert(equal(iota(n), r.join));
        }
    }
}

// Map array on M threads and N fibers
// Non lazy. Return void if f is void.
//            :
//           /|\
//          / | \
//       ->/  |  \<- M threads
//        /   |   \
//       N    N    N
//      /|\  /|\  /|\
//      |||  |||  |||
//      |||  |||->|||<- N fibers
//      fff  fff  fff
//      ...  ...  ...
//      ...  ...  ... <- r splitted over MxN fibers
//      ...  ...  .. 
//
auto mapMxN(F, R)(R r, F f, ulong m, ulong n) {
    enum Void = is(ReturnType!F == void);

    assert(m > 0 && n > 0 && r.length > 0, "should be m > 0 && n > 0 && r.length > 0, you have %d,%d,%d".format(m,n,r.length));

    m = min(m, r.length);

    auto fiberWorker(R fiber_chunk) {
        static if (!Void) {
            return fiber_chunk.map!(f).array;
        } else {
            fiber_chunk.each!f;
        }
    }

    auto threadWorker(R thread_chunk) {
        auto fibers = thread_chunk.splitn(n). // split on N chunks
            map!(fiber_chunk => task(&fiberWorker, fiber_chunk)). // start fiber over each chunk
            array;
        fibers.each!"a.start";
        fibers.each!"a.wait";
        static if (!Void) {
            return fibers.map!"a.value".array.join;
        }
    }
    auto threads = r.splitn(m). // split on M chunks
        map!(thread_chunk => threaded(&threadWorker, thread_chunk)). // start thread over each chunk
        array;
    threads.each!"a.start";
    threads.each!"a.wait";
    static if (!Void) {
        return threads.map!"a.value".array.join;
    }
}

// map array on M threads
// Non lazy. Return void if f is void.
//            :
//           /|\
//          / | \
//       ->/  |  \<- M threads
//        /   |   \
//       f    f    f
//       .    .    . 
//       .    .    .  <- r splitted over M threads
//       .    .      
//
auto mapM(R, F)(R r, F f, ulong m) if (isArray!R) {
    enum Void = is(ReturnType!F == void);

    assert(m > 0 && r.length > 0);

    m = min(m, r.length);

    static if (Void) {
        void threadWorker(R chunk) {
            chunk.each!f;
        }
    } else {
        auto threadWorker(R chunk) {
            return chunk.map!f.array;
        }
    }

    auto threads = r.splitn(m).map!(thread_chunk => threaded(&threadWorker, thread_chunk).start).array;

    threads.each!"a.wait";

    static if (!Void) {
        return threads.map!"a.value".array.join;
    }
}

unittest {
    import std.range;
    import std.stdio;
    import core.atomic;

    shared int cnt;

    void f0(int arg) {
        atomicOp!"+="(cnt,arg);
    }

    int f1(int i) {
        return i * i;
    }

    int[] f2(int i) {
        return [i,i+1];
    }

    App({
        // woid function, updates shared counter
        iota(20).array.mapMxN(&f0, 2, 3);
        assert(cnt == 190);
    });

    cnt = 0;
    App({
        // woid function, updates shared counter
        iota(20).array.mapM(&f0, 5);
        assert(cnt == 190);
    });

    App({
        auto r = iota(20).array.mapMxN(&f1, 2, 3);
        assert(equal(r, iota(20).map!"a*a"));
    });

    App({
        auto r = iota(20).array.mapM(&f1, 5);
        assert(equal(r, iota(20).map!"a*a"));
    });

    App({
        auto r = iota(20).array.mapM(&f2, 5);
        assert(equal(r, iota(20).map!"[a, a+1]"));
    });
}