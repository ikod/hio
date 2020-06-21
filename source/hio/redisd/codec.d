///
module redisd.codec;

import std.string;
import std.algorithm;
import std.stdio;
import std.conv;
import std.exception;
import std.format;
import std.typecons;
import std.traits;
import std.array;
import std.range;

import std.experimental.logger;

import nbuff;

/// Type of redis value
enum ValueType : ubyte {
    Incomplete = 0,
    Null,
    Integer = ':',
    String = '+',
    BulkString = '$',
    List = '*',
    Error = '-',
}
///
class BadDataFormat : Exception {
    this(string msg, string f = __FILE__, ulong l = __LINE__) @safe {
        super(msg, f, l);
    }
}
///
class EncodeException : Exception {
    this(string msg, string f = __FILE__, ulong l = __LINE__) @safe {
        super(msg, f, l);
    }
}
///
class WrongOffset : Exception {
    this(string msg, string f = __FILE__, ulong l = __LINE__) @safe {
        super(msg, f, l);
    }
}
///
class WrongDataAccess : Exception {
    this(string msg, string f = __FILE__, ulong l = __LINE__) @safe {
        super(msg, f, l);
    }
}

struct RedisdValue {
    private {
        ValueType       _type;
        string          _svar;
        long            _ivar;
        RedisdValue[]    _list;
    }
    /// get type of value
    ValueType type() @safe const {
        return _type;
    }
    /// if this is nil value
    bool empty() const {
        return _type == ValueType.Null;
    }
    /// get string value
    string svar() @safe const {
        switch (_type) {
        case ValueType.String, ValueType.BulkString, ValueType.Error:
            return _svar;
        default:
            throw new WrongDataAccess("You can't use svar for non-string value");
        }
    }
    /// get integer value
    auto ivar() @safe const {
        switch (_type) {
        case ValueType.Integer:
            return _ivar;
        default:
            throw new WrongDataAccess("You can't use ivar for non-integer value");
        }
    }

    void opAssign(long v) @safe {
        _type = ValueType.Integer;
        _ivar = v;
        _svar = string.init;
        _list = RedisdValue[].init;
    }

    void opAssign(string v) @safe {
        _type = ValueType.String;
        _svar = v;
        _ivar = long.init;
        _list = RedisdValue[].init;
    }

    string toString() {
        switch(_type) {
        case ValueType.Incomplete:
            return "<Incomplete>";
        case ValueType.String:
            return "\"%s\"".format(_svar);
        case ValueType.Error:
            return "<%s>".format(_svar);
        case ValueType.Integer:
            return "%d".format(_ivar);
        case ValueType.BulkString:
            return "'%s'".format(_svar);
        case ValueType.List:
            return "[%(%s,%)]".format(_list);
        case ValueType.Null:
            return "(nil)";
        default:
            return "unknown type " ~ to!string(_type);
        }
    }
}

/// Build redis value from string or integer
RedisdValue redisdValue(T)(T v)
if (isSomeString!T || isIntegral!T) {
    RedisdValue _v;
    static if (isIntegral!T) {
        _v._type = ValueType.Integer;
        _v._ivar = v;
    } else
    static if (isSomeString!T) {
        _v._type = ValueType.BulkString;
        _v._svar = v;
    } else {
        static assert(0, T.stringof);
    }
    return _v;
}

/// Build redis value from tuple
RedisdValue redisdValue(T)(T v) if (isTuple!T) {
    RedisdValue _v;
    _v._type = ValueType.List;
    RedisdValue[] l;
    foreach (element; v) {
        l ~= redisdValue(element);
    }
    _v._list = l;
    return _v;
}

/// Build redis value from array
RedisdValue redisdValue(T:U[], U)(T v)
if (isArray!T && !isSomeString!T) {
    RedisdValue _v;
    _v._type = ValueType.List;
    RedisdValue[] l;
    foreach (element; v) {
        l ~= redisdValue(element);
    }
    _v._list = l;
    return _v;
}
/// serialize RedisdValue to byte array
immutable(ubyte)[] encode(RedisdValue v) @safe {
    string encoded;
    switch(v._type) {
    case ValueType.Error:
        encoded.reserve(1 + v._svar.length + 2);
        encoded ~= "-";
        encoded ~= v._svar;
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.String:
        encoded.reserve(1+v._svar.length+2);
        encoded ~= "+";
        encoded ~= v._svar;
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.Integer:
        encoded.reserve(15);
        encoded ~= ":";
        encoded ~= to!string(v._ivar);
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.BulkString:
        encoded.reserve(v._svar.length+1+20+2+2);
        encoded ~= "$";
        encoded ~= to!string(v._svar.length);
        encoded ~= "\r\n";
        encoded ~= to!string(v._svar);
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.List:
        Appender!(immutable(ubyte)[]) appender;
        appender.put(("*" ~ to!string(v._list.length) ~ "\r\n").representation);
        foreach(element; v._list) {
            appender.put(element.encode);
        }
        return cast(immutable(ubyte)[])appender.data;
    default:
        throw new EncodeException("Failed to encode");
    }
}

///
@safe unittest {
    RedisdValue v;
    v = "abc";
    assert(encode(v) == "+abc\r\n".representation);
    v = -1234567890;
    assert(encode(v) == ":-1234567890\r\n".representation);
    v = -0;
    assert(encode(v) == ":0\r\n".representation);

    v = -1234567890;
    assert(v.encode.decode.value == v);
    v = redisdValue("abc");
    assert(v.encode.decode.value == v);
    v = redisdValue([1,2]);
    assert(v.encode.decode.value == v);
    v = redisdValue(tuple("abc", 1));
    assert(v.encode.decode.value == v);
}

alias DecodeResult = Tuple!(RedisdValue, "value", immutable(ubyte)[], "rest");

/// deserialize from byte array
DecodeResult decode(immutable(ubyte)[] data) @safe {
    assert(data.length >= 1);
    RedisdValue v;
    switch(data[0]) {
    case '+':
        // simple string
        v._type = ValueType.String;
        auto s = data[1..$].findSplit([13,10]);
        v._svar = cast(string)s[0];
        return DecodeResult(v, s[2]);
    case '-':
        // error
        v._type = ValueType.Error;
        auto s = data[1 .. $].findSplit([13, 10]);
        v._svar = cast(string) s[0];
        return DecodeResult(v, s[2]);
    case ':':
        // integer
        v._type = ValueType.Integer;
        auto s = data[1 .. $].findSplit([13, 10]);
        v._ivar = to!long(cast(string)s[0]);
        return DecodeResult(v, s[2]);
    case '$':
        // bulk string
        // skip $, then try to split on first \r\n:
        // s now: [length],[\r\n],[data\r\n]
        v._type = ValueType.BulkString;
        auto s = data[1..$].findSplit([13, 10]);
        if (s[1].length != 2) {
            throw new BadDataFormat("bad data: [%(%02.2#x,%)]".format(data));
        }
        auto len = to!long(cast(string)s[0]);
        if ( s[2].length < len + 2 ) {
            throw new BadDataFormat("bad data: [%(%02.2#x,%)]".format(data));
        }
        v._svar = cast(string)s[2][0..len];
        return DecodeResult(v, s[2][len+2..$]);
    case '*':
        // list
        v._type = ValueType.List;
        auto s = data[1 .. $].findSplit([13, 10]);
        if (s[1].length != 2) {
            throw new BadDataFormat("bad data: [%(%02.2#x,%)]".format(data));
        }
        auto len = to!long(cast(string) s[0]);
        if ( len == 0 ) {
            return DecodeResult(v, s[2]);
        }
        if ( len == -1 ){
            v._type = ValueType.Null;
            return DecodeResult(v, s[2]);
        }
        auto rest = s[2];
        RedisdValue[] array;

        while(len>0) {
            auto d = decode(rest);
            auto v0 = d.value;
            array ~= v0;
            rest = d.rest;
            len--;
        }
        v._list = array;
        return DecodeResult(v, rest);
    default:
        break;
    }
    assert(0);
}

@safe unittest {
    RedisdValue v;
    v = "a";
    v = 1;
}
///
@safe unittest {
    DecodeResult d;
    d = decode("+OK\r\n ".representation);
    auto v = d.value;
    auto r = d.rest;

    assert(v._type == ValueType.String);
    assert(v._svar == "OK");
    assert(r == " ".representation);

    d = decode("-ERROR\r\ngarbage\r\n".representation);
    v = d.value;
    r = d.rest;
    assert(v._type == ValueType.Error);
    assert(v._svar == "ERROR");
    assert(r == "garbage\r\n".representation);

    d = decode(":100\r\n".representation);
    v = d.value;
    r = d.rest;
    assert(v._type == ValueType.Integer);
    assert(v._ivar == 100);
    assert(r == "".representation);

    d = decode("$8\r\nfoobar\r\n\r\n:41\r\n".representation);
    v = d.value;
    r = d.rest;
    assert(v._svar == "foobar\r\n", format("<%s>", v._svar));
    assert(r ==  ":41\r\n".representation);
    assert(v._type == ValueType.BulkString);

    d = decode("*3\r\n:1\r\n:2\r\n$6\r\nfoobar\r\nxyz".representation);
    v = d.value;
    r = d.rest;
    assert(v._type == ValueType.List);
    assert(r == "xyz".representation);
}

/// decode redis values from stream of ubyte chunks
class Decoder {
    enum State {
        Init,
        Type,
    }
    private {
        Nbuff           _chunks;
        State           _state;
        ValueType       _frontChunkType;
        size_t          _parsedPosition;
        size_t          _list_len;
        RedisdValue[]   _list;
    }
    /// put next data chunk to decoder
    bool put(NbuffChunk chunk) @safe {
        assert(chunk.length > 0, "Chunk must not be emplty");
        if ( _chunks.length == 0 ) {
            switch( chunk[0]) {
            case '+','-',':','*','$':
                _frontChunkType = cast(ValueType)chunk[0];
                debug(redisd) tracef("new chunk type %s", _frontChunkType);
                break;
            default:
                throw new BadDataFormat("on chunk" ~ to!string(chunk));
            }
        }
        _chunks.append(chunk);
        //_len += chunk.length;
        return false;
    }

    private RedisdValue _handleListElement(RedisdValue v) @safe {
        // we processing list element
        () @trusted {debug(redisd) tracef("appending %s to list", v);} ();
        _list ~= v;
        _list_len--;
        if (_list_len == 0) {
            RedisdValue result = {_type:ValueType.List, _list : _list};
            _list.length = 0;
            return result;
        }
        return RedisdValue();
    }
    /// try to fetch decoded value from decoder.
    /// Return next value or value of type $(B Incomplete).
    RedisdValue get() @safe {
        RedisdValue v;
    // debug(redisd)writefln("on entry:\n◇\n%s\n◆", _chunks.dump());
    start:
        if (_chunks.length == 0 ) {
            return v;
        }
        // Flat f = Flat(_chunks);
        // Flat[] s;
        debug(redisd) tracef("check var type '%c'", cast(char)_chunks[0]);
        switch (_chunks[0]) {
        case ':':
            auto s = _chunks.findSplitOn(['\r', '\n']);
            //debug(redisd) tracef("check var type %s", s[0].data.asString!(s=>s));
            if ( s[1].length ) {
                v = to!long(s[0].data[1..$].toString);
                _chunks = s[2];
                // debug(redisd)writefln("after:\n%s\n", _chunks.dump());
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len)
                        goto start;
                }
                debug(redisd) tracef("value: %s", v);
                return v;
            }
            break;
        case '+':
            auto s = _chunks.findSplitOn(['\r', '\n']);
            if ( s[1].length ) {
                v = s[0].data[1 .. $].toString;
                _chunks = s[2];
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len)
                        goto start;
                }
                return v;
            }
            break;
        case '-':
            auto s = _chunks.findSplitOn(['\r', '\n']);
            if ( s[1].length ) {
                v._type = ValueType.Error;
                v._svar = s[0].data[1 .. $].toString;
                _chunks = s[2];
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len)
                        goto start;
                }
                return v;
            }
            break;
        case '$':
            auto s = _chunks.findSplitOn(['\r', '\n']);
            if ( s[1].length ) {
                long len = (s[0].data[1..$].toString.to!long);
                if ( len == -1 ) {
                    v._type = ValueType.Null;
                    _chunks = s[2];
                    if (_list_len > 0) {
                        v = _handleListElement(v);
                        if (_list_len)
                            goto start;
                    }
                    return v;
                }
                if (s[2].length < len + 2) {
                    return v;
                }
                string data = s[2][0..len].toString;
                v = data;
                _chunks = s[2][data.length+2..s[2].length];
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len) goto start;
                }
            }
            break;
        case '*':
            _list_len = -1;
            auto s = _chunks.findSplitOn(['\r', '\n']);
            if ( s[1].length ) {
                long len = s[0].data[1 .. $].toString.to!long;
                _list_len = len;
                _chunks = s[2];
                if (len == 0) {
                    v._type = ValueType.Null;
                    return v;
                }
                debug (redisd)
                    tracef("list of length %d detected", _list_len);
                goto start;            
            }
            break;
        default:
            break;
        }
        return v;
    }
}
///
@safe unittest {
    globalLogLevel = LogLevel.trace;
    RedisdValue str = {_type:ValueType.String, _svar : "abc"};
    RedisdValue err = {_type:ValueType.Error, _svar : "err"};
    immutable(ubyte)[] b = redisdValue(1001).encode 
            ~ redisdValue(1002).encode
            ~ str.encode
            ~ err.encode
            ~ redisdValue("\r\nBulkString\r\n").encode
            ~ redisdValue(1002).encode
            ~ redisdValue([1,2,3]).encode
            ~ redisdValue(["abc", "def"]).encode
            ~ redisdValue(1002).encode;

    foreach(chunkSize; 1..b.length) {
        auto s = new Decoder();
        foreach (c; b.chunks(chunkSize)) {
            s.put(NbuffChunk(c));
        }
        auto v = s.get();
        assert(v._ivar == 1001);

        v = s.get();
        assert(v._ivar == 1002);

        v = s.get();
        assert(v._svar == "abc");

        v = s.get();
        assert(v._svar == "err");

        v = s.get();
        assert(v._svar == "\r\nBulkString\r\n");
        v = s.get();
        debug(redisd)trace(v);
        assert(v._ivar == 1002);
        int lists_to_get = 2;
        while( lists_to_get>0 ) {
            v = s.get();
            debug(redisd)trace(v);
            debug (redisd)
                () @trusted { tracef("%s: %s, %s", v._type, v, lists_to_get); }();
            if (v._type == ValueType.List) {
                lists_to_get--;
            }
        }
        v = s.get();
        debug(redisd)trace(v);
        assert(v._ivar == 1002);
        v = s.get();
        debug(redisd)trace(v);
        assert(v._type == ValueType.Incomplete);
    }
    info("test ok");
}