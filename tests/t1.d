#!/usr/bin/env dub
/+ dub.sdl:
    name "t1"
    dflags "-I../source"
    dflags "-debug"
    lflags "-lcares"
    dependency "hio" version="~>0"
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
    auto r = hio_gethostbyname("dlang.org", 80);
    writefln("resolve dlang.org in main thread: %s", r.addresses);
    auto result = App({
        auto hosts = [
            "dlang.org",
            "google.com",
            "yahoo.com",
            "altavista.com",
            "github.com",
            "ok.some.domains.are.fake",
            ".... - some incorrect name",
        ];
        auto resolve(string host)
        {
            iota(10).each!(n=>hio_gethostbyname(host));
            return hio_gethostbyname(host, 80);
        }
        auto tasks = hosts.map!(h => task(&resolve, h)).array;
        tasks.each!(t => t.start);
        tasks.each!(t => t.wait);
        return zip(hosts, tasks.map!(t=>t.result).array);
    });
    result.each!(r => writefln("domain: '%s', status: %s, addresses: %s", r[0], ares_statusString(r[1].status), r[1].addresses));
}
