module hio.tls.common;

import std.format;

package string SSL_Function_decl(R, string N, A...)() {
    string F = "extern (C) @nogc nothrow @trusted %s %s%s;".format(R.stringof, N, A.stringof);
    return F;
}

enum SSL_connect_call_result
{
    ERROR,
    CONNECTED,
    WANT_READ,
    WANT_WRITE
}

struct SSLOptions
{
    private
    {
        bool    _verifyPeer = true;
    }
    bool verifyPeer() pure inout @safe @nogc nothrow
    {
        return _verifyPeer;
    }
    void verifyPeer(bool v) pure @safe @nogc nothrow
    {
        _verifyPeer = v;
    }    
}