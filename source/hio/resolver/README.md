# This is c-ares binding for internal async resolver

## Features ##

* INET4 and INET6 resolving
* you can use single hio_gethostbyname/hio_gethostbyname6 for resolving 
  * without event loop
  * with event loop in the task context
  * with event loop using callbacks
* No exceptions, you get return code and array of addresses

### Code samples: ###

#### No event loop: ####
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "test"
    lflags "-lcares"
    dependency "hio" version="~>0"
+/
import std;
import hio.resolver;

void main()
{
    auto r = hio_gethostbyname("dlang.org");
    assert(r.status == ARES_SUCCESS);
    writefln("resolving status: %s", resolver_errno(r.status));
    writefln("resolved addresses:% s", r.addresses);
}
```

#### In task context ####
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "test"
    lflags "-lcares"
    dependency "hio" version="~>0"
+/
import std;
import hio.scheduler;
import hio.resolver;

void main()
{
    App({
        auto r = hio_gethostbyname("dlang.org");
        assert(r.status == ARES_SUCCESS);
        writefln("resolving status: %s", resolver_errno(r.status));
        writefln("resolved addresses:% s", r.addresses);
    });
}
```

#### With callbacks ####
##### also demonstrate INET6, port and timeout #####
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "test"
    lflags "-lcares"
    dependency "hio" version="~>0"
+/
import std;
import hio.loop;
import hio.resolver;

void main()
{
    void resolve(ResolverResult6 r)
    {
        assert(r.status == ARES_SUCCESS);
        writefln("resolving status: %s", resolver_errno(r.status));
        writefln("resolved addresses:% s", r.addresses);
        getDefaultLoop().stop();
    }
    hio_gethostbyname6("dlang.org", &resolve, 80, 1.seconds);
    getDefaultLoop().run(5.seconds);
}
```