module gio.buffer;

import std.string:representation;
import std.algorithm;
import std.conv;
import std.range;
import std.stdio;
import std.format;
import core.exception;
import std.exception;
import std.range.primitives;

///
// network buffer
///

// цели
// 1 минимум коприрований данных
// 2 input range штеукасфу
// 3 не держать ненужные данные в памяти
// сценарии использования
// чтение из сокеты во временный буффер, добавление временного буффера к Buffer
// проверили что Buffer содержит нужные данные, разделяет Buffer на части и продолжает рабботу.
//
//               +---B--+
// +---A--+      | data |
// | data |      +------+
// +------+  -> 
// | rest |      +---C--+
// +------+      | rest |
//               +------+
// приём данных продолжаем в Buffer C, для работы с полученными данными используем Buffer B
// 
struct Buffer {
    alias Chunk = immutable(ubyte)[];
    size_t              _length;
    immutable(Chunk)[]  _chunks;
    static struct _range {
        // implement InputRange
        size_t              _pos;
        size_t              _end;
        Buffer              _buffer;
        this(in Buffer b) {
            _buffer = b;
            _pos = 0;
            _end = _buffer.length;
        }
        @property auto ref front() {
            return _buffer[_pos];
        }
        @property void popFront() {
            _pos++;
        }
        @property bool empty() {
            return _pos == _end;
        }
        @property auto save() {
            return this;
        }
        @property size_t length() {
            return _end - _pos;
        }
        auto ref opIndex(size_t i) {
            if ( i >= length ) {
                throw new RangeError();
            }
            return _buffer[_pos + i];
        }
        auto opSlice(size_t m, size_t n) {
            auto another = _buffer[m..n];
            return another.range();
        }
        auto opDollar() const pure @safe {
            return _buffer.length;
        }
        @property auto ref back() {
            return _buffer[_end-1];
        }
        @property auto popBack() {
            _end--;
        }
        auto opCast(T)() if (is(T==immutable(ubyte)[])) {
            return _buffer[_pos.._end].data();
        }
        auto opCast(T)() if (is(T==ubyte[])) {
            return _buffer[_pos.._end].data().dup;
        }
    }
    this(string s) immutable {
        _chunks = [s.representation];
        _length = s.length;
    }
    this(string s) {
        _chunks = [s.representation];
        _length = s.length;
    }
    this(in Buffer other, size_t m, size_t n) {
        ulong i;
        // produce slice view m..n
        if ( n == m ) {
            return;
        }
        _length = n - m;
        n = n - m;
        while( m > other._chunks[i].length ) {
            m -= other._chunks[i].length;
            i++;
        }
        auto to_copy = min(n, other._chunks[i].length - m);
        if ( to_copy > 0 ) {
            _chunks ~= other._chunks[i][m..m+to_copy];
        }
        i++;
        n -= to_copy;
        while(n > 0) {
            to_copy = min(n, other._chunks[i].length);
            _chunks ~= other._chunks[i][0..to_copy];
            n -= to_copy;
            i++;
        }
    }
    this(in Buffer other, size_t m, size_t n) immutable {
        _length = n - m;
        _chunks = other._chunks;
    }
   ~this() {
    }

    auto append(string s) {
        Chunk chunk = s.representation;
        _chunks ~= chunk;
        _length += chunk.length;
    }
    auto append(Chunk s) {
        _chunks ~= s;
        _length += s.length;
    }

    auto length() const {
        return _length;
    }
    auto opDollar() const pure @safe {
        return _length;
    }
    Buffer opSlice(size_t m, size_t n) const {
        if ( this._length==0 || m == n ) {
            return Buffer();
        }
        enforce( m <= n && n <= _length, "Wrong slice parameters: start: %d, end: %d, this.length: %d".format(m, n, _length));
        auto res = Buffer(this, m, n);
        return res;
    }
    auto ref opIndex(size_t n) const pure @safe {
        assert( n < _length );
        foreach(b; _chunks) {
            if ( n < b.length ) {
                return b[n];
            }
            n -= b.length;
        }
        assert(false, "Impossible");
    }

    Chunk data() const {
        if ( _chunks.length == 1 ) {
            return _chunks[0];
        }
        ubyte[] r = new ubyte[this.length];
        uint d = 0;
        foreach(ref c; _chunks) {
            r[d..d+c.length] = c;
            d += c.length;
        }
        return assumeUnique(r);
    }
    _range range() {
        return _range(this);
    }
}

unittest {
    auto b = Buffer();
    b.append("abc");
    b.append("def".representation);
    b.append("123");
    assert(b.length == "abcdef123".length);
    assert(cast(string)b.data() == "abcdef123");
    auto bi = immutable Buffer("abc");
    assert(bi.length == 3);
    assert(cast(string)bi.data() == "abc");
    Buffer c = b;
    assert(cast(string)c.data() == "abcdef123");
    assert(c.length == 9);
    assert(c._chunks.length == 3);
    // update B do not affect C
    b.append("ghi");
    assert(cast(string)c.data() == "abcdef123");
    // test slices
    immutable Buffer di = b[1..5];
    // +di+
    // |bc|
    // |de|
    // +--+
    assert(cast(string)di.data == "bcde");
    b = di[0..2];
    assert(cast(string)b.data, "ab");
    assert(b.length == 2);
    b = di[$-2..$];
    assert(cast(string)b.data == "de");
    assert(b._chunks.length==1);
    assert(b.length == 2);
    b = di[$-1..$];
    assert(cast(string)b.data == "e");
    assert(b._chunks.length==1);
    assert(b.length == 1);
    b = Buffer();
    b.append("abc");
    b.append("def".representation);
    b.append("123");
    // +-b-+
    // |abc|
    // |def|
    // |123|
    // +---+
    assert(b._chunks.length==3);
    c = b[3..$];
    // +-c-+
    // |def|
    // |123|
    // +---+
    assert(c.length == 6);
    assert(c._chunks.length==2);
    assert(c[1] == 'e');
    assert(c[3] == '1');
    assert(c[$-1] == '3');
    static assert(hasLength!(Buffer));


    static assert(isInputRange!(Buffer._range));
    static assert(isForwardRange!(Buffer._range));
    static assert(hasLength!(Buffer._range));
    static assert(hasSlicing!(Buffer._range));
    static assert(isBidirectionalRange!(Buffer._range));
    static assert(isRandomAccessRange!(Buffer._range));
    auto bit = b.range();
    assert(!bit.canFind('4'));
    assert(bit.canFind('1'));
    assert(equal(splitter(bit, 'd').array[0], ['a','b','c']));
    assert(equal(splitter(bit, 'd').array[1], ['e', 'f', '1', '2', '3']));
    assert(bit.length == 9);
    bit.popBack;
    assert(bit.length == 8);
    assertThrown!RangeError(bit[8]);
    assert(equal(bit, ['a', 'b', 'c', 'd', 'e', 'f', '1', '2']));
}