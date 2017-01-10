module gio.osx;

import gio.loop;

version(OSX):

// eventloop driver for OSX kqueue

pragma(msg, "building OSX event loop driver");
import std.datetime;
import std.process;
import std.exception;
import std.string;
import std.experimental.logger;

import core.stdc.errno: errno;
import core.stdc.string: strerror;
import core.stdc.stdint : intptr_t, uintptr_t;

import core.sys.posix.signal : timespec;
import core.sys.darwin.sys.event;
import core.sys.posix.fcntl: open, O_RDONLY;
import core.sys.posix.unistd: close;



static this () {
    globalLogLevel(LogLevel.info);
}

enum : short {
    EVFILT_READ =      (-1),
    EVFILT_WRITE =     (-2),
    EVFILT_AIO =       (-3),    /* attached to aio requests */
    EVFILT_VNODE =     (-4),    /* attached to vnodes */
    EVFILT_PROC =      (-5),    /* attached to struct proc */
    EVFILT_SIGNAL =    (-6),    /* attached to struct proc */
    EVFILT_TIMER =     (-7),    /* timers */
    EVFILT_MACHPORT =  (-8),    /* Mach portsets */
    EVFILT_FS =        (-9),    /* Filesystem events */
    EVFILT_USER =      (-10),   /* User events */
            /* (-11) unused */
    EVFILT_VM =        (-12)   /* Virtual memory events */
}

enum : ushort {
/* actions */
    EV_ADD  =                0x0001,          /* add event to kq (implies enable) */
    EV_DELETE =              0x0002,          /* delete event from kq */
    EV_ENABLE =              0x0004,          /* enable event */
    EV_DISABLE =             0x0008          /* disable event (not reported) */
}

struct kevent_t {
    uintptr_t       ident;          /* identifier for this event */
    short           filter;         /* filter for event */
    ushort          flags;          /* general flags */
    uint            fflags;         /* filter-specific flags */
    intptr_t        data;           /* filter-specific data */
    void            *udata;         /* opaque user data identifier */
}

extern(C) int kqueue() @safe @nogc nothrow;
extern(C) int kevent(int kqueue_fd, const kevent_t *events, int ne, const kevent_t *events, int ne,timespec* timeout) @safe @nogc nothrow;

class OSXEventLoopImpl : EventLoopImpl {
    private {
        enum MAXEVENTS = 1024;

        int  kqueue_fd;  // interface to kernel
        int  timer_fd;
        //Pipe cmdChannel; // for fast wakeup 

        bool running;
        int  in_index;

        kevent_t[MAXEVENTS] in_events;
        kevent_t[MAXEVENTS] out_events;
    }

    this() {
        kqueue_fd = timer_fd = -1;
    }
    final override void init() {
        if ( kqueue_fd == -1) {
            kqueue_fd = kqueue();
        }
        if ( timer_fd == -1 ) {
            timer_fd = open("/dev/zero", O_RDONLY);
        }
        debug tracef("kqueue_fd=%d", kqueue_fd);
    }
    final override void deinit() {
        debug tracef("deinit");
        close(kqueue_fd);
        kqueue_fd = -1;
        close(timer_fd);
        timer_fd = -1;
        in_index = 0;
    }
    final override void stop() {
        running = false;
    }

    final override void run(Duration d = 1.seconds) {
        running = true;
        while (running) {
            timespec ts = {
                tv_sec:  cast(typeof(timespec.tv_sec))d.split!("seconds", "nsecs")().seconds,
                tv_nsec: cast(typeof(timespec.tv_nsec))d.split!("seconds", "nsecs")().nsecs
            };
            debug trace("waiting for events");
            uint ready = kevent(kqueue_fd,
                                cast(kevent_t*)&in_events[0], in_index,
                                cast(kevent_t*)&out_events[0], MAXEVENTS,
                                &ts);
            debug tracef("kevent returned %d events", ready);
            if ( ready == 0 ) {
                debug trace("timeout");
                continue;
            }
            if ( ready < 0 ) {
                error("kevent returned error");
                return;
            }
            in_index = 0;
            foreach(i; 0..ready) {
                if ( !running ) {
                    break;
                }
                auto e = out_events[i];
                debug tracef("got kevent[%d] %s, data: %d, udata: %0x", i, e, e.data, e.udata);
                if ( e.ident == timer_fd ) {
                    ulong id = cast(ulong)e.udata;
                    debug trace("timer event, id = %d".format(id));
                    timerHandler(id);
                    continue;
                }
                EventHandler* h = cast(EventHandler*)e.udata;
                AppEvent appEvent = AppEvent(sysEventToAppEvent(e.filter), e.data);
                h.handler(appEvent);
            }
        }
        //kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
        in_index = 0;
    }
    ///
    /// del from monitoring
    /// 
    final override int del(int fd, AppEvent.Type event, EventHandler* handler) {
        int rc;
        kevent_t e;
        e.ident = fd;
        e.filter = appEventToSysEvent(event);
        e.flags = EV_DELETE;
        e.udata = cast(void*)handler;
        if ( in_index == MAXEVENTS ) {
            // flush
            rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
            debug if ( rc == -1 ) {
                error("error adding handler: %s", fromStringz(strerror(errno)));
            }
            in_index = 0;
        } else {
            in_events[in_index++] = e;
            rc = 0;
        }
        return rc;
    }
    ///
    /// add fd to monitoring
    ///
    final override int add(int fd, AppEvent.Type event, EventHandler* handler) {
        int rc;
        kevent_t e;
        e.ident = fd;
        e.filter = appEventToSysEvent(event);
        e.flags = EV_ADD;
        e.udata = cast(void*)handler;
        if ( in_index == MAXEVENTS ) {
            // flush
            rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
            debug if ( rc == -1 ) {
                error("error adding handler: %s", fromStringz(strerror(errno)));
            }
            in_index = 0;
        } else {
            in_events[in_index++] = e;
            rc = 0;
        }
        return rc;
    }
    final override void timer(Timer t) {
        enforce(timer_fd >= 0, "Timer file is not opened ");
        intptr_t delay_ms = (t.expires - Clock.currTime).split!"msecs".msecs;
        int rc;
        kevent_t e;
        e.ident = timer_fd;
        e.filter = EVFILT_TIMER;
        e.flags = EV_ADD;
        e.flags |= EV_ONESHOT;
        e.data = delay_ms;
        e.udata = cast(void*)t.id;
        if ( in_index == MAXEVENTS ) {
            // flush
            rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
            debug if ( rc == -1 ) {
                error("error adding handler: %s", fromStringz(strerror(errno)));
            }
            in_index = 0;
        } else {
            in_events[in_index++] = e;
            rc = 0;
        }
    }
}
auto appEventToSysEvent(AppEvent.Type ae) {
    import core.bitop;
    assert( popcnt(ae) == 1, "Set one event at a time");
    assert( ae <= AppEvent.CONN, "You can ask for IN,OUT,CONN events");
    final switch ( ae ) {
        case AppEvent.IN:
            return EVFILT_READ;
        case AppEvent.OUT:
            return EVFILT_WRITE;
        case AppEvent.CONN:
            return EVFILT_READ;
    }
}
AppEvent.Type sysEventToAppEvent(short se) {
    final switch ( se ) {
        case EVFILT_READ:
            return AppEvent.IN;
        case EVFILT_WRITE:
            return AppEvent.OUT;
        // default:
        //     throw new Exception("Unexpected event %d".format(se));
    }
}
unittest {
    import std.exception;
    import core.exception;

    assert(appEventToSysEvent(AppEvent.IN)==EVFILT_READ);
    assert(appEventToSysEvent(AppEvent.OUT)==EVFILT_WRITE);
    assert(appEventToSysEvent(AppEvent.CONN)==EVFILT_READ);
    assertThrown!AssertError(appEventToSysEvent(AppEvent.IN | AppEvent.OUT));
    assert(sysEventToAppEvent(EVFILT_READ) == AppEvent.IN);
    assert(sysEventToAppEvent(EVFILT_WRITE) == AppEvent.OUT);
}
