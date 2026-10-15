# min-clicks (Zig port)

A Zig 0.17.0 port of [clmpk/min-clicks](https://github.com/clmpk/min-clicks/tree/7225581ca6044512737192fb1f8d1b6b40dcdcfb)

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
