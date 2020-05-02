/+ dub.sdl:
    name "t3"
    dflags "-I../source"
    #dflags "-debug"
    lflags "-lcares"
    buildRequirements "allowWarnings"
    dependency "hio" version="*"
    dependency "nbuff" version="*"
+/

module tests.t3;
import std.experimental.logger;
import std.datetime;
import std.string;
import std.algorithm;
import std.range;

import core.atomic;

import hio.socket;
import hio.scheduler;

import nbuff: Nbuff;

shared int ops;

enum BufferSize = 4*1024;

void client()
{
    while(true)
    {
        auto s = new HioSocket();
        s.connect("127.0.0.1:12345", 1.seconds);
        s.send("hello".representation, 1.seconds);
        s.close();
    }
}

void handler(HioSocket s)
{
    scope(exit)
    {
        s.close();
    }

    Nbuff buffer;
    size_t p, scanned;
    int connections;

    while(true)
    {
        IOResult message = s.recv(BufferSize, 10.seconds);
        if (message.error)
        {
            errorf("error receiving request");
            return;
        }
        if (message.timedout)
        {
            errorf("Timeout waiting for request");
            return;
        }
        assert(message.input.length>0, "empty buffer");
        buffer.append(message.input);
        p = buffer.countUntil("\n\n".representation, scanned);
        if (p>=0)
        {
            connections++;
            if (connections < 5)
            {
                s.send("HTTP/1.0 200 OK\nContent-Type: text/plain\nContent-Length: 10\n\n0123456789".representation);
                buffer = Nbuff();
                p = 0;
                scanned = 0;
                continue;
            }
            else
            {
                s.send("HTTP/1.0 200 OK\nContent-Type: text/plain\nContent-Length: 10\nConnection: close\n\n0123456789".representation);
                return;
            }
        }
        else
        {
            scanned = buffer.length - 1;
        }
    }
}

void server(int so, int n)
{
    auto sock = new HioSocket(so);
    scope(exit)
    {
        sock.close();
    }
    while(true)
    {
        auto client_socket = sock.accept();
        ops.atomicOp!"+="(1);
        task(&handler, client_socket).start;
    }
}

enum servers = 2;

void main()
{
    globalLogLevel = LogLevel.info;
    App({
        auto server_socket = new HioSocket();
        server_socket.bind("0.0.0.0:12345");
        server_socket.listen(1024);

        auto server_threads = iota(servers).map!(i => threaded(&server, server_socket.fileno, i).start).array;

        hlSleep(60.seconds);

        server_threads.each!(t => t.stopThreadLoop());
        server_threads.each!(t => t.wait());
        server_socket.close();
        infof("done %d", ops);
    });
}
