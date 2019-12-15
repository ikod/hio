/+ dub.sdl:
    name "t2"
    dflags "-I../source"
    dflags "-debug"
    lflags "-lcares"
    dependency "hio" version="*"
+/

module tests.t2;

import std.experimental.logger;
import std.datetime;
import std.string;
import std.algorithm;
import std.range;

import core.atomic;

import hio.socket;
import hio.scheduler;

shared int ops;

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
    auto message = s.recv(16, 200.msecs);
    assert(message.input == "hello".representation, "got %s instead of 'hello'(%s)".format(message.input, message));
    s.close();
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
        //infof("accept %d", n);
        task(&handler, client_socket).start;
    }
}

enum clients = 4;
enum servers = 2;

void main()
{
    globalLogLevel = LogLevel.trace;
    App({
        auto server_socket = new HioSocket();
        server_socket.bind("0.0.0.0:12345");
        server_socket.listen(100);

        auto server_threads = iota(servers).map!(i => threaded(&server, server_socket.fileno, i).start).array;

        auto client_threads = iota(clients).map!(i => threaded(&client).start).array;

        hlSleep(5.seconds);

        client_threads.each!(t => t.stopThreadLoop());
        server_threads.each!(t => t.stopThreadLoop());
        server_socket.close();
        infof("done %d", ops);
    });
}
