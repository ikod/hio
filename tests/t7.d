/+ dub.sdl:
    name "t7"
    dflags "-I../source"
    #dflags "-debug"
    lflags "-lcares"
    buildRequirements "allowWarnings"
    dependency "hio" version="*"
    dependency "nbuff" version="*"
    debugVersions "hiossl"
+/

module tests.t7;

import std.experimental.logger;
import std.datetime;
import std.socket;

import hio.scheduler;
import hio.tls;
import hio.events;
import hio.loop;

import nbuff: Nbuff;

enum host = "www.google.com";
enum port = 443;
// enum host = "127.0.0.1";
// enum port = 4433;

void main()
{
    globalLogLevel = LogLevel.trace;
    IORequest iorq;
    AsyncSSLSocket s;
    hlEvLoop loop = getDefaultLoop();

    void io_callback(IOResult r) @safe
    {
        if (r.timedout || r.error)
        {
            info("done");
            loop.stop();
            s.close();
            return;
        }
        iorq.to_read = 16*1024;
        iorq.output = Nbuff();
        s.io(loop, iorq, 5.seconds);
    }
    void connected(AppEvent ev) @safe
    {
        infof("connected result: %s", ev);
        if ( ev != AppEvent.OUT)
        {
            info("=== Failed to connect ===");
            loop.stop();
            s.close();
            return;
        }
        info("=== CONNECTED ===");
        iorq.callback = &io_callback;
        iorq.to_read = 1024;
        iorq.output = Nbuff("GET / HTTP/1.1\n");
        iorq.output.append("Host: www.google.com\n");
        iorq.output.append("\n");
        s.io(loop, iorq, 5.seconds);
    }

    s = new AsyncSSLSocket();
    s.open();
    s.connect(new InternetAddress(host, port), loop, &connected, 1.seconds);
    loop.run(500.seconds);
}