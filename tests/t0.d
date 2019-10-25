#!/usr/bin/env dub
/+ dub.sdl:
    name "t0"
    dflags "-I../source"
    dflags "-debug"
    dependency "hio" version="*"
+/
// cd to tests and run with "dub run --single t0.d"
import std.datetime;
import std.stdio;
import std.experimental.logger;
import core.sys.posix.signal;
import core.memory;
import core.thread;

import hio.scheduler;
import hio.socket;
import hio.events;
import hio.loop;

static bool server_active;
void client() {

    hlSleep(500.msecs);
    while (server_active) {
        auto s = new HioSocket();
        info("Connecting");
        s.connect("127.0.0.1:9999", 1.seconds);
        if (s.connected()) {
            info("Connected");
        }
        else {
            infof("Failed to connect: %d", s.errno());
        }
        hlSleep(100.msecs);
        s.close();
    }
}

void server() {

    auto s = new HioSocket();
    scope (exit) {
        //s.close();
    }

    auto started = Clock.currTime;

    try {
        s.bind("0.0.0.0:9999");
    }
    catch (Throwable t) {
        error(t);
        return;
    }
    infof("server bind ok");

    s.listen();
    server_active = true;
    while (Clock.currTime < started + 10.seconds) {
        auto new_socket = s.accept();
        infof("using accepted socket %s", new_socket);
        new_socket.close();
        //info("next loop");
        new_socket = null;
    }
    server_active = false;
    s.close();
}

void job() {

    SigHandlerDelegate sigint = delegate void(int signum) {
        info("signal");
        getDefaultLoop().stop();
    };
    auto sighandler = new Signal(SIGINT, sigint);
    getDefaultLoop().startSignal(sighandler);

    auto s = task(&server);
    auto clients = [task(&client), task(&client)];
    s.start;
    foreach(c; clients) {
        c.start();
    }
    s.wait();
    info("server done");
    foreach (c; clients) {
        c.wait();
        info("client done");
    }
}

void main()
{
    globalLogLevel = LogLevel.info;
    ignoreSignal(SIGINT);
    App(&job);
}