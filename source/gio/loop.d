module gio.loop;

import std.datetime;
import std.exception;
import std.format;
import std.algorithm;
import std.experimental.logger;
import std.container;
import std.stdio;
import std.typecons;
import core.thread;

interface EventLoopImpl {
    void init();
    void run(Duration d=1.seconds);
    void stop();
    void deinit();
    int add(int fd, AppEvent.Type event, EventHandler* handler);
    int del(int fd, AppEvent.Type event, EventHandler* handler);
    void start_timer(Timer) @safe;
};

alias HandlerDelegate = void delegate (AppEvent);

class Timer {
    SysTime         expires;
    HandlerDelegate handler;
    ulong           id;
    EventLoopImpl   evl;
    this(SysTime e, HandlerDelegate h, ulong id, EventLoopImpl evl) pure nothrow @nogc @safe {
        this.expires = e;
        this.handler = h;
        this.id = id;
        this.evl = evl;
    }
    int opCmp(in Timer other) const nothrow pure @safe {
        return expires < other.expires?-1:1;
    }
    override string toString() const {
        return "Timer(%s, %d, %s, %s)".format(expires, id, handler, evl);
    }
}

static  RedBlackTree!(Timer) timerList;

static this() {
    timerList = new RedBlackTree!(Timer)();
}

static void timerHandler(ulong id)
in {
    assert(!timerList.empty);
    assert(timerList.front.id == id);
    }
body{
    auto thisTimer = timerList.front;
    debug tracef("process timer %s, delay %s", thisTimer, thisTimer.expires - Clock.currTime);
    enforce(thisTimer.id == id, "Front  %d != %d".format(thisTimer.id, id));
    if (thisTimer.handler) {
        thisTimer.handler(AppEvent(AppEvent.TMO));
    }
    if ( timerList.empty ) {
        debug tracef("Empty timerList, probably evenloop were stopped from inside handler");
        return;
    }
    timerList.removeFront;
    while ( !timerList.empty && timerList.front.handler==null ) {
        // skip removed timers
        timerList.removeFront;
    }
    if ( !timerList.empty ) {
        auto nextTimer = timerList.front;
        nextTimer.evl.start_timer(nextTimer);
        debug tracef("set next timer %s", nextTimer);
    }
}

struct EventLoop {
    private {
        EventLoopImpl   _impl;
        ulong           _timer_id = 1;
    }
    @property EventLoopImpl impl() pure @safe {
        return _impl;
    }
    @property void impl(EventLoopImpl impl) {
        _impl = impl;
    }
    Timer startTimer(Duration d, HandlerDelegate h, bool periodic = false) @safe {
        enforce(d > 0.seconds, "You can't add timer for past time %s".format(d));
        Timer t = new Timer(Clock.currTime + d, h, _timer_id, this._impl);
        _timer_id++;
        if ( timerList.empty || t <= timerList.front ) {
            // add new timer to kernel
            _impl.start_timer(t);
        }
        timerList.insert(t);
        return t;
    }
    void stopTimer(Timer t) {
        assert(!timerList.empty);
        auto a = scoped!Timer(t.expires, null, t.id, null);
        auto r = timerList.equalRange(a);
        enforce(!r.empty, "Failed to find Timer to delete");
        foreach(i; r) {
            i.handler = null;
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

