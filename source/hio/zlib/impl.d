module hio.zlib.impl;

import std.experimental.logger;
import std.string;
import std.stdio;
import std.algorithm;
import std.typecons;

import etc.c.zlib;

import nbuff: Nbuff, NbuffChunk, MutableNbuffChunk;


enum OBUFFSZ = 16*1024;

alias zInflateResult = Tuple!(ulong, "consumed", NbuffChunk, "result", int, "status");

struct ZLib
{
    private
    {
        z_stream          _zstr;
        uint              _obufsz = 16*1024;
        MutableNbuffChunk _outBuff;
        int               _state = Z_OK;
    }

    void zInit(uint obufsz)
    {
        immutable r = inflateInit2(&_zstr, 15+32); // allow autodetect
        assert(r == Z_OK);
        _obufsz = obufsz;
        _outBuff = Nbuff.get(_obufsz);
        _zstr.next_out = &_outBuff.data.ptr[0];
        _zstr.avail_out = _obufsz;
        _state = Z_OK;
    }

    zInflateResult zInflate(NbuffChunk b)
    {
        // process data in b
        // after call to inflate we can have
        // 0) avail_in =  0 - everything processed (input empty)
        //    avail_out>= 0 - 
        //
        // 1) avail_in >   0 - something consumed but...
        //    avail_out == 0 - no space in out buffer
        //
        // 2) 
        // avail_in == 0
        // avail_out > 0
        if (_state != Z_OK)
        {
            return zInflateResult(0, NbuffChunk(), _state);
        }
        _zstr.next_in = &b.data[0];
        _zstr.avail_in = cast(int)b.length;
        int rc = inflate(&_zstr, 0);
        switch(rc)
        {
            case Z_OK, Z_STREAM_END, Z_STREAM_ERROR, Z_DATA_ERROR:
                _state = rc;
                break;
            default:
                break;
        }
        // writefln("r=%d, avail_in=%d, avail_out=%d", rc, _zstr.avail_in, _zstr.avail_out);
        // writefln("in progress = %d", b.length - _zstr.avail_in);
        // writefln("out space = %d", _zstr.avail_out);
        // writefln("data=%s", cast(string)_outBuff.data[0.._obufsz-_zstr.avail_out]);
        if ( _zstr.avail_out == 0 || rc == Z_STREAM_END)
        {
            auto res = zInflateResult(
                b.length - _zstr.avail_in,
                NbuffChunk(_outBuff, min(_obufsz - _zstr.avail_out, _obufsz)),
                rc);
            _outBuff = Nbuff.get(_obufsz);
            _zstr.avail_out = _obufsz;
            _zstr.next_out = &_outBuff.data.ptr[0];
            return res;
        }
        else
        {
            return zInflateResult(b.length - _zstr.avail_in, NbuffChunk(), rc);
        }
    }

    void zFlush()
    {
        inflateEnd(&_zstr);
    }
}


unittest
{
    import std.range;
    info("testing zlib");
    immutable(ubyte)[] hello =
    [
        0x1f, 0x8b, 0x08, 0x00, 0x94, 0x82, 0xc1, 0x5e, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xe7,
        0x02, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00, 0x00, 0x00
    ];
    NbuffChunk b = NbuffChunk(hello);
    ZLib zlib;
    zlib.zInit(4);
    int processed;
    while(processed<b.length)
    {
        auto r = zlib.zInflate(b[processed..$]);
        processed += r.consumed;
    }
    zlib.zFlush();

    immutable(ubyte)[] compressed =
    [
        0x1F,0x8B,0x08,0x00, 0xF0,0xFD,0xC2,0x5E, 0x00,0x03,0x4B,0x4C, 0x4A,0x4E,0x49,0x4D,
        0x4B,0xCF,0xC8,0xCC, 0xCA,0xCE,0xC9,0xCD, 0xCB,0x2F,0x28,0x2C, 0x2A,0x2E,0x29,0x2D,
        0x2B,0xAF,0xA8,0xAC, 0xE2,0x72,0x74,0x72, 0x76,0x71,0x75,0x73, 0xF7,0xF0,0xF4,0xF2,
        0xF6,0xF1,0xF5,0xF3, 0x0F,0x08,0x0C,0x0A, 0x0E,0x09,0x0D,0x0B, 0x8F,0x88,0x8C,0xE2,
        0x4A,0xA4,0xA3,0x2E, 0x00,0x94,0xA7,0x42, 0x7C,0xA2,0x00,0x00, 0x00,
        0xff,0xff,0xff // this is 3 garbage bytes
    ];



    for(int s=1; s<=1024; s++)
    for(int c=1; c<=64;   c++)
    {
        Nbuff uncompressed;
        zlib.zInit(s);
        foreach(chunk; chunks(compressed, c))
        {
            processed = 0;
            b = NbuffChunk(chunk);
            while(processed<b.length)
            {
                auto r = zlib.zInflate(b[processed..$]);
                processed += r.consumed;
                if (r.result.length)
                {
                    uncompressed.append(r.result);
                }
                if (r.status == Z_STREAM_END)
                {
                    break;
                }
            }
        }
        zlib.zFlush();
        assert(uncompressed.data.data ==
            "abcdefghijklmnopqrstuvwxyz\nABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n" ~
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\nABCDEFGHIJKLMNOPQRSTUVWXYZ\n");
        //writefln("ok for %d/%d", s, c);
    }
    info("ok");
}