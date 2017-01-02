module gio.loop;

import std.datetime;
import std.exception;
import std.experimental.logger;


interface EventLoopImpl {
    void run(Duration d=1.seconds);
    void stop();
    int add(int fd, AppEvent.Type event, EventHandler* handler);
    int del(int fd, AppEvent.Type event, EventHandler* handler);
};

struct EventLoop {
    EventLoopImpl   impl;

    int add(int fd, AppEvent.Type ev, EventHandler* handler) {
        assert(impl, "EventLoop not initialized?");
        return impl.add(fd, ev, handler);
    }
    int del(int fd, AppEvent.Type ev, EventHandler* handler) {
        assert(impl, "EventLoop not initialized?");
        return impl.del(fd, ev, handler);
    }
    void run(Duration d = 1.seconds) {
        assert(impl, "EventLoop not initialized?");
        impl.run(d);
    }
    void stop() {
        assert(impl, "EventLoop not initialized?");
        impl.stop();
    }
}

struct EventHandler {
    EventLoop       evl;
    int  	  		fd;
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
        enforce(registered, "You trying deregister unregistered handler");
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
    Type		events;
    intptr_t 	data;

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

