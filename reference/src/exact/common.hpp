#pragma once

#include "../board.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <map>
#include <numeric>
#include <random>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>

namespace minclicks::detail {

using namespace std;
using Clock = chrono::steady_clock;

inline double seconds(Clock::time_point start) {
    return chrono::duration<double>(Clock::now() - start).count();
}

inline void unique_sort(vector<int> &v) {
    sort(v.begin(), v.end());
    v.erase(unique(v.begin(), v.end()), v.end());
}

inline bool subset(const vector<int> &a, const vector<int> &b) {
    return includes(b.begin(), b.end(), a.begin(), a.end());
}

struct DSU {
    vector<int> p;

    explicit DSU(int n) : p(n) { iota(p.begin(), p.end(), 0); }

    int root(int a) {
        while (p[a] != a) {
            p[a] = p[p[a]];
            a = p[a];
        }
        return a;
    }

    void join(int a, int b) { p[root(a)] = root(b); }
};

inline void flip(string &s, int i) {
    s[i / 8] ^= char(1u << (i % 8));
}

}  // namespace minclicks::detail