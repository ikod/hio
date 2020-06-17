/+ dub.sdl:
    name "t8"
    dflags "-I../source"
    #dflags "-debug"
    lflags "-lcares"
    buildRequirements "allowWarnings"
    dependency "hio" version="*"
    dependency "nbuff" version="*"
    debugVersions "hiossl"
+/

// test ssl connection

module tests.t8;

import std.experimental.logger;
import std.datetime;
import std.socket;

import hio.scheduler;
import hio.tls;
import hio.events;
import hio.loop;
import hio.socket;

import nbuff: Nbuff;

void main()
{
    globalLogLevel = LogLevel.trace;
    auto loop = getDefaultLoop();
    auto s = new AsyncSSLSocket();
    s.open();
    void server_callback(AsyncSocketLike c) @safe
    {
        IORequest iorq;
        AsyncSSLSocket client = cast(AsyncSSLSocket)c;
        bool done = false;
        void io_callback(IOResult r)
        {
            infof("got result: %s", r);
            if (r.error || r.timedout || done)
            {
                client.close();
                return;
            }
            iorq.to_read = 0;
            iorq.output = Nbuff("ok\n");
            done = true;
            client.io(loop, iorq, 15.seconds);
        }
        if ( client is null )
        {
            // accept timed out, just restart acceppting
            s.accept(loop, 15.seconds, &server_callback);
            return;
        }
        if ( !client.connected )
        {
            // something wrong
            c.close();
            return;
        }
        info("client connected, reading request");
        iorq.to_read = 128;
        iorq.callback = &io_callback;
        client.io(loop, iorq, 15.seconds);
    }
    s.bind(new InternetAddress("127.0.0.1", 5555));
    s.listen(512);
    s.cert_file("./cert.pem");
    s.key_file("./key.pem");
    s.accept(loop, 15.seconds, &server_callback);
    loop.run(50.seconds);
}
