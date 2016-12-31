import std.stdio;
import std.experimental.logger;
import gio;

void main()
{
	globalLogLevel(LogLevel.trace);
	info("Started");
	runEventLoop();
}
