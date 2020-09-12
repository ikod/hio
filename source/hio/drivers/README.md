## Timers ##

* Using timingwheels
* Adding timer in the past or inside current ticks will trigger callback on the next loop run

## Code sample ##

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "test"
    dependency "hio" version="~>0"
+/
import std;
import hio.events;
import hio.loop;

void main()
{
    int event_no;
    void timer(AppEvent e)
    {
        writefln("Timer fired: %d", event_no);
        event_no++;
        getDefaultLoop().stop();
    }
    Timer t = new Timer(1.seconds, &timer);
    getDefaultLoop().startTimer(t);
    getDefaultLoop().run(3.seconds);
    t.rearm(500.msecs);
    getDefaultLoop().startTimer(t);
    getDefaultLoop().run(3.seconds);
}
```