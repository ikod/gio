module gio.task;

import std.typecons;
import std.exception;
import core.thread;
import std.experimental.logger;
import std.traits;

import gio.loop;

alias emptyFunction = function void () {};

class Task(F, A...) : Fiber {

    alias R = ReturnType!F;
    alias run = call;

    private {
        static if (!is(R == void)) {
            R   _v;
        }
        F   _f;
        A   _args;
    }
    private void run() {
        static if (!is(R==void)) {
            _v = _f(_args);
        }
        else {
            _f(_args);
        }
        yield();
    }
    this(F f, A args) {
        _f = f;
        _args = args;
        super(&run);
    }
}

auto task(F)(F f) {
    return new Task!F(f);
}

auto task(F, A...)(F f, A args) {
    return new Task!(F, A)(f, args);
}

class Future(V) {
    static if ( is(V==void) ) {
        enum notVoid = false;
        alias onSuccessType = void delegate();
        alias onFailType = void delegate(Exception);
        alias onCompleteType = void delegate(Exception);
    }
    else {
        enum notVoid = true;
        alias onSuccessType = void delegate(V);
        alias onFailType = void delegate(Exception);
        alias onCompleteType = void delegate(V, Exception);
    }
    private {
        Exception _fail;
        Fiber     _waitor;
        onSuccessType  onSuccess;
        onFailType     onFail;
        onCompleteType onComplete;
        static if (notVoid) {
            Nullable!V  _value;
        }
        else {
            bool _ready;
        }
    }
    @property bool isReady() {
        static if (notVoid) {
            return !_value.isNull;
        }
        else {
            return _ready;
        }
    }
    @property isFailed() {
        return _fail !is null;
    }
    void _wakeup() {
        if ( _waitor !is null ) {
            trace("wakeup");
            _waitor.call();
        }
    }
    // @property auto value() {
    //     return _value.get();
    // }
    // @property void value(V v) {
    //     _value = v;
    //     _wakeup();
    // }
    void fail(Exception e) {
        enforce(_fail is null, "You can call fail only once");
        _fail = e;
        _wakeup();
    }
    static if ( notVoid ) {
        void set(V v) {
            enforce(_value.isNull, "You can't set value twice");
            tracef("set %s", v);
            _value = v;
            _wakeup();
        }
    }
    else {
        void set() {
            enforce(!_ready, "You can't set value twice");
            tracef("set void");
            _ready = true;
            _wakeup();
        }
    }
    auto get() {
        trace("Enter get");
        while( !isReady && !isFailed ) {
            wait();
        }
        if ( _fail ) {
            trace("Rethrowing from get()");
            throw _fail;
        }
        static if (notVoid) {
            tracef("get - return %s", _value.get());
            return _value.get();
        } else {
            trace("get - return void");
        }
    }
    void wait() {
        if ( isReady ) {
            tracef("Value ready");
            return;
        }
        tracef("Waiting");
        auto thisF = Fiber.getThis();
        enforce(thisF, "You can wait only in task/fiber context");
        tracef("Fiber %s waiting", thisF);
        _waitor = thisF;
        Fiber.yield();
    }
    // auto then(Fn)(Fn f) {
    //     return promise(f, this.get());
    // }
    auto transform(Fn)(Fn f) {
        alias R = ReturnType!Fn;
        auto ft = new Future!R;
        auto applyAndSet = delegate void() {
            static if ( notVoid ) {
                static if ( !is(R==void) ) {
                    ft.set(f(this.get()));
                }
                else {
                    f(this.get());
                    ft.set();
                }
            }
            else {
                static if ( !is(R==void) ) {
                    ft.set(f());
                }
                else {
                    f();
                    ft.set();
                }
            }
        };
        if ( isReady ) {
            try {
                applyAndSet();
            } catch (Exception e) {
                ft.fail(e);
            }
            return ft;
        }
        auto fb = new Fiber(() {
            try {
                applyAndSet();
            } catch (Exception e) {
                ft.fail(e);
            }
        });
        this._waitor = fb;
        return ft;
    }
}

auto promise(F, A...)(F f, lazy A args) {
    alias R = ReturnType!F;
    static if ( is(R==void) ) {
        enum notVoid = false;
    }
    else {
        enum notVoid = true;
    }
    auto ft = new Future!R();
    auto t  = new Fiber( () {
        static if (notVoid) {
            static if (arity!f > 0) {
                ft.set(f(args));
            }
            else {
                ft.set(f());
            }
        }
        else {
            static if (arity!f > 0) {
                f(args);
            }
            else {
                f();
            }
            ft.set();
        }
    }).call();
    return ft;
}

unittest {
    import std.stdio;
    import std.conv;
    globalLogLevel(LogLevel.trace);

    int i;
    auto t0 = task(emptyFunction);
    auto t1 = task(delegate int (scope int x) {
            i++;
            return x+1;
            },
            1);
    t1.call();
    assert(i==1);
    auto p = promise(delegate int (int a, int b) {
        return i+a+b;
    },
    1, 2);
    p.wait();
    assert(p.get == 4);
    globalLogLevel(LogLevel.trace);
    info("test then");
    auto p1 = promise(function int() {
            return 42;
        }).
        transform(function int(int i) {
            trace("set i+1");
            return i+1;
        }).
        transform(function string(int i) {
            trace("set string");
            return to!string(i*2);
        });
    assert(p1.get == "86");
    info("ok");
    // auto p2 = promise(function void () {
    //     return;
    // }).
    // then(function int() {
    //     return 1;
    // }).
    // then(function int(int a){
    //     return a+1;
    // });
    // assert(p2.get == 2);
    // auto p3 = promise(function void() {});
}
