module gio.socket;

import std.socket;

import gio.transports;

class gioTCPSocket: IStreamTransport!Address {
    ConnectResult connect(Address addr) {
        return ConnectResult.init;
    }
}