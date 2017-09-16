module gio.loop;

import std.datetime;
import std.exception;
import std.format;
import std.algorithm;
import std.experimental.logger;
import std.container;
import std.stdio;
import core.thread;

interface EventLoopImpl {
    void init();
    void run(Duration d=1.seconds);
    void stop();
    void deinit();
    int add(int fd, AppEvent.Type event, EventHandler* handler);
    int del(int fd, AppEvent.Type event, EventHandler* handler);
    void timer(ref Timer);
};

alias HandlerDelegate = void delegate (AppEvent);

struct  Timer {
    SysTime         expires;
    HandlerDelegate handler;
    ulong           id;
    EventLoopImpl   evl;

    int opCmp(ref const Timer other) {
        return expires < other.expires?-1:1;
    }
}

static  DList!Timer timerList;

static void timerHandler(ulong id)
in {
    assert(!timerList.empty);
    assert(timerList.front.id == id);
    }
body{
    auto thisTimer = timerList.front;
    if (thisTimer.handler) {
        thisTimer.handler(AppEvent(AppEvent.TMO));
    }
    if ( timerList.empty ) {
        debug trace("Empty timerList, probably evenloop were stopped from inside handler");
        return;
    }
    timerList.removeFront;
    while ( !timerList.empty && timerList.front.handler==null ) {
        // skip removed timers
        timerList.removeFront;
    }
    if ( !timerList.empty ) {
        auto nextTimer = timerList.front;
        nextTimer.evl.timer(nextTimer);
    }
}

struct EventLoop {
    private {
        EventLoopImpl   _impl;
        ulong           _timer_id;
    }
    @property EventLoopImpl impl() pure @safe {
        return _impl;
    }
    @property void impl(EventLoopImpl impl) {
        _impl = impl;
    }
    Timer startTimer(Duration d, HandlerDelegate h, bool periodic = false) {
        enforce(d > 0.seconds, "You can't add timer for past time %s".format(d));
        Timer t = Timer(Clock.currTime + d, h, _timer_id, this._impl);
        _timer_id++;
        if ( timerList.empty || t <= timerList.front ) {
            // 1. insert it in front of timers list
            timerList.insertFront(t);
            // 2. add new timer to kernel
            _impl.timer(t);
        } else if ( t > timerList.back ) {
            // add to tail
            timerList.insertBack(t);
        } else if ( t > timerList.front ) {
            // between first and last
            // just insert into middle, no kernel manipulation
            auto r = timerList[].find!"a > b"(t);
            timerList.insertBefore(r, t);
        } 
        return t;
    }
    void stopTimer(in ref Timer t) {
        assert(!timerList.empty);
        auto r = timerList[].find!(a => a.id == t.id);
        if (!r.empty ) {
            r.front.handler = null;
        }
    }
    int add(int fd, AppEvent.Type ev, EventHandler* handler) {
        assert(_impl, "EventLoop not initialized?");
        return _impl.add(fd, ev, handler);
    }
    int del(int fd, AppEvent.Type ev, EventHandler* handler) {
        assert(_impl, "EventLoop not initialized?");
        return _impl.del(fd, ev, handler);
    }
    void run(Duration d = 1.seconds) {
        assert(_impl, "EventLoop not initialized?");
        _impl.init();
        _impl.run(d);
    }
    void stop() {
        assert(_impl, "EventLoop not initialized?");
        _impl.stop();
        _impl.deinit();
        if ( !timerList.empty ) {
            timerList.clear;
        }
        _impl.init();
    }
}

struct EventHandler {
    EventLoop       evl;
    int             fd;
    AppEvent.Type   events;
    void delegate (AppEvent) handler;
    bool registered;

    @disable this(this);

    this(EventLoop evl, int fd, AppEvent.Type events) {
        this.evl = evl;
        this.fd = fd;
        this.events = events;
    }
    int register(void delegate(AppEvent) handler) {
        enforce(!registered, "You trying register registered handler");
        debug tracef("register handler for fd %d", fd);
        registered = true;
        this.handler = handler;
        auto rc = evl.add(fd, events, &this);
        debug tracef("register handler for fd %d - %s", fd, rc==0?"ok":"fail");
        return rc;
    }
    int deregister() {
        enforce(registered, "You trying to deregister unregistered handler");
        debug tracef("deregister handler for fd %d", fd);
        registered = false;
        this.handler = null;
        auto rc = evl.del(fd, events, &this);
        debug tracef("deregister handler for fd %d - %s", fd, rc==0?"ok":"fail");
        return rc;
    }
    ~this() {
        if ( registered ) {
            deregister();
        }
    }
}

static immutable string[int] AppEventNames;
static this() {
    AppEventNames = [
        AppEvent.IN:   "IN",
        AppEvent.OUT:  "OUT",
        AppEvent.CONN: "CONN",
        AppEvent.ERR:  "ERR",
        AppEvent.HUP:  "HUP",
        AppEvent.TMO:  "TMO",
    ];
}

struct AppEvent {
    import core.stdc.stdint : intptr_t, uintptr_t;
    
    alias  Type = short;
    enum : Type {
        IN      = 1,
        OUT     = 4,
        CONN    = 8,
        ERR     = 0x10,
        HUP     = 0x20,
        TMO     = 0x40
    };
    Type        events;
    intptr_t    data;

    this(Type e, intptr_t d = intptr_t.max) {
        events = e;
        data = d;
    }
    string toString() pure {
        import std.array;
        import std.algorithm;
        string   result;
        string[] n;
        foreach(t; sort(AppEventNames.byKey.array)) {
            if ( events & t ) {
                n ~= AppEventNames[t];
            }
        }
        result = "appEvent: " ~  n.join("|");
        return result;
    }
    unittest {
        import std.stdio;
        AppEvent e = AppEvent(AppEvent.IN|AppEvent.OUT|AppEvent.CONN|AppEvent.ERR|AppEvent.HUP|AppEvent.TMO);
        assert(e.toString == "appEvent: IN|OUT|CONN|ERR|HUP|TMO");
    }
}

