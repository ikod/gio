module gio.socket;

import std.socket;
import std.datetime;


import gio;

class gioTCPSocket: IStreamTransport!Address {
    TcpSocket  s;

    this() {
        s = new TcpSocket();
        s.blocking = false;
    }
    ConnectResult connect(Address addr, Duration timeout) {
        EventHandler on_send = EventHandler(
            getEventLoop(),
            s.handle,
            (
                AppEvent.OUT|
                AppEvent.CONN|
                AppEvent.ERR|
                AppEvent.HUP|
                AppEvent.TMO
            )
         );
        return ConnectResult.init;
    }
}

unittest {
    import std.experimental.logger;
    import std.socket;
    import gio;

    info("testing sockets");
    run_until_complete({
        auto sock = new gioTCPSocket();
    });
}