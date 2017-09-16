module gio.task;

import std.typecons;
import std.exception;
import core.thread;
import std.experimental.logger;
import std.traits;
import std.algorithm;
import std.functional;
import gio.loop;

alias emptyFunction = function void () {};

class Task(F, A...) : Fiber if (isCallable!F && is(ReturnType!F == void)) {

    alias run = call;
    enum State {INIT, RUN, DONE};

    private {
        F       _f;
        A       _args;
        Fiber   _joining;
        State   _state = State.INIT;
    }
    private void run() {
        _state = State.RUN;
        try {
            _f(_args);
        } catch (Exception e) {
            error("Uncought exception in task function");
        }
        _state = State.DONE;
        if ( _joining ) {
            Fiber cb = _joining;
            _joining = null;
            cb.call();
        }
    }
    this(F f, A args) {
        _f = f;
        _args = args;
        super(&run);
    }
    @property running() const {
        return _state != State.DONE;
    }
    void interrupt() {
        return;
    }
}

auto task(F)(F f) {
    return new Task!F(f);
}

auto task(F, A...)(F f, A args) {
    return new Task!(F, A)(f, args);
}
void join(T)(T task) {
    enforce(task._joining is null);
    while (task._state != T.State.DONE) {
        task._joining = Fiber.getThis();
        Fiber.yield();
    }
}

class InvalidStateError: Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

class CancelledError: Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

class Future(V) {
    alias onSuccessType = void delegate();
    alias onFailType = void delegate();
    alias onCompleteType = void delegate(typeof(this));
    alias Tasktype = Task!(void delegate());
    alias Valuetype = V;

    private {
        V                   _value;
        bool                _ready = false;
        bool                _cancelled = false;
        Exception           _exception = null;
        onCompleteType[]    _done_callbacks;
        Tasktype            _task;
    }

    void _schedule_callbacks() {
        foreach(ref cb; _done_callbacks) {
            cb(this);
            //call_soon(cb, this); // TODO
        }
    }
    /**
     +   “set_result(result)
     +   Mark the future done and set its result.
     +
     +   If the future is already done when this method is called, raises InvalidStateError.”
     +
     +   Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
     **/
    void set_result(V v){
        if ( done() ) {
            throw new InvalidStateError("try to set_result on already done Future");
        }
        _value = v;
        _ready = true;
        _schedule_callbacks();
    }
    /**
     +   “result()
     +   Return the result this future represents.
     +
     +   If the future has been cancelled, raises CancelledError.
     +   If the future’s result isn’t yet available, raises InvalidStateError.
     +   If the future is done and has an exception set, this exception is raised.”
     +
     +   Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
     **/
    V result() {
        if ( _cancelled ) {
            throw new CancelledError("get result from cancelled Future");
        }
        if ( ! _ready ) {
            throw new InvalidStateError("get result from not ready Future");
        }
        if ( _exception ) {
            throw _exception;
        }
        return _value;
    }
    /**
        “done()
        Return True if the future is done.

        Done means either that a result / exception are available, or that the future was cancelled.”

        Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
    **/
    bool done() const pure nothrow @nogc{
        return _ready || _exception || _cancelled;
    }
    /**
        “cancel()
        Cancel the future and schedule callbacks.

        If the future is already done or cancelled, return False.
        Otherwise, change the future’s state to cancelled, schedule the callbacks and return True.”

        Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
    */
    bool cancel() {
        if ( done() ) {
            return false;
        }
        if ( _task && _task.running ) {
            _task.interrupt();
        }
        _cancelled = true;
        _schedule_callbacks();
        return true;
    }
    bool cancelled() const pure nothrow @nogc @safe {
        return _cancelled;
    }
    /**
        “Add a callback to be run when the future becomes done.

        The callback is called with a single argument - the future object.
        If the future is already done when this is called, the callback is scheduled with call_soon().”

        Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
    */
    void add_done_callback(onCompleteType fn) {
        if ( done() ) {
            // todo call_soon(fn)
            fn(this);
        } else {
            _done_callbacks ~= fn;
        }
    }
    /**
        “remove_done_callback(fn)
        Remove all instances of a callback from the “call when done” list.

        Returns the number of callbacks removed.”

        Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
    */
    size_t remove_done_callback(onCompleteType fn) {
        auto length_before = _done_callbacks.length;
        _done_callbacks = _done_callbacks.remove!((a) => fn == a);
        return length_before - _done_callbacks.length;
    }
    /**
        “exception()
        Return the exception that was set on this future.

        The exception (or None if no exception was set) is returned only if the future is done.
        If the future has been cancelled, raises CancelledError. If the future isn’t done yet, raises InvalidStateError.”

        Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
     */
    Exception exception() {
        if ( _cancelled ) {
            throw new CancelledError("Called exception() on cancelled Future");
        }
        if ( _ready || _exception ) {
            return _exception;
        }
        throw new InvalidStateError("exception called on not done Future");
    }
    /**
        “set_exception(exception)
        Mark the future done and set an exception.

        If the future is already done when this method is called, raises InvalidStateError.”

        Excerpt From: Python Documentation Authors. “Python 3.5.4 documentation.” iBooks.
     */
     void set_exception(Exception e) {
        if ( done() ) {
            throw new InvalidStateError("Called set_exception on done future");
        }
        _exception = e;
     }
     auto await() {
        if ( _task.running() ) {
            _task.join();
        }
        return result();
     }
}

F.Valuetype await(F)(F f) {
    return f.await();
}

auto await_any(F...)(F fs) {
    static foreach(f; fs) {
        f.add_done_callback();
    }
}

auto async(F, A...)(F f, A a) if (isCallable!f) {
    auto future = new Future!(ReturnType!f);
    future._task = task({
        try {
            auto v = f(a);
            future.set_result(v);
        } catch(Exception e) {
            future.set_exception(e);
        }
    });
    future._task.call();
    return future;
}

