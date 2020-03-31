/+ dub.sdl:
    name "t4"
    dflags "-I../source"
    #dflags "-debug"
    #debugVersions "nbuff"
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

    void acceptFunction(int s) @safe
    {
        if ( s == -1 )
        {
            // timeout
            server_socket.accept(loop, 5.seconds, &acceptFunction);
            return;
        }
        auto client_socket = new hlSocket(s);
        void ioWriteCompleted(IOResult iores)
        {
            if (iores.error)
            {
                throw new Exception("err");
            }
            client_socket.close();
        }
        void ioReadCompleted(IOResult iores) @trusted
        {
            if ( !iores.timedout && !iores.error )
            {
                IORequest iorq;
                iorq.output = NbuffChunk("HTTP/1.0 200 OK\nContent-Type: text/plain\nContent-Length: 10\n\n0123456789");
                iorq.callback = &ioWriteCompleted;
                client_socket.io(loop, iorq, 10.seconds);
            }
            else
            {
                client_socket.close();
            }
        }
        IORequest iorq;
        iorq.to_read = 64;
        iorq.callback = &ioReadCompleted;
        client_socket.io(loop, iorq, 10.seconds);
    }
    server_socket.accept(loop, 5.seconds, &acceptFunction);
    hlSleep(60.seconds);
}

immutable servers = 2;

void main()
{
    globalLogLevel = LogLevel.trace;
    auto server_socket = new HioSocket();
    server_socket.bind("0.0.0.0:12345");
    server_socket.listen(1024);
    auto server_threads = iota(servers).map!(i => threaded(&server, server_socket.fileno).start).array;
}
