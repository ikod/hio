nginx
nice -n -10 ./wrk -d 30 -c 200 -R 2000 --latency -t4 http://localhost:80/
Running 30s test @ http://localhost:80/
  4 threads and 200 connections
  Thread calibration: mean lat.: 1.234ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.273ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.272ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.282ms, rate sampling interval: 10ms
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.33ms  452.45us   3.99ms   65.69%
    Req/Sec   527.08    127.91     1.00k    72.62%
  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%    1.30ms
 75.000%    1.64ms
 90.000%    1.96ms
 99.000%    2.43ms
 99.900%    2.73ms
 99.990%    3.52ms
 99.999%    3.99ms
100.000%    3.99ms

#[Mean    =        1.334, StdDeviation   =        0.452]
#[Max     =        3.992, Total count    =        39480]

t4 (callbacks)
Running 30s test @ http://localhost:12345/
  4 threads and 200 connections
  Thread calibration: mean lat.: 1.188ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.191ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.177ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.155ms, rate sampling interval: 10ms
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.13ms  494.29us   6.54ms   66.60%
    Req/Sec   524.66    235.41     1.22k    65.60%
  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%    1.09ms
 75.000%    1.46ms
 90.000%    1.78ms
 99.000%    2.37ms
 99.900%    2.96ms
 99.990%    6.03ms
 99.999%    6.55ms
100.000%    6.55ms

#[Mean    =        1.133, StdDeviation   =        0.494]
#[Max     =        6.544, Total count    =        39463]

t3(tasks)
Running 30s test @ http://localhost:12345/
  4 threads and 200 connections
  Thread calibration: mean lat.: 1.169ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.170ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.183ms, rate sampling interval: 10ms
  Thread calibration: mean lat.: 1.157ms, rate sampling interval: 10ms
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.14ms  528.72us  10.10ms   69.79%
    Req/Sec   525.82    263.61     1.44k    61.66%
  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%    1.12ms
 75.000%    1.47ms
 90.000%    1.78ms
 99.000%    2.30ms
 99.900%    5.99ms
 99.990%    9.26ms
 99.999%   10.11ms
100.000%   10.11ms
#[Mean    =        1.145, StdDeviation   =        0.529]
#[Max     =       10.104, Total count    =        39461]
