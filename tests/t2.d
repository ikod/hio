/+ dub.sdl:
    name "t2"
    dflags "-I../source"
    lflags "-lcares"
    dependency "hio" version="*"
    debugVersions "hioepoll"
    debugVersions "hiosocket"
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

enum client_tasks = 16;
enum clients = 2;
enum servers = 2;
enum duration = 15.seconds;

void client_task()
{
    while(true)
    {
        auto s = new HioSocket();
        scope(exit)
        {
            s.close();
        }
        try
        {
            s.connect("127.0.0.1:12345", 1.seconds);
            if (s.connected)
            {
                s.send("hello".representation, 1.seconds);
            }
            s.close();
            hlSleep(100.hnsecs);
        }
        catch(LoopShutdownException)
        {
            info("got shutdown");
            return;
        }
        catch(Exception e)
        {
            errorf("%s", e);
            return;
        }
        tracef("next iteration");
    }
}

void client_thread()
{
    auto tasks = iota(client_tasks).map!(i => task(&client_task)).array;
    tasks.each!(t => t.start());
    tasks.each!(t => t.wait(2*duration));
}

void handler(HioSocket s)
{
    scope(exit)
    {
        s.close();
    }
    try
    {
        auto message = s.recv(16, 200.msecs);
        if (!message.error && !message.timedout)
        {
            assert(message.input == "hello".representation, "msg: %s, sock: %s".format(message, s));
        }
    }
    catch(LoopShutdownException)
    {
        return;
    }
    catch(Exception e)
    {
        error("server task exception: %s", s);
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
        try
        {
            auto client_socket = sock.accept();
            ops.atomicOp!"+="(1);
            task(&handler, client_socket).start;
        }
        catch(LoopShutdownException)
        {
            return;
        }
        catch(Exception e)
        {
            errorf("server exception: %s", e);
            return;
        }
    }
}


void main()
{
    globalLogLevel = LogLevel.info;
    App({
        auto server_socket = new HioSocket();
        server_socket.bind("0.0.0.0:12345");
        server_socket.listen(2048);

        auto server_threads = iota(servers).map!(i => threaded(&server, server_socket.fileno, i).start).array;

        auto client_threads = iota(clients).map!(i => threaded(&client_thread).start).array;

        hlSleep(duration);
        //globalLogLevel = LogLevel.trace;
        client_threads.each!(t => t.shutdownThreadLoop());
        server_threads.each!(t => t.shutdownThreadLoop());

        client_threads.each!(t => t.wait());
        server_threads.each!(t => t.wait());

        server_socket.close();
        infof("done %d", ops);
    });
}
