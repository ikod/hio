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

private enum PAGESIZE = 4*1024;
/// stack size for new tasks
shared int TASK_STACK_SIZE = 16 * PAGESIZE;

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
    bool shutdown;
    auto callback = delegate void (AppEvent e) @trusted
    {
        debug tracef("got event %s while sleeping", e);
        if ( e & AppEvent.SHUTDOWN)
        {
            shutdown = true;
        }
        tid.call(Fiber.Rethrow.no);
    };
    auto t = new Timer(d, callback);
    getDefaultLoop().startTimer(t);
    Fiber.yield();
    if (shutdown)
    {
        throw new LoopShutdownException("got loop shutdown");
    }
}

struct Box(T) {

    enum Void = is(T == void);

    static if (!Void) {
        T   _data;
    }
    SocketPair  _pair;
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
            version(unittest)
            {
                debug tracef("app throwed %s", e);
            }
            else
            {
                errorf("app throwed %s", e);
            }
            box._exception = e;
        }
        getDefaultLoop().stop();
    }

    // shared void delegate() run = () {
    //     //
    //     // in the child thread:
    //     // 1. start new fiber (task over wrapper) with user supplied function
    //     // 2. start event loop forewer
    //     // 3. when eventLoop done(stopped inside from wrapper) the task will finish
    //     // 4. store value in box and use socketpair to send signal to caller thread
    //     //
    //     auto t = task(&_wrapper);
    //     auto e = t.start(Fiber.Rethrow.no);
    //     if ( box._exception is null ) { // box.exception can be filled before Fiber start
    //         box._exception = e;
    //     }
    //     getDefaultLoop.run(Duration.max);
    //     //t.reset();
    // };
    // Thread child = new Thread(run);
    // child.start();
    // child.join();
    //run();
    auto t = task(&_wrapper);
    auto e = t.start(Fiber.Rethrow.no);
    if ( !box._exception )
    {
        // box.exception can be filled before Fiber start
        box._exception = e;
    }
    if ( !box._exception)
    {
        // if we started ok - run loop
        getDefaultLoop.run(Duration.max);
    }
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

interface Computation {
    bool ready();
    bool wait(Duration t = Duration.max);
}

enum Commands
{
    StopLoop,
    WakeUpLoop,
    ShutdownLoop,
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
        bool        _child_joined; // did we called _child.join?
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
    }

    override bool ready() {
        return _ready;
    }
    auto isDaemon(bool v)
    in(_child is null) // you can't change this after thread started
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
    void shutdownThreadLoop()
    {
        debug tracef("shutdown loop in thread");
        ubyte[1] cmd = [Commands.ShutdownLoop];
        _commands.write(1, cmd);
    }
    override bool wait(Duration timeout = Duration.max)
    in(!_isDaemon)      // this not works with daemons
    in(_child !is null) // you can wait only for started tasks
    {
        if (_ready) {
            if ( !_child_joined ) {
                _child.join();
                _child_joined = true;
                _commands.close();
                _box._pair.close();
            }
            if ( _box._exception ) {
                throw _box._exception;
            }
            return true;
        }
        if ( timeout <= 0.seconds )
        {
            // this is poll
            return _ready;
        }
        if ( timeout < Duration.max )
        {
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
            override string describe() @safe
            {
                return
                    "thread event handler: f(args): %s(%s)".format(_f, _args);
            }
            override void eventHandler(int fd, AppEvent e) @trusted
            {
                _box._pair.read(0, 1);
                getDefaultLoop().stopPoll(_box._pair[0], AppEvent.IN);
                getDefaultLoop().detach(_box._pair[0]);
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
        if ( _ready && !_child_joined ) {
            _child.join();
            _child_joined = true;
            _commands.close();
            _box._pair.close();
        }
        return _ready;
    }

    final auto run()
    in(_child is null)
    {
        class CommandsHandler : FileEventHandler
        {
            override void eventHandler(int fd, AppEvent e)
            {
                assert(fd == _commands[0]);
                if ( e & AppEvent.SHUTDOWN)
                {
                    // just ignore
                    return;
                }
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
                    case Commands.ShutdownLoop:
                        debug tracef("got Shutdown command");
                        getDefaultLoop.shutdown();
                        break;
                }
            }
        }
        this._child = new Thread(
            {
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
                // clean up everything and release memory
                uninitializeLoops(); // close fds, free memory
            }
        );
        this._child.isDaemon = _isDaemon;
        if ( !_isDaemon )
        {
            _box._pair = makeSocketPair();
            _commands = makeSocketPair();
        }
        this._child.start();
        return this;
    }
}

///
/// Task. Exacute computation. Inherits from Fiber
/// you can start, wait, check for readiness.
///
class Task(F, A...) : Computation if (isCallable!F) {
    private enum  Void = is(ReturnType!F==void);
    alias start = call;
    debug private
    {
        static ulong task_id;
        ulong        _task_id;
    }
    private {
        alias R = ReturnType!F;

        F            _f;
        A            _args;
        bool         _ready;
        bool         _daemon;
        // Notification _done;
        Fiber        _waitor;
        Throwable    _exception;

        Fiber        _executor;
        static if ( !Void ) {
            R       _result;
        }
    }

    final this(F f, A args) @safe
    {
        _f = f;
        _args = args;
        _waitor = null;
        _exception = null;
        static if (!Void) {
            _result = R.init;
        }
        if (fiberPoolSize>0)
        {
            _executor = fiberPool[--fiberPoolSize];
            () @trusted {
                _executor.reset(&run);
            }();
        }
        else
        {
            () @trusted {
                _executor = new Fiber(&run, TASK_STACK_SIZE);
            }();
        }
        debug
        {
            _task_id = task_id++;
            debug tracef("t:%0X task %s created", Thread.getThis.id, _task_id);
        }
        //super(&run);
    }
    Throwable call(Fiber.Rethrow r = Fiber.Rethrow.yes)
    {
        return _executor.call(r);
    }
    void daemon(bool v)
    {
        _daemon = v;
    }
    void start() @trusted
    {
        _executor.call();
    }
    void reset()
    {
        _executor.reset();
    }
    auto state()
    {
        return _executor.state;
    }
    static int fiberPoolSize;
    enum   FiberPoolCapacity = 1024;
    static Fiber[FiberPoolCapacity] fiberPool;
    ///
    /// wait() - wait forewer
    /// wait(Duration) - wait with timeout
    /// 
    override bool wait(Duration timeout = Duration.max) {
        debug trace("enter wait");
        assert(!_daemon);
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
        Timer t;
        if ( timeout < Duration.max) 
        {

           t = new Timer(timeout, (AppEvent e) @trusted {
                debug tracef("Event %s on 'wait' timer", e);
                if (_waitor)
                {
                    auto w = _waitor;
                    _waitor = null;
                    w.call(Fiber.Rethrow.no);
                }
            });
            try
            {
                getDefaultLoop().startTimer(t);
            }
            catch(LoopShutdownException e)
            {
                // this can happens if we are in shutdown process
                t = null;
            }
        }
        debug tracef("yeilding task");
        Fiber.yield();
        debug tracef("wait continue, task state %s", _executor.state);
        if ( t )
        {
            getDefaultLoop().stopTimer(t);
        }
        if (fiberPoolSize < FiberPoolCapacity )
        {
            fiberPool[fiberPoolSize++] = _executor;
        }
        if ( _exception !is null )
        {
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
                version(unittest)
                {
                    debug tracef("got throwable %s", e);
                }
                else
                {
                    errorf("got throwable %s", e);
                }
            }
            //debug tracef("run void finished, waitors: %s", this._waitor);
        }
        else 
        {
            try {
                _result = _f(_args);
            } catch(Throwable e) {
                _exception = e;
                version(unittest)
                {
                    debug tracef("got throwable %s", e);
                }
                else
                {
                    errorf("got throwable %s", e);
                }
            }
            //debug tracef("run finished, result: %s, waitor: %s", _result, this._waitor);
        }
        this._ready = true;
        if ( !_daemon && this._waitor ) {
            auto w = this._waitor;
            this._waitor = null;
            debug tracef("t:%0X task %s finished, wakeup waitor", Thread.getThis.id, _task_id);
            w.call();
        }
        else
        {
            debug tracef("t:%0X task %s finsihed, no one to wake up(isdaemon=%s)", Thread.getThis.id, _task_id, _daemon);
        }
        if ( _daemon )
        {
            Fiber.getThis.reset();
            return;
        }
        if (fiberPoolSize < FiberPoolCapacity )
        {
            fiberPool[fiberPoolSize++] = _executor;
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
    t.start();
    t.wait();
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
        //t.wait();
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
    struct V
    {
        Throwable exception;
        static if (!Void)
        {
            ReturnType!F    _value;
            auto value() inout
            {
                check();
                return _value;
            }
            alias value this;
        }
        void check() inout
        {
            if (exception)
            {
                throw exception;
            }
        }
    }
    assert(m > 0 && n > 0 && r.length > 0, "should be m > 0 && n > 0 && r.length > 0, you have %d,%d,%d".format(m,n,r.length));

    m = min(m, r.length);

    auto fiberWorker(R fiber_chunk) {
        V[] result;
        foreach(ref c; fiber_chunk)
        {
            try
            {
                static if (!Void)
                {
                    result ~= V(null, f(c));
                }
                else
                {
                    f(c);
                    result ~= V();
                }
            }
            catch(Throwable e)
            {
                result ~= V(e);
            }
        }
        return result;
    }

    auto threadWorker(R thread_chunk) {
        auto fibers = thread_chunk.splitn(n). // split on N chunks
            map!(fiber_chunk => task(&fiberWorker, fiber_chunk)). // start fiber over each chunk
            array;
        fibers.each!"a.start";
        debug tracef("%d tasks started", fibers.length);
        auto ready = fibers.map!"a.wait".array;
        assert(ready.all);
        return fibers.map!"a.value".join;
    }
    auto threads = r.splitn(m). // split on M chunks
        map!(thread_chunk => threaded(&threadWorker, thread_chunk)). // start thread over each chunk
        array;
    threads.each!"a.start";
    debug tracef("threads started");
    threads.each!"a.wait";
    debug tracef("threads finished");
    return threads.map!"a.value".array.join;
    // auto ready = threads.map!"a.wait".array;
    // assert(ready.all);
    // return threads.map!"a.value".join;
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
        auto r = iota(20).array.mapM(&f1, 5);
        assert(equal(r, iota(20).map!"a*a"));
    });

    App({
        auto r = iota(20).array.mapM(&f2, 5);
        assert(equal(r, iota(20).map!"[a, a+1]"));
    });

    App({
        // woid function, updates shared counter
        iota(20).array.mapM(&f0, 5);
        assert(cnt == 190);
    });

    cnt = 0;
    App({
        // woid function, updates shared counter
        iota(20).array.mapMxN(&f0, 2, 3);
        assert(cnt == 190);
    });

    App({
        auto r = iota(20).array.mapMxN(&f1, 1, 1);
        assert(equal(r.map!"a.value", iota(20).map!"a*a"));
    });
}
unittest
{
    globalLogLevel = LogLevel.info;
    // test shutdown
    App({
        void a()
        {
            hlSleep(100.msecs);
            getDefaultLoop.shutdown();
        }
        void b()
        {
            try
            {
                hlSleep(1.seconds);
                assert(0, "have to be interrupted");
            }
            catch (LoopShutdownException e)
            {
                debug tracef("got what expected");
            }
        }
        auto ta = task(&a);
        auto tb = task(&b);
        ta.start();
        tb.start();
        ta.wait();
        tb.wait();
    });
    uninitializeLoops();
    globalLogLevel = LogLevel.info;
}