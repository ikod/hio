#!/usr/bin/env dub
/+ dub.sdl:
    name "t0"
    dflags "-I../source"
    dflags "-debug"
    lflags "-L.."
    lflags "-lhio"
    lflags "-lcares"
    dependency "nbuff" version="*"
+/
// cd to tests and run with "dub run --single t1.d"

import std.algorithm;
import std.array;
import std.range;
import std.stdio;
import std.experimental.logger;

import hio.scheduler;
import hio.socket;
import hio.events;
import hio.loop;
import hio.resolver;

void main()
{
    globalLogLevel = LogLevel.info;
    auto r = hio_gethostbyname("dlang.org");
    writefln("resolve dlang.org in main thread: %s", r.addresses);
    auto result = App({
        auto hosts = [
            "dlang.org",
            "google.com",
            "yahoo.com",
            "altavista.com",
            "github.com",
            "ok.some.domains.are.fake",
            ".... - some incorrecr",
        ];
        auto resolve(string host)
        {
            iota(10).each!(n=>hio_gethostbyname(host));
            return hio_gethostbyname(host);
        }
        auto tasks = hosts.map!(h => task(&resolve, h)).array;
        tasks.each!(t => t.start);
        tasks.each!(t => t.wait);
        return zip(hosts, tasks.map!(t=>t.result).array);
    });
    result.each!(r => writefln("domain: '%s', status: %s, addresses: %s", r[0], ares_statusString(r[1].status), r[1].addresses));
}