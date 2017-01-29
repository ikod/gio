module gio;

import std.datetime;
import std.array;
import std.experimental.logger;
import core.stdc.stdint : intptr_t, uintptr_t;
import core.thread;

public import gio.loop;
public import gio.socket;
public import gio.task;

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

auto sleep(Duration d) {
    trace("Sleep start");
    auto f = Fiber.getThis();
    auto handler = delegate void(scope AppEvent e) {
        f.call();
    };
    evl.startTimer(d, handler);
    Fiber.yield();
    trace("Sleep done");    
}

auto delay(Duration d) {
    auto f = new Future!void();

    evl.startTimer(d, delegate void(scope AppEvent e) {
        f.set();
    });

    return f;
}
unittest {
    import std.exception;
    import core.exception;
    import std.stdio;
    import std.experimental.logger;
    import std.algorithm.comparison;

    import gio.select;
    
    void test() {
        import std.process;
        import std.format;
        import std.algorithm;

        globalLogLevel(LogLevel.info);
        info("testing io");
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

        info("testing timer");
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
            //writeln(timeouts[i] - timeouts[i-1]);
        }
        info("Test socket");
        auto client = gioSocket();
        auto server = gioSocket();
        void function(gioSocket) process = (gioSocket so) {
            trace("accepted connection");
        };
//        server.listen(8080)
    }
    auto evl = eventLoop();
    info("Testing best available event loop");
    test();
    evl.impl = new SelEventLoopImpl();
    info("Testing fallback event loop (select)");
    test();
    info("Testing fallback event loop (select) - done");
    evl = eventLoop();
    task(delegate void() {
        info("test in task");
        test();
        info("test in task - done");
        globalLogLevel(LogLevel.trace);
        info("test sleep");
        task(function void() {
            sleep(2.seconds);
            stopEventLoop();
        }).call();
        task(function void() {
            sleep(500.msecs);
            info("1");
            sleep(500.msecs);
            info("2");
        }).call();
            // .then(delegate void() {
            //     info("then");
            //     evl.stop();
            //     info("then-then");
            // });
        evl.run();
        info("test sleep - done");
    }).call();
    globalLogLevel(LogLevel.trace);
//    evl = eventLoop();
    task(function void() {
        info("test sleep again");
        sleep(2.seconds);
        info("test sleep again - done");
        stopEventLoop();
    }).call();
    evl.run();

    info("test delay");
    // async/callback based future tests
    int[] container;
    delay(2000.msecs).
        transform(delegate void () {
            info("delayed 2");
            container ~= 2;
        }).
        transform(delegate void() {
            sleep(1.seconds);
            info("delayed 3");
            container ~= 3;
        });
    delay(1.seconds).
        transform(delegate int(){
            info("delayed 1");
            container ~= 1;
            return 1;
        }).
        transform(function int (int x) {
            assert(x == 1);
            sleep(3.seconds);
            return x+1;
        }).
        transform(delegate void (int x) {
            assert(x == 2);
            infof("delayed 4 = %d", x);
            container ~= 4;
            stopEventLoop();
        });
    evl.run();
    assert(equal(container, [1,2,3,4]));

    // task based future tests
    task(function void() {
        info("Testing wait for future");
        auto f = delay(500.msecs);
        info("Testing wait for future - future started");
        assert(!f.isReady);
        f.wait();
        assert(f.isReady);
        info("Testing wait for future - done");
        stopEventLoop();
    }).call();
    evl.run();
    task(function void() {
        info("Testing wait for failed future");
        auto f = delay(500.msecs).
            transform(function void() {
                info("Throwing");
                throw new Exception("Test exception");
            });
        info("Testing wait for failed future - future started");
        assert(!f.isReady);
        try {
            f.wait();
        } catch(Exception e) {
            info("Catched exception");
        }
        assert(f.isFailed);
        info("Testing wait for failed future - done");
        stopEventLoop();
    }).call();
    evl.run();
    task(function void() {
        info("Testing get() for failed future");
        auto f = delay(500.msecs).
            transform(function void() {
                info("Throwing");
                throw new Exception("Test exception");
            });
        info("Testing get() for failed future - future started");
        assert(!f.isReady);
        try {
            f.get();
        } catch(Exception e) {
            info("Catched exception");
        }
        assert(f.isFailed);
        info("Testing wait for failed future - done");
        stopEventLoop();
    }).call();
    evl.run();
    // promise(function void() {
    //     return;
    // }).
    // then(function void() {
    //     stopEventLoop();
    // });
    // evl.run();
    // task(delegate void() {
    //     auto p = promise();
    //     p.wait();
    // }).call();
}
