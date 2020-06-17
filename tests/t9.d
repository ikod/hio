/+ dub.sdl:
    name "t9"
    dflags "-I../source"
    #dflags "-debug"
    lflags "-lcares"
    buildRequirements "allowWarnings"
    dependency "hio" version="*"
    dependency "nbuff" version="*"
    #debugVersions "hiohttp"
    #debugVersions "hioepoll"
+/

// test http client
import std.stdio;
import std.datetime;
import std.experimental.logger;

import hio.loop;
import hio.scheduler;
import hio.http.client;
import hio.http.common;

void main()
{
    AsyncHTTPClient client = new AsyncHTTPClient();
    void callback(AsyncHTTPResult r)
    {
        writefln("<%s>", r.response_headers);
        writeln(r.response_body.toString);
        getDefaultLoop().stop();
    }
    URL url = parse_url("https://httpbin.org/stream/512");
    client.verbosity = 1;
    client.execute(Method("GET"), url, &callback);
    getDefaultLoop().run();
    client.close();
}

