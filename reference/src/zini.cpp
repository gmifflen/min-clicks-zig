#include "zini.hpp"
#include <algorithm>
#include <numeric>
#include <stdexcept>

namespace minclicks {
namespace {
// Legacy Wom premiums are incremental: recomputing them after each move changes
// the algorithm. See docs/legacy-zini.md for the pinned reference and quirks.
struct LegacyBoard {
    const Board &b;
    std::vector<int> order, primary, secondary;
    std::vector<std::vector<int>> openings;
    explicit LegacyBoard(const Board &board)
        : b(board), primary(b.w * b.h), secondary(b.w * b.h) {
        for (int x = 0; x < b.w; ++x)
            for (int y = 0; y < b.h; ++y)
                order.push_back(y * b.w + x);
        std::vector<int> labels(b.zeros.size(), 0);
        int label = 0;
        for (int p : order)
            if (b.island[p] >= 0 && !labels[b.island[p]])
                labels[b.island[p]] = ++label;
        std::vector<int> islands(b.zeros.size());
        std::iota(islands.begin(), islands.end(), 0);
        std::sort(islands.begin(), islands.end(),
                  [&](int a, int c) { return labels[a] < labels[c]; });
        for (int z : islands) {
            for (int p : b.zeros[z])
                primary[p] = labels[z];
            for (int p : b.borders[z]) {
                if (!primary[p])
                    primary[p] = labels[z];
                else
                    secondary[p] = labels[z];
            }
        }
        // Preserve the legacy first/last labels, including its treatment of
        // borders touching several regions. This is the old full scan's exact
        // membership and column-major order, indexed by opening label.
        openings.resize(label + 1);
        for (int p : order) {
            if (primary[p])
                openings[primary[p]].push_back(p);
            if (secondary[p] && secondary[p] != primary[p])
                openings[secondary[p]].push_back(p);
        }
    }
};
struct Position {
    std::vector<int> open, flag, premium;
    explicit Position(int n) : open(n), flag(n), premium(n) {}
};
int reveal(const LegacyBoard &b, Position &s, int p) {
    s.open[p] = 1;
    int count = 1;
    if (b.b.number[p] == 0) {
        for (int q : b.openings[b.primary[p]])
            if (q != p) {
                if (!s.open[q]) {
                    s.open[q] = 1;
                    ++count;
                    if (b.b.number[q] != 0)
                        ++s.premium[q];
                }
                if (b.b.number[q] != 0)
                    --s.premium[q];
            }
    } else {
        ++s.premium[p];
        if (!b.primary[p]) {
            --s.premium[p];
            for (int q : b.b.adj[p])
                --s.premium[q];
        }
    }
    return count;
}
int chord(const LegacyBoard &b, Position &s, int p,
          std::vector<Action> *actions = nullptr) {
    int revealed = 0;
    if (!s.open[p]) {
        revealed += reveal(b, s, p);
        if (actions)
            actions->push_back({'O', p});
    }
    for (int q : b.b.adj[p]) {
        if (b.b.mine[q] && !s.flag[q]) {
            s.flag[q] = 1;
            for (int r : b.b.adj[q])
                ++s.premium[r];
            if (actions)
                actions->push_back({'F', q});
        } else if (!b.b.mine[q] && !s.open[q])
            revealed += reveal(b, s, q);
    }
    if (actions)
        actions->push_back({'C', p});
    return revealed;
}
struct Best {
    int premium = -100, count = 0, first = -1;
};
Best best(const LegacyBoard &b, const Position &s, bool h) {
    Best result;
    for (int p : b.order)
        if (!h || s.open[p]) {
            if (s.premium[p] > result.premium) {
                result.premium = s.premium[p];
                result.count = 0;
            }
            if (s.premium[p] == result.premium) {
                if (!result.count)
                    result.first = p;
                ++result.count;
            }
        }
    return result;
}
HeuristicResult run(const LegacyBoard &b, bool h) {
    Position s(b.b.w * b.b.h);
    Position next(b.b.w * b.b.h);
    HeuristicResult result;
    int remaining = b.b.w * b.b.h - b.b.mineCount();
    bool openingsDone = h;
    if (h) {
        std::vector<bool> clicked(b.b.zeros.size() + 1);
        for (int p : b.order)
            if (b.primary[p]) {
                s.open[p] = 1;
                --remaining;
                if (b.b.number[p] == 0 && !clicked[b.primary[p]]) {
                    clicked[b.primary[p]] = true;
                    result.actions.push_back({'O', p});
                }
            }
    }
    for (int p : b.order) {
        if (b.b.number[p] <= 0) {
            s.premium[p] = -100;
            continue;
        }
        int value = -(!s.open[p]) - 1 + (!b.primary[p]);
        bool zero = false;
        for (int q : b.b.adj[p]) {
            if (b.b.mine[q])
                value -= !s.flag[q];
            else if (!s.open[q] && !b.primary[q])
                ++value;
            if (b.b.number[q] == 0 && !s.open[q])
                zero = true;
        }
        s.premium[p] = value + (b.secondary[p] != 0 && zero);
    }
    while (remaining > 0) {
        auto candidates = best(b, s, h);
        if (candidates.premium >= 0 && candidates.count) {
            int chosen = candidates.first, score = -1;
            if (candidates.count > 1)
                for (int p : b.order)
                    if ((!h || s.open[p]) && s.premium[p] == candidates.premium) {
                        next = s; // Reuse storage across tie simulations.
                        chord(b, next, p);
                        auto future = best(b, next, h);
                        int value = future.premium * 1000 + future.count;
                        if (value > score) {
                            score = value;
                            chosen = p;
                        }
                    }
            remaining -= chord(b, s, chosen, &result.actions);
        } else {
            int chosen = -1;
            if (!openingsDone) {
                for (int p : b.order)
                    if (!s.open[p] && b.b.number[p] == 0) {
                        chosen = p;
                        break;
                    }
                if (chosen < 0)
                    openingsDone = true;
            }
            if (openingsDone)
                for (int p : b.order)
                    if (!s.open[p] && !b.b.mine[p] &&
                        !(b.secondary[p] && b.b.number[p] > 0)) {
                        chosen = p;
                        break;
                    }
            if (chosen < 0)
                throw std::logic_error("Legacy ZiNi left an unopened cell");
            remaining -= reveal(b, s, chosen);
            result.actions.push_back({'O', chosen});
        }
    }
    result.clicks = int(result.actions.size());
    return result;
}
} // namespace
HeuristicResult hzini(const Board &b) { return run(LegacyBoard(b), true); }
LegacyZiniResults legacyZini(const Board &b) {
    LegacyBoard board(b);
    LegacyZiniResults result{run(board, true), run(board, false)};
    if (result.lzini.clicks > result.hzini.clicks)
        result.lzini = result.hzini;
    return result;
}
HeuristicResult lzini(const Board &b) { return legacyZini(b).lzini; }
} // namespace minclicks
