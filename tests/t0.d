#!/usr/bin/env dub
/+ dub.sdl:
    name "t0"
    dflags "-I../source"
    dflags "-release"
    lflags "-L.."
    lflags "-lgio"
    dependency "nbuff" version="~>0.0.3"
+/
// cd to tests and run with "dub run --single t0.d"
void main() {
    import std.datetime;
    import std.stdio;
    import gio;

    auto loop = getEventLoop();
    HandlerDelegate handler = (AppEvent e) {
        writeln("Hello from Handler");
        loop.stop();
    };
    auto timer = loop.startTimer(1.seconds, handler);
    writeln("Starting loop1, wait 1seconds ...");
    loop.run();
    writeln("loop stopped, bye");
    for(int i; i < 10_000; i++) {
        timer = loop.startTimer(1.seconds, handler);
        loop.stopTimer(timer);
    }
    Timer[] ts = new Timer[](1000);
    for(int i; i<100_000; i++) {
        ts[i] = loop.startTimer(1.seconds, handler);
    }
    for(int i; i<1000; i++) {
        loop.stopTimer(ts[i]);
    }
    timer = loop.startTimer(1.seconds, handler);
    writeln("Starting loop2, wait 1seconds ...");
    loop.run();
    writeln("loop stopped, bye");
}
