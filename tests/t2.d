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

import hio.socket;
import hio.scheduler;

void handler(HioSocket s)
{
    s.recv(16, 200.msecs);
    s.close();
}
void client()
{
    foreach(i;0..50000000)
    {
        auto s = new HioSocket();
        s.connect("127.0.0.1:12345", 1.seconds);
        s.send("hello".representation, 1.seconds);
        s.close();
    }
}

void server(int so, int n)
{
    auto sock = new HioSocket(so);
    while(true)
    {
        auto client_socket = sock.accept();
        //infof("accept %d", n);
        task(&handler, client_socket).start;
    }
}

enum clients = 4;
enum servers = 4;

void main()
{
    globalLogLevel = LogLevel.info;
    App({
        auto server_socket = new HioSocket();
        server_socket.bind("0.0.0.0:12345");
        server_socket.listen(100);

        foreach(i;0..servers)
        {
            threaded(&server, server_socket.fileno, i)
                .isDaemon(true) // do not wait completion
                .start;
        }

        foreach(i;0..clients)
        {
            threaded(&client)
                .isDaemon(true) // do not wait completion
                .start;
        }
        hlSleep(1.minutes);
        server_socket.close();
        info("done");
    });
}