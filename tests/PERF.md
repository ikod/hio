cpufreq-set -g performance
analyzing CPU 0:
  driver: intel_pstate
  CPUs which run at the same hardware frequency: 0
  CPUs which need to have their frequency coordinated by software: 0
  maximum transition latency: 4294.55 ms.
  hardware limits: 400 MHz - 4.60 GHz
  available cpufreq governors: performance, powersave
  current policy: frequency should be within 400 MHz and 4.60 GHz.
                  The governor "performance" may decide which speed to use
                  within this range.
  current CPU frequency is 4.26 GHz.

nginx
$ sudo nice -n -10 ./wrk -d 30 -c 200 -R 2000 --latency -t4 http://localhost:80/
Running 30s test @ http://localhost:80/
  4 threads and 200 connections
  Thread calibration: mean lat.: 1.043ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.028ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.034ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.042ms, rate sampling interval: 10ms
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.02ms  448.52us   2.78ms   63.51%
    Req/Sec   524.84    177.06     1.00k    73.27%
  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%    1.02ms
 75.000%    1.35ms
 90.000%    1.62ms
 99.000%    2.01ms
 99.900%    2.27ms
 99.990%    2.65ms
 99.999%    2.79ms
100.000%    2.79ms

 --DRT-gcopt="parallel:0"

t4(callbacks)
$ sudo nice -n -10 ./wrk -d 45 -c 200 -R 2000 --latency -t4 http://localhost:12345/
Running 45s test @ http://localhost:12345/
  4 threads and 200 connections
  Thread calibration: mean lat.: 1.032ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.041ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.045ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.012ms, rate sampling interval: 10ms
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     0.92ms  445.61us   2.82ms   64.97%
    Req/Sec   523.75    192.62     1.11k    71.48%
  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%    0.90ms
 75.000%    1.23ms
 90.000%    1.50ms
 99.000%    2.01ms
 99.900%    2.24ms
 99.990%    2.46ms
 99.999%    2.82ms
100.000%    2.83ms



t3(tasks)
sudo nice -n -10 ./wrk -d 45 -c 200 -R 2000 --latency -t4 http://localhost:12345/
Running 45s test @ http://localhost:12345/
  4 threads and 200 connections
  Thread calibration: mean lat.: 0.965ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.040ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.032ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.046ms, rate sampling interval: 10ms
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     0.92ms  442.18us   3.81ms   64.76%
    Req/Sec   524.62    205.22     1.33k    70.85%
  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%    0.92ms
 75.000%    1.24ms
 90.000%    1.50ms
 99.000%    1.95ms
 99.900%    2.37ms
 99.990%    3.08ms
 99.999%    3.38ms
100.000%    3.82ms

