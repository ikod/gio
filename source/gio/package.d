module gio;

import std.experimental.logger;
import core.stdc.stdint : intptr_t, uintptr_t;

public import  gio.loop;

private static EventLoop evl;

static this() {
	version(OSX) {
		import gio.osx;
		evl.impl = new OSXEventLoopImpl();
	}
	version(linux) {
		import gio.epoll;
		evl.impl = new EpollEventLoopImpl();
	}
	if ( evl.impl is null ) {
		warning("WARNING: You are using fallback 'select' asyncio driver.");
		import gio.select;
		evl.impl = new SelEventLoopImpl();
	}
}

auto eventLoop() {
	return evl;
}

auto runEventLoop() {
	evl.impl.run();
}

auto stopEventLoop() {
	if ( evl.impl ) {
		evl.impl.stop();
	}
}



unittest {
	import std.exception;
	import core.exception;
	import std.stdio;
	import std.experimental.logger;
	
	globalLogLevel(LogLevel.info);
	info("Testing best available event loop");
	auto evl = eventLoop();
	{
		import std.process;
		import std.format;
		import std.algorithm;

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
	}
}
