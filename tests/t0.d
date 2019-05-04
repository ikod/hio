#!/usr/bin/env dub
/+ dub.sdl:
    name "t0"
    dflags "-I../source"
    dflags "-release"
    lflags "-L.."
    lflags "-lhio"
+/
// cd to tests and run with "dub run --single t0.d"
import hio;

void job()
{

}

void main()
{
}