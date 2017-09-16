module gio.drivers.epoll;

import gio.loop;

version(linux):

import std.experimental.logger;

static this() {
    globalLogLevel(LogLevel.info);
}

import std.datetime;
import std.exception;
import std.typecons;
import core.sys.linux.epoll;
import core.sys.linux.timerfd;
import core.sys.posix.unistd: close, read;
import core.sys.posix.time : itimerspec, CLOCK_REALTIME, timespec;

pragma(msg, "Building linux event loop driver");

class EpollEventLoopImpl: EventLoopImpl {

    enum MAXEVENTS = 1024;
    bool running;

    int             epoll_fd;
    int             timer_fd;
    Nullable!ulong  timer_id;

    align(1) epoll_event[MAXEVENTS] events;

    this() {
        epoll_fd = timer_fd = -1;
        init();
    }
    final override void init() {
        if ( epoll_fd == -1 ) {
            epoll_fd = epoll_create(MAXEVENTS);
        }
        if ( timer_fd == -1 ) {
            timer_fd = timerfd_create(CLOCK_REALTIME, 0);
        }
    }
    final override void deinit() {
        close(epoll_fd);
        epoll_fd = -1;
        close(timer_fd);
        timer_fd = -1;
    }
    final override void run(Duration d=1.seconds){
        running = true;
        uint timeout_ms = cast(int)d.total!"msecs";
        while( running ) {
            uint ready = epoll_wait(epoll_fd, &events[0], MAXEVENTS, timeout_ms);
            if ( ready == 0 ) {
                debug trace("epoll timeout");
                continue;
            }
            if ( ready < 0 ) {
                error("epoll returned error");
                return;
            }
            if ( ready > 0 ) {
                foreach(i; 0..ready) {
                    auto e = events[i];
                    if ( e.data.fd == timer_fd ) {
                        ubyte[8] v;
                        read(timer_fd, &v[0], 8);
                        ulong id = timer_id;
                        timer_id.nullify;
                        timerHandler(id);
                        continue;
                    }
                    EventHandler* h = cast(EventHandler*)e.data.ptr;
                    AppEvent appEvent = AppEvent(sysEventToAppEvent(e.events), -1);
                    h.handler(appEvent);
                }
            }
        }
    };
    final override void stop(){
        running = false;
    };
    final override int add(int fd, AppEvent.Type event, EventHandler* handler){
        epoll_event e;
        e.events = appEventToSysEvent(event);
        e.data.ptr = handler;
        return epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd, &e);
    };
    final override int del(int fd, AppEvent.Type event, EventHandler* handler){
        epoll_event e;
        e.events = appEventToSysEvent(event);
        e.data.ptr = handler;
        return epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, &e);
    };
    final override void timer(in ref Timer t) {
        enforce(timer_fd>=0, "Timer file is not opened");
        itimerspec itimer;
        auto d = t.expires - Clock.currTime;
        itimer.it_value.tv_sec = cast(typeof(itimer.it_value.tv_sec)) d.split!("seconds", "nsecs")().seconds;
        itimer.it_value.tv_nsec = cast(typeof(itimer.it_value.tv_nsec)) d.split!("seconds", "nsecs")().nsecs;
        timerfd_settime(timer_fd, 0, &itimer, null);
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = timer_fd;
        timer_id = t.id;
        epoll_ctl(epoll_fd, EPOLL_CTL_ADD, timer_fd, &e);
    }
    auto appEventToSysEvent(AppEvent.Type ae) {
        import core.bitop;
        assert( popcnt(ae) == 1, "Set one event at a time");
        assert( ae <= AppEvent.CONN, "You can ask for IN,OUT,CONN events");
        final switch ( ae ) {
            case AppEvent.IN:
                return EPOLLIN;
            case AppEvent.OUT:
                return EPOLLOUT;
        }
    }
    AppEvent.Type sysEventToAppEvent(uint se) {
        final switch ( se ) {
            case EPOLLIN:
                return AppEvent.IN;
            case EPOLLOUT:
                return AppEvent.OUT;
        }
    }
}
