/+ dub.sdl:
    name "t2"
    dflags "-I../source"
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

void client_task()
{
    while(true)
    {
        auto s = new HioSocket();
        s.connect("127.0.0.1:12345", 1.seconds);
        s.send("hello".representation, 1.seconds);
        s.close();
    }
}

void client_thread()
{
    enum client_tasks = 16;
    auto tasks = iota(client_tasks).map!(i => task(&client_task)).array;
    tasks.each!(t => t.start());
    tasks.each!(t => t.wait());
}

void handler(HioSocket s)
{
    auto message = s.recv(16, 200.msecs);
    assert(message.input == "hello".representation);
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
        task(&handler, client_socket).start;
    }
}

enum clients = 2;
enum servers = 2;

void main()
{
    globalLogLevel = LogLevel.info;
    App({
        auto server_socket = new HioSocket();
        server_socket.bind("0.0.0.0:12345");
        server_socket.listen(2048);

        auto server_threads = iota(servers).map!(i => threaded(&server, server_socket.fileno, i).start).array;

        auto client_threads = iota(clients).map!(i => threaded(&client_thread).start).array;

        hlSleep(10.seconds);

        client_threads.each!(t => t.stopThreadLoop());
        server_threads.each!(t => t.stopThreadLoop());

        client_threads.each!(t => t.wait());
        server_threads.each!(t => t.wait());

        server_socket.close();
        infof("done %d", ops);
    });
}
