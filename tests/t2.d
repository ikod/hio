/+ dub.sdl:
    name "t2"
    dflags "-I../source"
    dflags "-debug"
    lflags "-lcares"
    dependency "hio" version="*"
+/

module tests.t2;

import std.experimental.logger;

import hio.socket;
import hio.scheduler;

void main()
{
    globalLogLevel = LogLevel.trace;
    void server_code(int so, int n)
    {
        void client_code (HioSocket s)
        {
            s.close();
        }
        auto sock = new HioSocket(so);
        while(true)
        {
            auto client_socket = sock.accept();
            infof("accept %d", n);
            task(&client_code, client_socket).start;
        }
    }
    App({
        enum threads = 4;
        auto server_socket = new HioSocket();
        server_socket.bind("0.0.0.0:12345");
        server_socket.listen(100);

        auto s0 = threaded(&server_code, server_socket.fileno, 0).start;
        auto s1 = threaded(&server_code, server_socket.fileno, 1).start;
        auto s2 = threaded(&server_code, server_socket.fileno, 2).start;
        auto s3 = threaded(&server_code, server_socket.fileno, 3).start;
        s0.wait();
        s1.wait();
        server_socket.close();
    });
}