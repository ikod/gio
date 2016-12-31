module gio.select;

import std.datetime;
import std.algorithm;
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

	EventHandler*[EvTuple]  reads;
	EventHandler*[EvTuple]  writes;
	EventHandler*[EvTuple]  errs;
	fd_set					read_fds;
	fd_set					write_fds;
	fd_set					err_fds;

	bool                    running;

	override final void run(Duration d=1.seconds){
		running = true;
		while( running ) {
			FD_ZERO(&read_fds);
			FD_ZERO(&write_fds);
			FD_ZERO(&err_fds);
			int fdmax;
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
			auto ready = select(fdmax+1, &read_fds, &write_fds, null, null);
			debug tracef("select returned %d", ready);
			if ( ready == 0 ) {
				debug trace("select timed out");
				continue;
			}
			if ( ready == -1 ) {
				errorf("select returend error: %s", fromStringz(strerror(errno)));
				continue;
			}
			foreach(int fd; 0..fdmax+1) {
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
}

unittest {
	globalLogLevel(LogLevel.info);
	info("Testing fallback(select) eventloop");
	auto evl = EventLoop();
	evl.impl = new SelEventLoopImpl();
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