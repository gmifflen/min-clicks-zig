#include "zini.hpp"
#include <algorithm>
#include <bit>
#include <cassert>
#include <limits>

namespace minclicks {
namespace {
// Bits within each premium bucket are traversal ranks, preserving tie-breaks.
struct PremiumQueue {
    int words;
    std::vector<uint64_t> bits;
    std::vector<int> rank, cell, premium;
    std::array<int, 9> counts{};
    unsigned active = 0;

    explicit PremiumQueue(const Board &b)
        : words((b.w * b.h + 63) / 64), bits(9 * words),
          rank(b.w * b.h), cell(b.w * b.h), premium(b.w * b.h) {}
    void reset(const Board &b, const std::vector<int> &initial, int direction) {
        premium = initial;
        std::fill(bits.begin(), bits.end(), 0);
        counts.fill(0);
        active = 0;
        for (int y = 0; y < b.h; ++y)
            for (int x = 0; x < b.w; ++x) {
                int rx = direction & 1 ? b.w - 1 - x : x;
                int ry = direction & 2 ? b.h - 1 - y : y;
                int r = direction & 4 ? ry + b.h * rx : rx + b.w * ry;
                int p = y * b.w + x;
                rank[p] = r;
                cell[r] = p;
                if (premium[p] >= 0) {
                    bits[premium[p] * words + r / 64] |= uint64_t(1) << (r % 64);
                    ++counts[premium[p]];
                    active |= 1u << premium[p];
                }
            }
    }
    void change(int p, int delta) {
        int r = rank[p], old = premium[p], value = old + delta;
        assert(value <= 8);
        uint64_t bit = uint64_t(1) << (r % 64);
        if (old >= 0) {
            bits[old * words + r / 64] &= ~bit;
            if (!--counts[old])
                active &= ~(1u << old);
        }
        premium[p] = value;
        if (value >= 0) {
            bits[value * words + r / 64] |= bit;
            ++counts[value];
            active |= 1u << value;
        }
    }
    int best() const {
        if (active) {
            int value = std::bit_width(active) - 1;
            for (int word = 0; word < words; ++word)
                if (uint64_t mask = bits[value * words + word])
                    return cell[64 * word + std::countr_zero(mask)];
        }
        return -1;
    }
};
template <bool WithActions> HeuristicResult runEightWay(const Board &b) {
    const int n = b.w * b.h;
    std::vector<uint8_t> target(n);
    for (int p : b.targets)
        target[p] = 1;
    std::vector<int> initial(n, -100);
    for (int p = 0; p < n; ++p)
        if (b.number[p] > 0) {
            initial[p] = -1 - !target[p] - b.number[p];
            for (int q : b.adj[p])
                initial[p] += target[q];
        }
    for (const auto &border : b.borders)
        for (int p : border)
            ++initial[p];

    HeuristicResult best;
    best.clicks = std::numeric_limits<int>::max();
    PremiumQueue queue(b);
    std::vector<uint8_t> open(n), flag(n);
    HeuristicResult result;
    if constexpr (WithActions)
        result.actions.reserve(n);
    auto action = [&](char kind, int p) {
        ++result.clicks;
        if constexpr (WithActions)
            result.actions.push_back({kind, p});
    };
    for (int direction = 0; direction < 8; ++direction) {
        queue.reset(b, initial, direction);
        std::fill(open.begin(), open.end(), 0);
        std::fill(flag.begin(), flag.end(), 0);
        result.clicks = 0;
        result.actions.clear();
        auto reveal = [&](int p) {
            if (open[p])
                return;
            open[p] = 1;
            if (b.island[p] >= 0) {
                int z = b.island[p];
                for (int q : b.zeros[z])
                    open[q] = 1;
                for (int q : b.borders[z]) {
                    // Lose this unopened-region credit. A newly opened border
                    // simultaneously gains its own opening-click credit.
                    if (open[q])
                        queue.change(q, -1);
                    open[q] = 1;
                }
            } else if (target[p]) {
                for (int q : b.adj[p])
                    if (b.number[q] > 0)
                        queue.change(q, -1);
            } else {
                queue.change(p, 1);
            }
        };
        for (int chosen; (chosen = queue.best()) >= 0;) {
            // Later traversals cannot replace an equal-cost earlier winner.
            if (result.clicks >= best.clicks)
                break;
            if (!open[chosen]) {
                action('O', chosen);
                reveal(chosen);
            }
            // The reference visits flag neighbors by column, then row.
            for (int dx = -1; dx <= 1; ++dx)
                for (int dy = -1; dy <= 1; ++dy) {
                    int x = chosen % b.w + dx, y = chosen / b.w + dy;
                    if (x < 0 || x >= b.w || y < 0 || y >= b.h)
                        continue;
                    int q = y * b.w + x;
                    if (b.mine[q] && !flag[q]) {
                        flag[q] = 1;
                        action('F', q);
                        for (int r : b.adj[q])
                            if (b.number[r] > 0)
                                queue.change(r, 1);
                    }
                }
            action('C', chosen);
            for (int q : b.adj[chosen])
                if (!b.mine[q])
                    reveal(q);
        }
        if (result.clicks >= best.clicks)
            continue;
        if constexpr (WithActions) {
            for (int x = 0; x < b.w; ++x)
                for (int y = 0; y < b.h; ++y) {
                    int p = y * b.w + x;
                    if (!open[p] && (target[p] || b.number[p] == 0)) {
                        action('O', p);
                        open[p] = 1;
                        // No future chord decisions: only zero membership is
                        // needed to preserve the final direct-opening order.
                        if (b.island[p] >= 0)
                            for (int q : b.zeros[b.island[p]])
                                open[q] = 1;
                    }
                }
        } else {
            for (int p : b.targets)
                result.clicks += !open[p];
            for (const auto &region : b.zeros)
                result.clicks += !open[region[0]];
        }
        if (result.clicks < best.clicks)
            best = result;
    }
    return best;
}
} // namespace
HeuristicResult eightWayZini(const Board &b) { return runEightWay<true>(b); }
int eightWayZiniClicks(const Board &b) { return runEightWay<false>(b).clicks; }
} // namespace minclicks
