# Signal benchmark baseline

The value is the median of three process-run means.
Each process run contains nine samples.

| Workload | Current Eta | Jane Street | Eta / Jane | 1.20× target |
|---|---:|---:|---:|---:|
| Changed scalar, depth 1 | 2.716 s | 32.0 ns | 84,895,845.0× | 38.4 ns |
| Changed scalar, depth 10 | 2.733 s | 148.5 ns | 18,399,231.2× | 178.2 ns |
| Changed scalar, depth 100 | 2.806 s | 1.044 us | 2,687,782.7× | 1.253 us |
| Cutoff before 10 dependents | 5.998 s | 53.7 ns | 111,618,352.4× | 64.5 ns |
| Dynamic branch switch | 2.710 s | 228.7 ns | 11,853,883.9× | 274.4 ns |
| One data change, 10k keys | 2.930 s | 264.1 ns | 11,092,745.9× | 316.9 ns |
| One data change, 100k keys | 2.674 s | 324.1 ns | 8,248,940.7× | 388.9 ns |
| One child change, 10k keys | 2.689 s | 89.4 ns | 30,078,928.2× | 107.3 ns |
| One child change, 100k keys | 2.716 s | 105.6 ns | 25,726,204.6× | 126.7 ns |

The final Eta value for each row must be less than its current value.
It must also be no more than the listed `1.20×` target.
