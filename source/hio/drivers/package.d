module hio.drivers;

version(OSX) {
    public import hio.drivers.kqueue;
} else
version(FreeBSD) {
    public import hio.drivers.kqueue;
} else
version(linux) {
    public import hio.drivers.epoll;
} else {
    struct NativeEventLoopImpl {
        bool invalid;
        void initialize();
    }
}


public import hio.drivers.select;
