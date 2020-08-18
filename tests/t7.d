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
import std.format;

import hio.scheduler;
import hio.tls;
import hio.events;
import hio.loop;

import nbuff: Nbuff;

static string[] hosts = [
    "www.reuters.com",
    "www.bloomberg.org",
    "www.wsj.com",
    "stumbleupon.com",
    "www-media.stanford.edu",
    "www.deviantart.com",
    "www.wiley.com",
    "themeforest.net",
    "mashable.com",
    "www.trustpilot.com",
    "www.a8.net",
    "www.uol.com.br",
    "www.domraider.com",
    "us.sagepub.com",
    "hbr.org",
    "static-service.prweb.com",
    "www.usgs.gov",
    "www.archives.gov",
    "www.usc.edu",
    "www.usa.gov",
    "www.istockphoto.com",
    "www.snapchat.com",
    "www2.gotomeeting.com",
    "bitbucket-marketing-cdn.atlassian.com",
    "cdn-1.wp.nginx.com",
    "www.worldbank.org",
    "www.mlbstatic.com"
];

// enum host = "www.humblebundle.com";
enum port = 443;
// enum host = "127.0.0.1";
// enum port = 4433;

void scrape(string host)
{
    globalLogLevel = LogLevel.info;
    IORequest iorq;
    AsyncSSLSocket s;
    ulong bytes;
    hlEvLoop loop = getDefaultLoop();

    void io_callback(ref IOResult r) @safe
    {
        bytes += r.input.length;
        if (r.timedout || r.error)
        {
            infof("done, %d bytes", bytes);
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
        infof("=== CONNECTED to %s ===", host);
        iorq.callback = &io_callback;
        iorq.to_read = 1024;
        iorq.output = Nbuff("GET / HTTP/1.1\nConnection: close\n");
        iorq.output.append("Host: %s\n".format(host));
        iorq.output.append("\n");
        s.io(loop, iorq, 5.seconds);
    }
    InternetAddress addr;
    try
    {
        addr = new InternetAddress(host, port);
    }
    catch(std.socket.AddressException e)
    {
        infof("socket exception %s", e);
        return;
    }
    s = new AsyncSSLSocket();
    s.open();
    s.set_host(host);
    s.connect(addr, loop, &connected, 1.seconds);
    loop.run(10.seconds);
    s.close();
}
void main()
{
    foreach (host; hosts)
    {
        scrape(host);
    }
}
