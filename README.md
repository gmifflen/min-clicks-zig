# min-clicks (Zig port)

A Zig 0.17.0 derivative of [clmpk/min-clicks](https://github.com/clmpk/min-clicks/tree/7225581ca6044512737192fb1f8d1b6b40dcdcfb)

All code under `reference/` is from the original min-clicks repo

## Build and compare

Install Zig from https://ziglang.org/download/

```sh
zig build -Drelease
zig build compare   # checks the Zig version against the C++ version and times them
```

Zig is the only toolchain needed: the C++ version in `reference/` is compiled with Zig's built-in C++ compiler. The first build of it also compiles libc++, which takes a minute or two.

```sh
zig build compare -- --rounds 5 # default 3
zig build compare -- --quick    # 3 small and 3 expert boards, one round
```

## Usage

The command line matches the original:

```sh
./optimal [URL/ENCODED_STRING] [options]
./optimal "?b=1&m=122a004010g000g80"

./optimal --random WIDTH HEIGHT MINES SEED [--64b] [options]
./optimal --random 30 16 99 42 --all --witness

./optimal --help
```

## Output of `zig build compare` run on a 5800x
```pwsh
λ zig build compare
MIN-CLICKS COMPARISON

Round 1/3
  PASS  small 16x16/40                   482.9 ms      349.0 ms   1.38x faster
  PASS  expert 30x16/99                    2.42 s        1.73 s   1.41x faster
  PASS  large 40x24/200                   20.38 s       10.06 s   2.03x faster
  PASS  long 46x28/270                    19.57 s       11.79 s   1.66x faster
  PASS  hard 30x30/180                    17.91 s        7.19 s   2.49x faster
  PASS  island 99x99 (just setup)         26.70 s      146.2 ms   182.58x faster

Round 2/3
  PASS  small 16x16/40                   467.6 ms      320.4 ms   1.46x faster
  PASS  expert 30x16/99                    2.35 s        1.65 s   1.43x faster
  PASS  large 40x24/200                   20.11 s        9.87 s   2.04x faster
  PASS  long 46x28/270                    19.64 s       11.39 s   1.72x faster
  PASS  hard 30x30/180                    17.85 s        7.19 s   2.48x faster
  PASS  island 99x99 (just setup)         26.69 s      136.5 ms   195.54x faster

Round 3/3
  PASS  small 16x16/40                   440.5 ms      312.6 ms   1.41x faster
  PASS  expert 30x16/99                    2.33 s        1.64 s   1.42x faster
  PASS  large 40x24/200                   20.12 s       10.11 s   1.99x faster
  PASS  long 46x28/270                    19.54 s       11.28 s   1.73x faster
  PASS  hard 30x30/180                    17.92 s        7.04 s   2.55x faster
  PASS  island 99x99 (just setup)         26.82 s      139.4 ms   192.41x faster

SUMMARY  (median of round totals)

Family                          Reference        Solver   Solver advantage
-------------------------------------------------------------------------------
small 16x16/40                   467.6 ms      320.4 ms   1.46x faster
expert 30x16/99                    2.35 s        1.65 s   1.43x faster
large 40x24/200                   20.12 s       10.06 s   2.00x faster
long 46x28/270                    19.57 s       11.39 s   1.72x faster
hard 30x30/180                    17.91 s        7.19 s   2.49x faster
island 99x99 (just setup)         26.70 s      139.4 ms   191.57x faster
```
