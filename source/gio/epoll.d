module gio.epoll;

import gio.loop;

version(linux):

import std.experimental.logger;

static this() {
    globalLogLevel(LogLevel.info);
}

import std.datetime;
import core.sys.linux.epoll;

pragma(msg, "Building linux event loop driver");

class EpollEventLoopImpl: EventLoopImpl {

    enum MAXEVENTS = 1024;
    bool running;

    int epoll_fd;
    align(1) epoll_event[MAXEVENTS] events;

    this() {
        epoll_fd = epoll_create(MAXEVENTS);
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
    final int add(int fd, AppEvent.Type event, EventHandler* handler){
        epoll_event e;
        e.events = appEventToSysEvent(event);
        e.data.ptr = handler;
        return epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd, &e);
    };
    final int del(int fd, AppEvent.Type event, EventHandler* handler){
        epoll_event e;
        e.events = appEventToSysEvent(event);
        e.data.ptr = handler;
        return epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, &e);
    };
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