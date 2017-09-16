module gio;

import std.typecons;
import std.datetime;
import std.exception;
import std.array;
import std.experimental.logger;
import core.stdc.stdint : intptr_t, uintptr_t;
import core.thread;

public import gio.loop;
public import gio.socket;
public import gio.task;
public import nbuff.buffer;


private static EventLoop evl;
static this() {
    version(OSX) {
        import gio.drivers.osx;
        evl.impl = new OSXEventLoopImpl();
    }
    version(linux) {
        import gio.drivers.epoll;
        evl.impl = new EpollEventLoopImpl();
    }
    if ( evl.impl is null ) {
        warning("WARNING: You are using fallback 'select' asyncio driver.");
        import gio.drivers.select;
        evl.impl = new SelEventLoopImpl();
    }
}
static this() {
    evl = getEventLoop();
}
class TimedOutException: Exception {
    this(string s = "") {
        super(s);
    }
}

auto ref getEventLoop() {
    return evl;
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

auto run_until_complete(void delegate() f) {
    auto t = task({
        try {
            f();
        } catch(Exception e){
            error("uncought exception %s in run_unil_complete");
        } finally {
            stopEventLoop();
        }
    });
    t.call();
    if ( t.running() ) {
        runEventLoop();
    }
    trace("competed");
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


//auto delay(Duration d) {
//    auto f = new Future!bool();
//
//    evl.startTimer(d, delegate void(scope AppEvent e) {
//        f.set_result(true);
//    });
//
//    return f;
//}

unittest {
    globalLogLevel(LogLevel.info);
    bool ok;
    run_until_complete({
        auto t = task({
            sleep(1.seconds);
        });
        t.call();
        t.join();
        ok = true;
    });
    assert(ok);
    info("testing run_until_complete - ok");
}

unittest {
    import std.exception;
    import core.exception;
    import std.stdio;
    import std.experimental.logger;
    import std.algorithm.comparison;

    import gio.drivers.select;
    
    void test() {
        import std.process;
        import std.format;
        import std.algorithm;

        globalLogLevel(LogLevel.info);
        trace("testing io");
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

        trace("testing timer");
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
        trace("Test socket");
        auto client = new gioTCPSocket();
        auto server = new gioTCPSocket();
        //void function(gioSocket) process = (gioSocket so) {
        //    trace("accepted connection");
        //};
//        server.listen(8080)
    }
    //auto evl = eventLoop();
    info("Testing best available event loop");
    test();
    info("Testing best available event loop - done ");
    info("Testing fallback event loop (select)");
    evl.impl = new SelEventLoopImpl();
    test();
    info("Testing fallback event loop (select) - done");
    evl = eventLoop();
    task(delegate void() {
        test();
        globalLogLevel(LogLevel.info);
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
    globalLogLevel(LogLevel.info);
//    evl = eventLoop();
    task(function void() {
        info("test sleep again");
        sleep(2.seconds);
        info("test sleep again - done");
        stopEventLoop();
    }).call();
    evl.run();
}

unittest {
    import std.stdio;
    import std.datetime;
    import std.functional;

    auto f = new Future!int;
    assertThrown!InvalidStateError(f.result());
    f.set_result(1);
    assert(f.done());
    assert(f.result() == 1);
    assert(f.cancelled() == false);     // not cancelled
    assert(f.cancel() == false);        // can't cancel as it is ready
    info("set_result - ok");
    f = new Future!int;
    assert(f.cancel() == true);
    assertThrown!CancelledError(f.result());
    info("cancel - ok");

    f = new Future!int;
    f.onCompleteType cb = delegate void (typeof(f) future) {
        writefln("callback for future %s", f);
        return;
    };
    f.add_done_callback(cb);
    f.add_done_callback(cb);
    assert(f.remove_done_callback(cb) == 2);
    info("remove callbacks - ok");

    //
    // 1. add several callbacks (with ards using partial() and with no args
    // 2. set result
    // 3. verify that callbacks called
    //
    f = new Future!int;
    int sum = 0;
    int[] order;

    auto cb_no_args = delegate void (typeof(f) future) {
        sum += 5;
    };
    auto cb_with_arg = delegate void (int arg, typeof(f) future) {
        sum += future.result() + arg;
        order ~= arg;
        return;
    };
    f.add_done_callback(&partial!(cb_with_arg, 1));
    f.add_done_callback(&partial!(cb_with_arg, 2));
    auto cb_with_arg2 = &partial!(cb_with_arg, 3);
    f.add_done_callback(cb_with_arg2);
    assert(f.remove_done_callback(cb_with_arg2) == 1);
    f.add_done_callback(cb_no_args);
    f.set_result(10);
    assert(sum == 23 + 5 /* 10+1 + 10+2 + 5 */);
    assert(order == [1,2]);
    info("check callbacks1 - ok");

    //
    // 1. set result for Future
    // 2. add callback
    // 3. check that callback is called at the time it was added
    //
    f = new Future!int;
    sum = 0;
    order = [];
    f.set_result(10);
    f.add_done_callback(&partial!(cb_with_arg, 1));
    assert(sum == 11 /* 10+1 */);
    assert(order == [1]);
    info("check callbacks2 - ok");

    // check exceptions
    f = new Future!int;
    f.set_exception(new Exception("test"));
    assertThrown!InvalidStateError(f.set_result(1));
    assertThrown!InvalidStateError(f.set_exception(new Exception("test")));
    assert(f.exception());
    info("check exceptions - ok");

    run_until_complete({
        globalLogLevel(LogLevel.info);
        auto slow_fun = delegate int (int d, int v) {
            sleep(d.seconds);
            return d + v;
        };
        auto t = async(slow_fun, 1, 6);
        assert(t.await() == 7);
        info("check await - ok");
    });
    run_until_complete({
        globalLogLevel(LogLevel.info);
        auto slow_fun = delegate int (int d) {
            if ( d == 0 ) {
                throw new Exception("test");
            }
            return 0;
        };
        auto t = async(slow_fun, 0);
        assertThrown!Exception(t.await());
        assert(t.exception());
        info("check exception in await - ok");
    });
    run_until_complete({
        info("parallel slow funcs - start");
        auto slow_sum = delegate int (int d, int v) {
            sleep(d.seconds);
            return d + v;
        };
        auto slow_sub = delegate int (int d, int v) {
            sleep(d.seconds);
            return d - v;
        };
        auto asum = async(slow_sum, 2, 1);
        auto asub = async(slow_sub, 1, 2);
        assert(asum.await() ==  3);
        assert(asub.await() == -1);
        info("parallel slow funcs - ok");
    });
    run_until_complete({
        info("test cancelation");
        auto slow = delegate int (int d) {
            sleep(d.seconds);
            return d;
        };
        auto first  = async(slow, 1);
        auto second = async(slow, 2);
        auto c = delegate void(typeof(first) f) {
            second.cancel();
        };
        first.add_done_callback(toDelegate(c));
        try {
            await(first);
            await(second);
        } catch(Exception e) {
        }
        assert(second.cancelled());
        info("done");
    });
}