module gio;

import std.datetime;
import std.array;
import std.experimental.logger;
import core.stdc.stdint : intptr_t, uintptr_t;

public import  gio.loop;

private static EventLoop evl;

static this() {
    version(OSX) {
        import gio.osx;
        evl.impl = new OSXEventLoopImpl();
    }
    version(linux) {
        import gio.epoll;
        evl.impl = new EpollEventLoopImpl();
    }
    if ( evl.impl is null ) {
        warning("WARNING: You are using fallback 'select' asyncio driver.");
        import gio.select;
        evl.impl = new SelEventLoopImpl();
    }
}

auto ref eventLoop() {
    return evl;
}

auto runEventLoop() {
    evl.run();
}

auto stopEventLoop() {
    evl.stop();
}



unittest {
    import std.exception;
    import core.exception;
    import std.stdio;
    import std.experimental.logger;
    import gio.select;
    
    void test() {
        import std.process;
        import std.format;
        import std.algorithm;

        globalLogLevel(LogLevel.info);
        auto p = pipe();
        int writes, reads;
        int wr = p.writeEnd.fileno();
        int rd = p.readEnd.fileno();
        auto wrh = EventHandler(evl, wr, AppEvent.OUT);
        auto rdh = EventHandler(evl, rd, AppEvent.IN);
        void delegate(scope AppEvent) write_handler = (scope AppEvent e) {
            tracef("Got writer event, data: %d", e.data);
            wrh.deregister();
            p.writeEnd.writeln("%d".format(writes));
            p.writeEnd.flush();
            if ( ++writes == 100 ) {
                rdh.deregister();
                evl.stop();
                return;
            }
        };
        void delegate(scope AppEvent) read_handler = (scope AppEvent e) {
            tracef("Got reader event, data: %d", e.data);

            auto data_len = e.data<0?16:e.data;

            char[] b = new char[data_len];
            p.readEnd.readln(b);
            reads++;
            wrh.register(write_handler);
        };
        
        wrh.register(write_handler);
        rdh.register(read_handler);
        evl.run();
        assert(reads == 99);
        info("Test timer");
        SysTime[] timeouts;
        void delegate(scope AppEvent) timer_handler = (scope AppEvent e) {
            tracef("Got timeout event");
            timeouts ~= Clock.currTime;
            if (timeouts.length == 4) {
                evl.stop();
            }
        };
        //globalLogLevel(LogLevel.trace);
        auto ta = Timer(Clock.currTime + 10.msecs, null);
        auto tb = Timer(Clock.currTime + 5.msecs, null);
        assert(tb<ta);
        assert(ta>tb);
        evl.startTimer(1000.msecs, timer_handler);
        evl.startTimer(500.msecs,  timer_handler);
        evl.startTimer(1500.msecs, timer_handler);
        evl.startTimer(200.msecs,  timer_handler);
        auto tid = evl.startTimer(201.msecs,  timer_handler);
        auto timers = timerList[].array;
        assert(timers[0]<timers[1] && timers[1]<timers[2] && timers[2]<timers[3]);
        evl.stopTimer(tid);
        evl.run();
        foreach(i;1..timeouts.length) {
            // should print something like 300, 500, 500
            writeln(timeouts[i] - timeouts[i-1]);
        }
    }
    auto evl = eventLoop();
    info("Testing best available event loop");
    test();
    evl.impl = new SelEventLoopImpl();
    info("Testing fallback event loop (select)");
    test();
}
