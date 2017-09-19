module gio.drivers.select;

import std.datetime;
import std.algorithm;
import std.array;
import std.format;
import std.typecons;
import std.experimental.logger;
import core.stdc.errno: errno;
import core.stdc.string: strerror;
import std.string: fromStringz;

import gio.loop;

/**
*** This is fallback eventloop driver if no optimal for platform driver found.
*** It should works on almost any platform.
**/

version(Windows) {
    import core.sys.windows.winsock2;
}
version(Posix) {
    import core.sys.posix.sys.select;
}

class SelEventLoopImpl: EventLoopImpl {
    private {
        EventHandler*[EvTuple]  reads;
        EventHandler*[EvTuple]  writes;
        EventHandler*[EvTuple]  errs;
        fd_set                  read_fds;
        fd_set                  write_fds;
        fd_set                  err_fds;
        Timer                   timeout;
        
        bool                    running;
    }
    struct EvTuple {
        int 			fd;
        AppEvent.Type	events;
        size_t toHash() const @safe pure nothrow {
            return fd ^ events;
        }
        bool opEquals(ref const typeof(this) other) const @safe pure nothrow {
            return (fd == other.fd && events == other.events);
        }
    }
    override final void init() {
    }
    override final void deinit() {
        reads = writes = errs = null;
        timeout = null;
    }
    override final void run(Duration d=1.seconds){
        running = true;
        while( running ) {
            FD_ZERO(&read_fds);
            FD_ZERO(&write_fds);
            FD_ZERO(&err_fds);

            int     fdmax;
            timeval timev;

            if ( timeout !is null ) {
                auto now = Clock.currTime();
                auto delta = timeout.expires - now;
                debug tracef("delta = %s, timeout = %s", delta, timeout);
                assert(delta>0.seconds, "Trying to set expired timeout: %s".format(delta));
                auto converted = delta.split!("seconds", "usecs");
                timev.tv_sec  = cast(typeof(timev.tv_sec))converted.seconds;
                timev.tv_usec = cast(typeof(timev.tv_usec))converted.usecs;
            }
            foreach(evt; reads.byKey) {
                debug tracef("select: adding %s to reads", evt);
                FD_SET(evt.fd, &read_fds);
                fdmax = max(fdmax, evt.fd);
            }
            foreach(evt; writes.byKey) {
                debug tracef("select: adding %s to writes", evt);
                FD_SET(evt.fd, &write_fds);
                fdmax = max(fdmax, evt.fd);
            }
            auto ready = select(fdmax+1, &read_fds, &write_fds, null, &timev);
            debug tracef("select returned %d", ready);
            if ( ready == 0 ) {
                debug trace("select timed out");
                if ( timeout !is null ) {
                    auto now = Clock.currTime;
                    debug tracef("timeoutExpires: %s, now: %s", timeout.expires, now);
                    if ( now >= timeout.expires ) {
                        debug trace("calling timer handler");
                        ulong id = timeout.id;
                        timeout = null;
                        timerHandler(id);
                    }
                }
                continue;
            }
            if ( ready == -1 ) {
                errorf("select returend error: %s", fromStringz(strerror(errno)));
                continue;
            }
            foreach(int fd; 0..fdmax+1) {
                if ( !running ) {
                    break;
                }
                if ( FD_ISSET(fd, &write_fds) ) {
                    debug tracef("writing on %d", fd);
                    auto evt = EvTuple(fd, AppEvent.OUT);
                    auto h = writes[evt];
                    auto ev = AppEvent(AppEvent.OUT, -1);
                    h.handler(ev);
                }
                if ( FD_ISSET(fd, &read_fds) ) {
                    debug tracef("reading on %d", fd);
                    auto evt = EvTuple(fd, AppEvent.IN);
                    auto h = reads[evt];
                    auto ev = AppEvent(AppEvent.IN, -1);
                    h.handler(ev);
                }
            }
        }
    };
    override final void stop(){
        running = false;
    };
    override final int add(int fd, AppEvent.Type event, EventHandler* handler){
        debug trace("add event");
        EvTuple evt = {fd, event};
        final switch(event) {
            case AppEvent.IN:
                reads[evt] = handler;
                break;
            case AppEvent.OUT:
                writes[evt] = handler;
                break;
        }
        return 0;
    };
    override final int del(int fd, AppEvent.Type event, EventHandler* handler){
        debug trace("del event");
        EvTuple evt = {fd, event};
        final switch(event) {
            case AppEvent.IN:
                reads.remove(evt);
                break;
            case AppEvent.OUT:
                writes.remove(evt);
                break;
        }
        return 0;
    };
    final override void start_timer(Timer t) {
        debug tracef("Set timer to %s", t.expires);
        timeout = t;
    }
}
