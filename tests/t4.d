/+ dub.sdl:
    name "t4"
    dflags "-I../source"
    #dflags "-fsanitize=address"
    #dflags "-debug"
    dmdflags "-check=assert=off"
    dmdflags "-check=in=off"
    dmdflags "-check=out=off"
    dmdflags "-check=invariant=off"
    dmdflags "-check=bounds=off"
    // dflags "-profile=gc"
    // #debugVersions "nbuff"
    #debugVersions "timingwheels"
    #debugVersions "cachetools"
    lflags "-lcares"
    buildRequirements "allowWarnings"
    dependency "hio" version="*"
    dependency "nbuff" version="*"
+/

module tests.t4;
import std.experimental.logger;
import std.datetime;
import std.string;
import std.algorithm;
import std.range;

import core.atomic;

import hio.socket;
import hio.scheduler;
import hio.loop;

import nbuff: Nbuff, NbuffChunk;


void server(int so)
{
    auto loop = getDefaultLoop();
    auto server_socket = new hlSocket(so);

    void acceptFunction(AsyncSocketLike s) @safe
    {
        if ( s is null )
        {
            // timeout
            server_socket.accept(loop, 5.seconds, &acceptFunction);
            return;
        }
        int requests;
        IORequest iorq;
        void delegate(ref IOResult) @safe ioWriteCompleted;
        void delegate(ref IOResult) @safe ioReadCompleted;

        auto client_socket = cast(hlSocket)s;
        ioWriteCompleted = delegate void(scope ref IOResult iores) @safe
        {
            if (iores.error)
            {
                //throw new Exception("err");
                client_socket.close();
                return;
            }
            if (requests < 1000)
            {
                requests++;
                iorq.to_read = 1024;
                iorq.callback = ioReadCompleted;
                client_socket.io(loop, iorq, 10.seconds);
            }
            else
            {
                client_socket.close();
            }
        };

        ioReadCompleted = delegate void(scope ref IOResult iores) @safe
        {
            if ( !iores.timedout && !iores.error )
            {
                IORequest iorq;
                iorq.output = Nbuff("HTTP/1.0 200 OK\nContent-Type: text/plain\nContent-Length: 10\n\n0123456789");
                iorq.callback = ioWriteCompleted;
                client_socket.io(loop, iorq, 10.seconds);
            }
            else
            {
                client_socket.close();
            }
        };

        iorq.to_read = 1024;
        iorq.callback = ioReadCompleted;
        client_socket.io(loop, iorq, 10.seconds);
    }
    server_socket.accept(loop, 5.seconds, &acceptFunction);
    hlSleep(60.seconds);
}

immutable servers = 4;

void main()
{
    globalLogLevel = LogLevel.info;
    auto server_socket = new HioSocket();
    server_socket.bind("0.0.0.0:12345");
    server_socket.listen(1024);
    auto server_threads = iota(servers).map!(i => threaded(&server, server_socket.fileno).start).array;
}
