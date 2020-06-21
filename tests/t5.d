/+ dub.sdl:
    name "t5"
    dflags "-I../source"
    #dflags "-fsanitize=address"
    #dflags "-debug"
    #debugVersions "nbuff"
    #debugVersions "timingwheels"
    #debugVersions "cachetools"
    lflags "-lcares"
    buildRequirements "allowWarnings"
    dependency "hio" version="*"
    dependency "nbuff" version="*"
+/

module tests.t5;
import core.thread;
import std.datetime;
import std.algorithm;
import std.string: fromStringz;
import std.experimental.logger;
import std.stdio;
import std.array;
import std.socket;
import core.sys.posix.arpa.inet;
import hio.resolver;
import hio.scheduler;
import hio.events;
import hio.loop;

void main()
{
    globalLogLevel = LogLevel.info;
    info("blocked resolving in main thread");
    enum iterations = 10;
    // sync
    for(int i=0; i< iterations; i++)
    {
        auto r0 = hio_gethostbyname("localhost");
        auto r4 = hio_gethostbyname("google.com");
        auto r6 = hio_gethostbyname6("google.com");
        writeln("localhost0 ", r0);
        Thread.sleep(500.msecs);
    }

    info("concurrent resolving in tasks");
    App({
        void job1()
        {
            for(int i=0;i<iterations;i++)
            {
                auto r0 = hio_gethostbyname("localhost");
                auto r4 = hio_gethostbyname("dlang.org");
                auto r6 = hio_gethostbyname6("dlang.org");
                writeln("localhost1 ", r0);
                writeln("dlang.org", r4,r6);
                hlSleep(200.msecs);
            }
        }
        void job2()
        {
            for(int i=0;i<iterations;i++)
            {
                auto r4 = hio_gethostbyname("ietf.org");
                auto r6 = hio_gethostbyname6("ietf.org");
                hlSleep(200.msecs);
            }
        }
        auto t1 = task(&job1), t2 = task(&job2);
        t1.start();
        t2.start();
        t1.wait();
        t2.wait();
    });
    // async/callbacks
    info("async resolving in callbacks");
    auto loop = getDefaultLoop();
    int  counter = 100;
    Timer t;
    void resolve4(int status, InternetAddress[] addresses) @trusted
    {
        char[32] buf;
        writefln("[%s]", addresses);
        counter--;
        if ( counter == 0 )
        {
            loop.stop();
        }
    }
    void resolve6(int status, Internet6Address[] addresses) @trusted
    {
        char[64] buf;
        writefln("[%s]", addresses);
        counter--;
        if ( counter == 0 )
        {
            loop.stop();
        }
    }
    void timer(AppEvent e) @safe
    {
        hio_gethostbyname("cloudflare.com", &resolve4);
        hio_gethostbyname6("cloudflare.com", &resolve6);
        hio_gethostbyname("github.com", &resolve4);
        t.rearm(200.msecs);
        loop.startTimer(t);
    }
    t = new Timer(200.msecs, &timer);
    loop.startTimer(t);
    loop.run();
}
