#include "schedule.hpp"
namespace minclicks::detail {
// Optimize permutations inside fixed blocks. Frontier width after a prefix
// depends only on its chosen subset, including for blocks crossing strip edges.
static void optimizeBlocks(const Model &m, vector<int> &order,
                           const vector<int> &ends) {
    int n = (int)order.size();
    vector<int> pos(n);
    for (int t = 0; t < n; ++t)
        pos[order[t]] = t;
    struct Block {
        int begin, end;
        vector<int> width;
    };
    vector<Block> blocks;
    int begin = 0;
    for (int end : ends) {
        // Planner complexity guard only: this leaves a valid spatial order and
        // never limits the actual solver or discards any solution.
        if (end - begin > 18)
            return;
        blocks.push_back({begin, end, {}});
        begin = end;
    }
    int globalPeak = 0;
    for (auto &block : blocks) {
        int begin = block.begin, end = block.end, k = end - begin,
            size = 1 << k, full = size - 1;
        vector<int> direct(size), complement(size);
        int constant = 0;
        auto classify = [&](const vector<int> &scope) {
            int mask = 0;
            bool before = false, after = false;
            for (int v : scope)
                if (v < n) {
                    int p = pos[v];
                    if (p < begin)
                        before = true;
                    else if (p >= end)
                        after = true;
                    else
                        mask |= 1 << (p - begin);
                }
            return tuple{mask, before, after};
        };
        auto hyperedge = [&](const vector<int> &scope, int weight) {
            auto [mask, before, after] = classify(scope);
            if (!mask && !before && !after)
                return;
            // [some processed AND some future] = 1 - [none processed]
            //                                      - [none future].
            constant += weight;
            if (!before)
                complement[mask] -= weight;
            if (!after)
                direct[mask] -= weight;
        };
        for (int v = 0; v < n; ++v)
            if (pos[v] < end) {
                auto [mask, before, after] = classify(m.edges[v]);
                (void)before;
                if (pos[v] < begin) {
                    constant += CONN_WEIGHT;
                    if (!after)
                        direct[mask] -= CONN_WEIGHT;
                } else {
                    int self = 1 << (pos[v] - begin);
                    direct[self] += CONN_WEIGHT;
                    if (!after)
                        direct[mask | self] -= CONN_WEIGHT;
                }
            }
        for (int z = n; z < (int)m.edges.size(); ++z)
            hyperedge(m.edges[z], CONN_WEIGHT);
        for (const auto &f : m.factors)
            hyperedge(f.vars, FACTOR_WEIGHT);
        // Subset zeta transforms evaluate the width of every possible prefix
        // in O(k * 2^k), instead of scanning every graph/factor for each
        // prefix.
        for (int bit = 1; bit < size; bit <<= 1)
            for (int mask = 0; mask < size; ++mask)
                if (mask & bit) {
                    direct[mask] += direct[mask ^ bit];
                    complement[mask] += complement[mask ^ bit];
                }
        block.width.resize(size);
        vector<int> peak(size, numeric_limits<int>::max());
        for (int mask = 0; mask < size; ++mask)
            block.width[mask] =
                constant + direct[mask] + complement[full ^ mask];
        peak[0] = block.width[0];
        for (int mask = 1; mask < size; ++mask) {
            for (unsigned bits = unsigned(mask); bits; bits &= bits - 1) {
                unsigned bit = bits & -bits;
                peak[mask] =
                    min(peak[mask], max(peak[mask ^ bit], block.width[mask]));
            }
        }
        globalPeak = max(globalPeak, peak.back());
    }
    vector<int> optimized;
    optimized.reserve(n);
    for (const auto &block : blocks) {
        int size = (int)block.width.size();
        vector<double> cost(size, numeric_limits<double>::infinity());
        vector<unsigned> parent(size);
        cost[0] = 0;
        for (int mask = 1; mask < size; ++mask)
            if (block.width[mask] <= globalPeak) {
                double increment = exp2(block.width[mask] / (WIDTH_EXP_SCALE * WEIGHT_SCALE));
                for (unsigned bits = unsigned(mask); bits; bits &= bits - 1) {
                    unsigned bit = bits & -bits;
                    double value = cost[mask ^ bit] + increment;
                    if (value <= cost[mask]) {
                        cost[mask] = value;
                        parent[mask] = bit;
                    }
                }
            }
        vector<int> reverse;
        for (unsigned mask = unsigned(size - 1); mask;) {
            unsigned bit = parent[mask];
            if (!bit)
                throw logic_error(
                    "Strip planner failed to reconstruct an order");
            reverse.push_back(order[block.begin + countr_zero(bit)]);
            mask ^= bit;
        }
        optimized.insert(optimized.end(), reverse.rbegin(), reverse.rend());
    }
    order = std::move(optimized);
}
void optimizeStrips(const Model &m, vector<int> &order, bool rows, int bandSize) {
    auto strip = [&](int v) {
        return (rows ? m.cells[v] / m.b.w : m.cells[v] % m.b.w) / bandSize;
    };
    vector<int> ends;
    for (int begin = 0, n = int(order.size()); begin < n;) {
        int end = begin + 1;
        while (end < n && strip(order[end]) == strip(order[begin])) ++end;
        ends.push_back(end);
        begin = end;
    }
    optimizeBlocks(m, order, ends);
}
void optimizeWindows(const Model &m, vector<int> &order, int size, int offset) {
    if (size < 1 || size > 18 || offset < 0 || offset >= size)
        throw invalid_argument("Invalid order-refinement window");
    vector<int> ends;
    for (int begin = 0, end = size - offset, n = int(order.size()); begin < n;
         begin = end, end += size)
        ends.push_back(min(n, end));
    optimizeBlocks(m, order, ends);
}
static OrderPlan scoreOrder(const Model &m, vector<int> order, string name,
                            int begin = 0, int end = -1) {
    int n = (int)m.cells.size(), total = (int)m.edges.size();
    vector<int> pos(n);
    if (end < 0) end = n;
    for (int i = 0; i < n; ++i)
        pos[order[i]] = i;
    vector<int> first(total, n), last(total, -1);
    for (int i = 0; i < total; ++i) {
        if (i < n)
            first[i] = last[i] = pos[i];
        for (int j : m.edges[i])
            if (j < n) {
                first[i] = min(first[i], pos[j]);
                last[i] = max(last[i], pos[j]);
            }
        if (i < n)
            first[i] = pos[i];
    }
    vector<int> ff(m.factors.size(), n), fl(m.factors.size(), -1);
    for (int f = 0; f < (int)m.factors.size(); ++f)
        for (int i : m.factors[f].vars) {
            ff[f] = min(ff[f], pos[i]);
            fl[f] = max(fl[f], pos[i]);
        }
    // Only lifetime counts are needed to compare orders. Building contacts,
    // bounds and fold tables for losing orders used to dominate easy boards.
    vector<int> connDelta(n + 1), factorDelta(n + 1);
    for (int i = 0; i < total; ++i)
        if (first[i] < last[i]) {
            ++connDelta[first[i]];
            --connDelta[last[i]];
        }
    for (int f = 0; f < (int)m.factors.size(); ++f)
        if (ff[f] < fl[f]) {
            ++factorDelta[ff[f]];
            --factorDelta[fl[f]];
        }
    OrderPlan plan{std::move(order), std::move(name)};
    int connections = 0, factors = 0;
    for (int t = 0; t < n; ++t) {
        connections += connDelta[t];
        factors += factorDelta[t];
        if (t < begin || t >= end) continue;
        double width = RATIO_WEIGHT * connections + factors;
        plan.score = max(plan.score, width);
        plan.totalScore += exp2(width / 4);
    }
    return plan;
}
OrderPlan refineOrder(const Model &m, OrderPlan plan) {
    const string name = plan.name + "-w";
    for (int pass = 0; pass < 4; ++pass) {
        auto order = plan.order;
        // Offset alternate passes so candidates can cross previous block edges.
        optimizeWindows(m, order, 16, (pass % 2) * 8);
        auto candidate = scoreOrder(m, std::move(order), name);
        if (candidate.score < plan.score ||
            (candidate.score == plan.score && candidate.totalScore < plan.totalScore))
            plan = std::move(candidate);
    }
    return plan;
}
// Estimate the number of distinct factor configurations at each cut. A live
// factor can only vary through decisions already made; counting every live
// factor as an independent bit badly overprices broad spatial bands. The
// binary incidence rank is a cheap proxy for the number of independent sums.
double estimateFrontierWork(const Model &m, const OrderPlan &plan) {
    const int n = int(plan.order.size()), total = int(m.edges.size());
    vector<int> pos(n), connDelta(n + 1);
    for (int t = 0; t < n; ++t) pos[plan.order[t]] = t;
    for (int i = 0; i < total; ++i) {
        int first = n, last = -1;
        if (i < n) first = last = pos[i];
        for (int v : m.edges[i]) if (v < n) {
            first = min(first, pos[v]);
            last = max(last, pos[v]);
        }
        if (i < n) first = pos[i];
        if (first < last) {
            ++connDelta[first];
            --connDelta[last];
        }
    }
    vector<int> ff(m.factors.size(), n), fl(m.factors.size(), -1);
    for (int f = 0; f < int(m.factors.size()); ++f)
        for (int v : m.factors[f].vars) {
            ff[f] = min(ff[f], pos[v]);
            fl[f] = max(fl[f], pos[v]);
        }
    double work = 0;
    int connections = 0;
    for (int t = 0; t < n; ++t) {
        connections += connDelta[t];
        vector<int> active;
        for (int f = 0; f < int(m.factors.size()); ++f)
            if (ff[f] <= t && t < fl[f]) active.push_back(f);
        int rank = 0;
        if (active.size() <= 64) {
            array<uint64_t, 64> basis{};
            vector<uint64_t> decisions(t + 1);
            for (int b = 0; b < int(active.size()); ++b)
                for (int v : m.factors[active[b]].vars)
                    if (pos[v] <= t)
                        decisions[pos[v]] |= uint64_t(1) << b;
            for (int k = 0; k <= t; ++k) {
                uint64_t mask = decisions[k];
                while (mask) {
                    int bit = 63 - countl_zero(mask);
                    if (!basis[bit]) { basis[bit] = mask; ++rank; break; }
                    mask ^= basis[bit];
                }
            }
        } else rank = int(active.size());
        work += exp2((RATIO_WEIGHT * connections + rank) / 4);
    }
    return work;
}
OrderPlan planOrder(const Model &m, string name) {
    vector<int> order(m.cells.size());
    iota(order.begin(), order.end(), 0);
    bool rows = name.find("rows") != string::npos,
         reverse = name.find("reverse") != string::npos;
    sort(order.begin(), order.end(), [&](int a, int b) {
        int p = m.cells[a], q = m.cells[b];
        int ka = rows ? p : (p % m.b.w) * m.b.h + p / m.b.w;
        int kb = rows ? q : (q % m.b.w) * m.b.h + q / m.b.w;
        return reverse ? ka > kb : ka < kb;
    });
    if (name.find("-dp") != string::npos)
        optimizeStrips(m, order, rows,
                       name.find("-dp2") != string::npos ? 2 : 1);
    return scoreOrder(m, std::move(order), std::move(name));
}
// Choose the strip boundaries themselves. Each band is swept in its secondary
// direction; the set before/after a band is independent of earlier band widths.
OrderPlan dynamicBandOrder(const Model &m, bool rows, bool reverse) {
    int n = int(m.cells.size()), lines = rows ? m.b.h : m.b.w;
    int maxBand = min(lines, 8);
    auto line = [&](int v) {
        int physical = rows ? m.cells[v] / m.b.w : m.cells[v] % m.b.w;
        return reverse ? lines - 1 - physical : physical;
    };
    auto secondary = [&](int v) {
        return rows ? m.cells[v] % m.b.w : m.cells[v] / m.b.w;
    };
    vector<vector<int>> byLine(lines);
    for (int v = 0; v < n; ++v) byLine[line(v)].push_back(v);
    vector<int> prefix(lines + 1);
    for (int l = 0; l < lines; ++l)
        prefix[l + 1] = prefix[l] + int(byLine[l].size());
    vector<vector<OrderPlan>> bands(lines);
    for (int start = 0; start < lines; ++start)
        for (int end = start + 1; end <= min(lines, start + maxBand); ++end) {
            vector<int> inside, trial;
            for (int l = start; l < end; ++l)
                inside.insert(inside.end(), byLine[l].begin(), byLine[l].end());
            sort(inside.begin(), inside.end(), [&](int a, int b) {
                return pair{secondary(a), line(a)} < pair{secondary(b), line(b)};
            });
            for (int l = 0; l < start; ++l)
                trial.insert(trial.end(), byLine[l].begin(), byLine[l].end());
            trial.insert(trial.end(), inside.begin(), inside.end());
            for (int l = end; l < lines; ++l)
                trial.insert(trial.end(), byLine[l].begin(), byLine[l].end());
            auto profile = scoreOrder(m, std::move(trial), "", prefix[start], prefix[end]);
            profile.order = std::move(inside);
            bands[start].push_back(std::move(profile));
        }
    vector<double> peak(lines + 1, numeric_limits<double>::infinity());
    peak[0] = 0;
    for (int end = 1; end <= lines; ++end)
        for (int start = max(0, end - maxBand); start < end; ++start)
            peak[end] = min(peak[end], max(peak[start], bands[start][end - start - 1].score));
    vector<double> work(lines + 1, numeric_limits<double>::infinity());
    vector<int> previous(lines + 1, -1);
    work[0] = 0;
    for (int end = 1; end <= lines; ++end)
        for (int start = max(0, end - maxBand); start < end; ++start) {
            const auto &band = bands[start][end - start - 1];
            double value = work[start] + band.totalScore;
            if (band.score <= peak[lines] && value < work[end]) {
                work[end] = value;
                previous[end] = start;
            }
        }
    vector<pair<int, int>> selected;
    for (int end = lines; end; end = previous[end]) {
        if (previous[end] < 0) throw logic_error("Dynamic band reconstruction failed");
        selected.push_back({previous[end], end});
    }
    vector<int> order;
    string name = string(rows ? "r" : "c") + (reverse ? "r" : "") + "b";
    for (auto it = selected.rbegin(); it != selected.rend(); ++it) {
        auto [start, end] = *it;
        const auto &inside = bands[start][end - start - 1].order;
        order.insert(order.end(), inside.begin(), inside.end());
        name += '-' + to_string(end - start);
    }
    return scoreOrder(m, std::move(order), std::move(name));
}
Schedule schedule(const Model &m, string name) {
    return schedule(m, planOrder(m, std::move(name)));
}
Schedule schedule(const Model &m, const OrderPlan &plan) {
    int n = (int)m.cells.size(), total = (int)m.edges.size();
    const auto &order = plan.order;
    vector<int> pos(n);
    for (int i = 0; i < n; ++i)
        pos[order[i]] = i;
    vector<int> first(total, n), last(total, -1);
    for (int i = 0; i < total; ++i) {
        if (i < n)
            first[i] = last[i] = pos[i];
        for (int j : m.edges[i])
            if (j < n) {
                first[i] = min(first[i], pos[j]);
                last[i] = max(last[i], pos[j]);
            }
        if (i < n)
            first[i] = pos[i];
    }
    vector<int> ff(m.factors.size(), n), fl(m.factors.size(), -1);
    for (int f = 0; f < (int)m.factors.size(); ++f)
        for (int i : m.factors[f].vars) {
            ff[f] = min(ff[f], pos[i]);
            fl[f] = max(fl[f], pos[i]);
        }
    Schedule s;
    s.name = plan.name;
    vector<int> active, af;
    for (int t = 0; t < n; ++t) {
        Step st;
        st.var = order[t];
        st.before = active;
        st.expanded = active;
        st.oldFactors = af;
        for (int z = n; z < total; ++z)
            if (first[z] == t) {
                st.expanded.push_back(z);
                ++st.freshZeros;
            }
        st.expanded.push_back(st.var);
        for (int j = 0; j < (int)st.expanded.size() - 1; ++j)
            if (find(m.edges[st.var].begin(), m.edges[st.var].end(),
                     st.expanded[j]) != m.edges[st.var].end())
                st.neighbors.push_back(j);
        for (int j = 0; j < (int)st.expanded.size(); ++j)
            if (last[st.expanded[j]] > t) {
                st.keep.push_back(j);
                st.after.push_back(st.expanded[j]);
            }
        vector<int> all = af;
        for (int f = 0; f < (int)m.factors.size(); ++f)
            if (ff[f] == t)
                all.push_back(f);
        for (int f : all) {
            auto it = find(af.begin(), af.end(), f);
            st.factorOld.push_back(it == af.end() ? -1
                                                  : (int)(it - af.begin()));
            st.factorTouch.push_back(find(m.factors[f].vars.begin(),
                                          m.factors[f].vars.end(),
                                          st.var) != m.factors[f].vars.end());
            st.factorClose.push_back(fl[f] == t ? (m.factors[f].mine ? 1 : 0)
                                                : -1);
            st.factorWeight.push_back(m.factors[f].weight);
            if (fl[f] > t) {
                st.factorKeep.push_back((int)st.newFactors.size());
                st.newFactors.push_back(f);
            } else
                st.factorKeep.push_back(-1);
        }
        active = st.after;
        af = st.newFactors;
        if (st.after.size() <= 24)
            for (int v : st.after) {
                vector<uint32_t> contacts;
                for (int u : m.edges[v])
                    if (u < n && pos[u] > t) {
                        uint32_t mask = 0;
                        for (int j = 0; j < (int)st.after.size(); ++j)
                            if (find(m.edges[u].begin(), m.edges[u].end(),
                                     st.after[j]) != m.edges[u].end())
                                mask |= uint32_t(1) << j;
                        contacts.push_back(mask);
                    }
                st.contacts.push_back(std::move(contacts));
            }
        if (!st.contacts.empty()) {
            vector<uint32_t> patterns;
            for (const auto &items : st.contacts)
                for (uint32_t mask : items)
                    if (find(patterns.begin(), patterns.end(), mask) == patterns.end())
                        patterns.push_back(mask);
            if (patterns.size() <= 64) {
                st.futureSignatures.assign(st.contacts.size(), 0);
                for (size_t index = 0; index < patterns.size(); ++index)
                    for (uint32_t mask = patterns[index]; mask; mask &= mask - 1)
                        st.futureSignatures[countr_zero(mask)] |= uint64_t(1) << index;
            }
        }
        s.maxConn = max(s.maxConn, (int)active.size());
        s.maxFactors = max(s.maxFactors, (int)af.size());
        // A cheap width estimate; compare both directions because long zero
        // islands matter.
        s.score = max(s.score, RATIO_WEIGHT * active.size() + af.size());
        s.totalScore += exp2((RATIO_WEIGHT * active.size() + af.size()) / 4);
        s.steps.push_back(std::move(st));
    }
    // Color factor lifetimes into stable bit positions, avoiding per-state
    // rearrangement of the OR bits. Slots are released after closing a factor.
    vector<int> slots(m.factors.size(), -1);
    uint64_t busy = 0;
    int stepIndex = 0;
    for (auto &st : s.steps) {
        if (st.expanded.size() > 31 || st.after.size() > 24)
            s.packed = false;
        vector<int> live = st.oldFactors;
        for (int f : st.newFactors)
            if (find(live.begin(), live.end(), f) == live.end())
                live.push_back(f);
        // Include factors that both start and finish at this candidate.
        for (int f = 0; f < (int)m.factors.size(); ++f)
            if (find(m.factors[f].vars.begin(), m.factors[f].vars.end(),
                     st.var) != m.factors[f].vars.end() &&
                find(live.begin(), live.end(), f) == live.end())
                live.push_back(f);
        for (int f : live)
            if (slots[f] < 0) {
                if (busy == ~uint64_t(0)) {
                    s.packed = false;
                    return s;
                }
                slots[f] = countr_zero(~busy);
                busy |= uint64_t(1) << slots[f];
            }
        for (int f : live) {
            uint64_t bit = uint64_t(1) << slots[f];
            if (m.factors[f].mine)
                st.mineMask |= bit;
            if (m.factors[f].mine && m.factors[f].weight > 1)
                st.extraMineWeights.push_back({bit, m.factors[f].weight - 1});
            if (find(m.factors[f].vars.begin(), m.factors[f].vars.end(),
                     st.var) != m.factors[f].vars.end())
                st.touchMask |= bit;
            if (find(st.newFactors.begin(), st.newFactors.end(), f) ==
                st.newFactors.end()) {
                (m.factors[f].mine ? st.closeMines : st.closeTargets) |= bit;
                if (!m.factors[f].mine && m.factors[f].weight > 1)
                    st.extraTargetWeights.push_back(
                        {bit, m.factors[f].weight - 1});
                busy &= ~bit;
                slots[f] = -1;
            }
        }
        // Feasible dual for the remaining target-cover problem, in twelfths.
        for (int f : st.newFactors)
            st.liveWeights.push_back(
                {uint64_t(1) << slots[f], m.factors[f].weight});
        // A future chord has capacity 12; paying a direct click also costs 12.
        vector<pair<int, int>> remaining;
        for (int f = 0; f < (int)m.factors.size(); ++f)
            if (!m.factors[f].mine && fl[f] > stepIndex) {
                int degree = 0;
                for (int v : m.factors[f].vars)
                    degree += pos[v] > stepIndex;
                remaining.push_back({degree, f});
            }
        sort(remaining.begin(), remaining.end());
        vector<int> capacity(n, 12);
        array<uint64_t, 13> masks{};
        for (auto [degree, f] : remaining) {
            (void)degree;
            int weight = 12;
            for (int v : m.factors[f].vars)
                if (pos[v] > stepIndex)
                    weight = min(weight, capacity[v]);
            if (!weight)
                continue;
            for (int v : m.factors[f].vars)
                if (pos[v] > stepIndex)
                    capacity[v] -= weight;
            if (ff[f] > stepIndex)
                st.boundConstant += weight;
            else
                masks[weight] |= uint64_t(1) << slots[f];
        }
        for (int w = 1; w <= 12; ++w)
            if (masks[w])
                st.boundMasks.push_back({masks[w], w});
        // Factors with the same remaining scope have the same future OR value.
        // For equal weights, only (#unpaid mines - #uncovered targets) matters.
        {
            map<pair<vector<int>, int>, FactorFold> groups;
            for (int f : st.newFactors) {
                vector<int> scope;
                for (int v : m.factors[f].vars)
                    if (pos[v] > stepIndex)
                        scope.push_back(v);
                sort(scope.begin(), scope.end());
                auto &group = groups[{scope, m.factors[f].weight}];
                group.weight = m.factors[f].weight;
                (m.factors[f].mine ? group.mines : group.targets) |=
                    uint64_t(1) << slots[f];
            }
            for (auto &[scope, group] : groups) {
                (void)scope;
                int mines = popcount(group.mines),
                    targets = popcount(group.targets);
                if (mines + targets < 2)
                    continue;
                group.targetCount = targets;
                for (int balance = -targets; balance <= mines; ++balance) {
                    uint64_t remaining =
                                 balance < 0 ? group.targets : group.mines,
                             zeros = 0;
                    for (int k = 0; k < abs(balance); ++k) {
                        zeros |= remaining & -remaining;
                        remaining &= remaining - 1;
                    }
                    group.zeroMasks.push_back(zeros);
                }
                st.folds.push_back(std::move(group));
            }
        }
        for (int z = n; z < total; ++z)
            if (!m.edges[z].empty() && first[z] > stepIndex)
                st.futureZero = true;
        ++stepIndex;
    }
    // Geometric conditional dominance. All safe squares opened by a chord at
    // b, except possibly one, are also opened by an already selected adjacent
    // chord at a. Deleting b saves its chord click; its one private square can
    // need either a direct click or one extra component seed, never both.
    vector<int> candidateAt(m.b.w * m.b.h, -1);
    for (int i = 0; i < n; ++i) candidateAt[m.cells[i]] = i;
    for (auto &st : s.steps) {
        int b = m.cells[st.var];
        for (int neighbor : m.b.adj[b]) {
            int a = candidateAt[neighbor];
            if (a < 0 || pos[a] >= pos[st.var]) continue;
            int exclusive = 0;
            auto outside = [&](int cell) {
                if (cell == m.cells[a]) return false;
                return find(m.b.adj[m.cells[a]].begin(),
                            m.b.adj[m.cells[a]].end(), cell) ==
                       m.b.adj[m.cells[a]].end();
            };
            exclusive += outside(b);
            for (int cell : m.b.adj[b])
                if (!m.b.mine[cell]) exclusive += outside(cell);
            if (exclusive <= 1)
                st.chordDominators.push_back(a);
        }
    }
    return s;
}
} // namespace minclicks::detail
