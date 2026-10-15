#include "../exact.hpp"
#include "decompose.hpp"
#include "state.hpp"
#include <memory>
namespace minclicks::detail {
using Options = ExactOptions;
struct Entry {
    int cost;
    string chosen;
};
struct Result {
    bool exact = false;
    int best = 0;
    string chosen, reason;
    size_t peak = 1, transitions = 0;
    size_t dominated = 0;
    int completed = 0;
    double elapsed = 0;
};
static Result initial(const Model &m, const Options &opt) {
    Result result;
    int n = (int)m.cells.size();
    result.chosen = string((n + 7) / 8, '\0');
    result.best = m.evaluate(result.chosen);
    opt.report("heuristic", 0, n, 0, 0, result.best, 0, 0, true);
    // Deterministic improving one-flip search gives an initial feasible bound.
    for (;;) {
        int best = result.best, arg = -1;
        for (int i = 0; i < n; ++i) {
            flip(result.chosen, i);
            int c = m.evaluate(result.chosen);
            flip(result.chosen, i);
            if (c < best) {
                best = c;
                arg = i;
            }
            if ((i & 63) == 0)
                opt.report("heuristic", 0, n, 0, 0, result.best, 0, 0);
        }
        if (arg < 0)
            break;
        flip(result.chosen, arg);
        result.best = best;
    }
    // A chord that is unprofitable alone can become useful with shared flags
    // and a shared seed. Descending from dense sets escapes that local minimum.
    mt19937 rng(0x5eed);
    vector<int> order(n);
    iota(order.begin(), order.end(), 0);
    for (int start = 0; start < 4; ++start) {
        string chosen((n + 7) / 8, '\0');
        for (int i = 0; i < n; ++i)
            if (start == 0 || rng() % 4 < unsigned(start))
                flip(chosen, i);
        int cost = m.evaluate(chosen);
        bool improved = true;
        for (int pass = 0; pass < 12 && improved; ++pass) {
            improved = false;
            for (int j = n - 1; j > 0; --j)
                swap(order[j], order[rng() % unsigned(j + 1)]);
            for (int i : order) {
                bool selected = ((uint8_t)chosen[i / 8] >> (i % 8) & 1);
                flip(chosen, i);
                int value = m.evaluate(chosen);
                if (value < cost || (value == cost && selected)) {
                    improved |= value < cost;
                    cost = value;
                } else
                    flip(chosen, i);
            }
        }
        if (cost < result.best) {
            result.best = cost;
            result.chosen = std::move(chosen);
        }
        opt.report("heuristic", 0, n, 0, 0, result.best, 0, 0);
    }
    return result;
}
static Result solve_reference(const Model &m, const Schedule &sched,
                              const Options &opt) {
    auto start = Clock::now();
    Result result = initial(m, opt);
    int n = (int)m.cells.size();
    if (opt.progress)
        cerr << "Initial upper bound: " << result.best << '\n';
    unordered_map<string, Entry> states, next;
    states.emplace("", Entry{m.base, string((n + 7) / 8, '\0')});
    double lastLog = seconds(start);
    for (const Step &st : sched.steps) {
        if (opt.timeLimit > 0 && seconds(start) >= opt.timeLimit) {
            result.reason = "time limit";
            break;
        }
        // Byte labels permit up to 254 simultaneous connectivity entries.
        if (st.expanded.size() > 254) {
            result.reason = "connectivity frontier exceeds 254 entries";
            break;
        }
        next.clear();
        next.reserve(opt.maxStates ? min(opt.maxStates, states.size() * 2)
                                   : states.size() * 2);
        bool stopped = false;
        for (const auto &[key, entry] : states) {
            for (int take = 0; take <= 1; ++take) {
                if (take) {
                    bool dominated = false;
                    for (int earlier : st.chordDominators)
                        if ((uint8_t)entry.chosen[earlier / 8] >> (earlier % 8) & 1) {
                            dominated = true;
                            break;
                        }
                    if (dominated) continue;
                }
                ++result.transitions;
                array<uint8_t, 256> labels{}, rename{}, present{}, survive{};
                uint8_t highest = 0;
                int old = (int)st.before.size(),
                    count = (int)st.expanded.size();
                for (int j = 0; j < old; ++j) {
                    labels[j] = (uint8_t)key[j];
                    highest = max(highest, labels[j]);
                }
                for (int j = old; j < count - 1; ++j)
                    labels[j] = ++highest;
                if (take) {
                    uint8_t component = ++highest;
                    labels[count - 1] = component;
                    for (int j : st.neighbors)
                        if (labels[j]) {
                            uint8_t merged = labels[j];
                            for (int k = 0; k < count; ++k)
                                if (labels[k] == merged)
                                    labels[k] = component;
                        }
                }
                for (int j = 0; j < count; ++j)
                    present[labels[j]] = 1;
                for (int j : st.keep)
                    survive[labels[j]] = 1;
                int cost = entry.cost + take;
                for (int j = 1; j <= highest; ++j)
                    cost += present[j] && !survive[j];
                int nc = (int)st.after.size();
                string out(nc + (st.newFactors.size() + 7) / 8, '\0');
                uint8_t fresh = 0;
                for (int j = 0; j < nc; ++j) {
                    uint8_t label = labels[st.keep[j]];
                    if (label && !rename[label])
                        rename[label] = ++fresh;
                    out[j] = char(rename[label]);
                }
                for (int f = 0; f < (int)st.factorOld.size(); ++f) {
                    int prev = st.factorOld[f];
                    bool used =
                        (take && st.factorTouch[f]) ||
                        (prev >= 0 &&
                         ((uint8_t)key[old + prev / 8] >> (prev % 8) & 1));
                    if (st.factorClose[f] >= 0)
                        cost += (used == bool(st.factorClose[f])) *
                                st.factorWeight[f];
                    else if (used) {
                        int j = st.factorKeep[f];
                        out[nc + j / 8] |= char(1u << (j % 8));
                    }
                }
                if (cost >= result.best)
                    continue;
                auto it = next.find(out);
                if (it == next.end()) {
                    string chosen = entry.chosen;
                    if (take)
                        flip(chosen, st.var);
                    next.emplace(std::move(out),
                                 Entry{cost, std::move(chosen)});
                    if (opt.maxStates && next.size() > opt.maxStates) {
                        result.reason = "state limit";
                        stopped = true;
                        break;
                    }
                } else if (cost < it->second.cost) {
                    it->second.cost = cost;
                    it->second.chosen = entry.chosen;
                    if (take)
                        flip(it->second.chosen, st.var);
                }
            }
            if (stopped)
                break;
            if (opt.onProgress && (result.transitions & 16383) == 0)
                opt.report("search", result.completed, n, next.size(),
                           max(result.peak, next.size()), result.best,
                           seconds(start), result.transitions);
            if ((result.transitions & 16383) == 0 && opt.timeLimit > 0 &&
                seconds(start) >= opt.timeLimit) {
                result.reason = "time limit";
                stopped = true;
                break;
            }
        }
        result.peak = max(result.peak, next.size());
        if (stopped)
            break;
        states.swap(next);
        ++result.completed;
        opt.report("search", result.completed, n, states.size(), result.peak,
                   result.best, seconds(start), result.transitions);
        if (opt.progress && seconds(start) - lastLog >= 2) {
            cerr << "DP " << result.completed << '/' << n << ": "
                 << states.size() << " states, " << seconds(start) << " s\n";
            lastLog = seconds(start);
        }
        if (states.empty()) {
            result.exact = true;
            break;
        }
    }
    if (result.completed == n) {
        result.exact = true;
        if (!states.empty()) {
            const auto &entry = states.at("");
            if (entry.cost < result.best) {
                result.best = entry.cost;
                result.chosen = entry.chosen;
            }
        }
    }
    result.elapsed = seconds(start);
    return result;
}

static Result solve_packed(const Model &m, const Schedule &sched,
                           const Options &opt) {
    auto start = Clock::now();
    Result result = initial(m, opt);
    int n = (int)m.cells.size(), words = (n + 63) / 64;
    if (opt.progress)
        cerr << "Initial upper bound: " << result.best << '\n';
    FlatTable states(words), next(words);
    vector<uint64_t> empty(words);
    // One exact transition entry per connectivity ID, shared by factor states.
    vector<ConnectionCacheEntry> connectionCache(64);
    vector<uint64_t> future(words, ~uint64_t(0));
    states.insert({}, m.base, empty.data());
    double lastLog = seconds(start);
    for (const Step &st : sched.steps) {
        if (opt.timeLimit > 0 && seconds(start) >= opt.timeLimit) {
            result.reason = "time limit";
            break;
        }
        if (connectionCache.size() < states.connections.keys.size())
            connectionCache.resize(states.connections.keys.size());
        next.clear();
        bool stopped = false;
        for (size_t index = 0; index < states.nodes.size(); ++index) {
            const auto &entry = states.nodes[index];
            auto &cached = connectionCache[entry.connection];
            if (cached.generation != result.completed + 1) {
                cached.generation = result.completed + 1;
                cached.next = connectionTransitions(states.connections.unpack(entry.connection), st);
                cached.target.fill(~uint32_t(0));
            }
            for (int take = 0; take <= 1; ++take) {
                if (take) {
                    bool dominated = false;
                    const uint64_t *chosen = states.choices.data() + index * words;
                    for (int earlier : st.chordDominators)
                        if (chosen[earlier / 64] >> (earlier % 64) & 1) {
                            dominated = true;
                            break;
                        }
                    if (dominated) continue;
                }
                ++result.transitions;
                const auto &connection = cached.next[take];
                PackedKey out{connection.lo, connection.hi, 0};
                uint64_t factors =
                    entry.factors | (take ? st.touchMask : 0);
                // Charge a flag on its first use, while retaining its OR bit
                // until last use so later chords share it for free.
                int cost =
                    entry.cost + take + connection.seeds +
                    popcount((factors & ~entry.factors) & st.mineMask) +
                    popcount(~factors & st.closeTargets);
                for (auto [mask, weight] : st.extraMineWeights)
                    if ((factors & ~entry.factors) & mask)
                        cost += weight;
                for (auto [mask, weight] : st.extraTargetWeights)
                    if (~factors & mask)
                        cost += weight;
                if (cost >= result.best)
                    continue;
                out.factors = factors & ~(st.closeMines | st.closeTargets);
                for (const auto &group : st.folds) {
                    int mines = popcount(group.mines & ~out.factors),
                        targets = popcount(group.targets & ~out.factors);
                    cost += min(mines, targets) * group.weight;
                    out.factors =
                        (out.factors | group.mines | group.targets) &
                        ~group.zeroMasks[mines - targets + group.targetCount];
                }
                {
                    int lower = st.boundConstant;
                    for (auto [mask, weight] : st.boundMasks)
                        lower += popcount(~out.factors & mask) * weight;

                    lower = (lower + 11) / 12 +
                            int(st.futureZero || connection.live);
                    if (cost + lower >= result.best)
                        continue;
                }
                if (cached.target[take] == ~uint32_t(0))
                    cached.target[take] = next.connections.intern(out.lo, out.hi);
                next.insertPrepared(cached.target[take], out.factors, cost,
                                    states.choices.data() + index * words,
                                    take ? st.var : -1);
                if (opt.maxStates && next.nodes.size() > opt.maxStates) {
                    result.reason = "state limit";
                    stopped = true;
                    break;
                }
            }
            if (stopped)
                break;
            if (opt.onProgress && (result.transitions & 16383) == 0)
                opt.report("search", result.completed, n, next.nodes.size(),
                           max(result.peak, next.nodes.size()), result.best,
                           seconds(start), result.transitions);
            if ((result.transitions & 16383) == 0 && opt.timeLimit > 0 &&
                seconds(start) >= opt.timeLimit) {
                result.reason = "time limit";
                stopped = true;
                break;
            }
        }
        result.peak = max(result.peak, next.nodes.size());
        if (!stopped)
            result.dominated += next.pruneFactors(st);
        future[st.var / 64] &= ~(uint64_t(1) << (st.var % 64));
        // Turn sampled prefix solutions into complete legal solutions by using
        // the incumbent's decisions on the suffix. This only improves an upper
        // bound; no state is lost and no heuristic result is called optimal.
        if (!next.nodes.empty() && (stopped || result.completed % 8 == 7 ||
                                    result.completed == n - 1)) {
            size_t minimum = 0;
            for (size_t i = 1; i < next.nodes.size(); ++i)
                if (next.nodes[i].cost < next.nodes[minimum].cost)
                    minimum = i;
            size_t stride = max(size_t(1), next.nodes.size() / 128);
            auto complete = [&](size_t index) {
                string chosen = result.chosen;
                for (int i = 0; i < n; ++i) {
                    if (!(future[i / 64] >> (i % 64) & 1)) {
                        bool take =
                            next.choices[index * words + i / 64] >> (i % 64) &
                            1;
                        bool had = (uint8_t)chosen[i / 8] >> (i % 8) & 1;
                        if (take != had)
                            flip(chosen, i);
                    }
                }
                int cost = m.evaluate(chosen);
                if (cost < result.best) {
                    result.best = cost;
                    result.chosen = std::move(chosen);
                }
            };
            complete(minimum);
            for (size_t i = 0; i < next.nodes.size(); i += stride)
                complete(i);
        }
        if (stopped)
            break;
        swap(states, next);
        ++result.completed;
        opt.report("search", result.completed, n, states.nodes.size(),
                   result.peak, result.best, seconds(start),
                   result.transitions);
        if (opt.progress && seconds(start) - lastLog >= 2) {
            cerr << "DP " << result.completed << '/' << n << ": "
                 << states.nodes.size() << " states, " << seconds(start)
                 << " s\n";
            lastLog = seconds(start);
        }
        if (states.nodes.empty()) {
            result.exact = true;
            break;
        }
    }
    if (result.completed == n) {
        result.exact = true;
        if (!states.nodes.empty() && states.nodes[0].cost < result.best) {
            result.best = states.nodes[0].cost;
            fill(result.chosen.begin(), result.chosen.end(), '\0');
            for (int i = 0; i < n; ++i)
                if (states.choices[i / 64] >> (i % 64) & 1)
                    flip(result.chosen, i);
        }
    }
    result.elapsed = seconds(start);
    return result;
}
static vector<Action> witness(const Model &m, const string &chosen) {
    const Board &b = m.b;
    int n = (int)m.cells.size();
    vector<bool> selected(b.w * b.h), flags(b.w * b.h), open(b.w * b.h),
        done(b.w * b.h);
    vector<Action> actions;
    for (int i = 0; i < n; ++i)
        if ((uint8_t)chosen[i / 8] >> (i % 8) & 1) {
            selected[m.cells[i]] = true;
            for (int q : b.adj[m.cells[i]])
                if (b.mine[q])
                    flags[q] = true;
        }
    for (int p = 0; p < b.w * b.h; ++p)
        if (flags[p])
            actions.push_back({'F', p});
    auto reveal = [&](int p) {
        if (b.mine[p])
            throw logic_error("Witness opens a mine");
        open[p] = true;
        if (b.island[p] >= 0) {
            int z = b.island[p];
            for (int q : b.zeros[z])
                open[q] = true;
            for (int q : b.borders[z])
                open[q] = true;
        }
    };
    auto propagate = [&]() {
        bool changed = true;
        while (changed) {
            changed = false;
            for (int p = 0; p < b.w * b.h; ++p)
                if (selected[p] && open[p] && !done[p]) {
                    actions.push_back({'C', p});
                    done[p] = true;
                    changed = true;
                    for (int q : b.adj[p])
                        if (!b.mine[q])
                            reveal(q);
                }
        }
    };
    // Prefer an island as seed whenever the component contains one.
    for (const auto &z : b.zeros)
        if (!open[z[0]]) {
            actions.push_back({'O', z[0]});
            reveal(z[0]);
            propagate();
        }
    for (int p = 0; p < b.w * b.h; ++p)
        if (selected[p] && !done[p]) {
            actions.push_back({'O', p});
            reveal(p);
            propagate();
        }
    for (int p = 0; p < b.w * b.h; ++p)
        if (!b.mine[p] && !open[p]) {
            actions.push_back({'O', p});
            reveal(p);
        }
    return actions;
}
// Iteratively remove candidates certified by a swap or a left-click bound.
// A swap replacement must cover every target/zero unit, flag no new mine, and
// retain every propagation contact. Relations can change after each removal.
static Model reduceCandidates(const Board &b) {
        Model m(b);
        int n = int(m.cells.size()), z = int(b.zeros.size());
        vector<vector<int>> contacts(n), bases(n), mines(n);
        for (int i = 0; i < n; ++i) {
            int p = m.cells[i];
            for (int q : b.adj[p]) {
                if (b.mine[q]) mines[i].push_back(q);
                else if (b.island[q] < 0 && b.number[q] > 0 &&
                         binary_search(b.targets.begin(), b.targets.end(), q))
                    bases[i].push_back(z + q);
            }
            if (binary_search(b.targets.begin(), b.targets.end(), p))
                bases[i].push_back(z + p);
            for (int island = 0; island < z; ++island)
                if (binary_search(m.edges[i].begin(), m.edges[i].end(), n + island))
                    bases[i].push_back(island);
            for (int j : m.edges[i])
                if (j < n) contacts[i].push_back(j);
            unique_sort(bases[i]);
            unique_sort(mines[i]);
        }
        for (int island = n; island < int(m.edges.size()); ++island)
            for (int i : m.edges[island])
                for (int j : m.edges[island])
                    if (i != j) contacts[i].push_back(j);
        for (auto &v : contacts) unique_sort(v);
        // Geometry does not change when candidates are deleted. Keep the
        // original IDs and mask dead vertices, instead of reconstructing the
        // model and every relation after each certificate.
        vector<uint8_t> alive(n, 1);
        int words = (n + 63) / 64;
        vector<uint64_t> active(words, ~uint64_t(0));
        vector<vector<uint64_t>> contactBits(n, vector<uint64_t>(words));
        for (int i = 0; i < n; ++i)
            for (int j : contacts[i])
                contactBits[i][j / 64] |= uint64_t(1) << (j % 64);
        vector<int> mineUsers(b.w * b.h);
        for (const auto &scope : mines)
            for (int cell : scope) ++mineUsers[cell];
    for (;;) {
        int victim = -1;
        for (int i = 0; i < n && victim < 0; ++i)
            if (alive[i])
            for (int j : contacts[i]) {
                if (!alive[j]) continue;
                if (!subset(bases[i], bases[j]) ||
                    !subset(mines[j], mines[i])) continue;
                bool good = true;
                for (int word = 0; word < words; ++word) {
                    uint64_t required = contactBits[i][word] & active[word];
                    if (word == j / 64) required &= ~(uint64_t(1) << (j % 64));
                    if (required & ~contactBits[j][word]) {
                        good = false;
                        break;
                    }
                }
                if (good) {
                    victim = i;
                    break;
                }
            }
        // A chord can also be redundant without a single replacement. For any
        // selected neighborhood X, deleting v can create at most cc(G[X])
        // seeds. Representatives of those components form an independent set.
        // Maximize that liability minus base units already covered by X.
        if (victim < 0) {
            for (int v = 0; v < n && victim < 0; ++v) {
                if (!alive[v]) continue;
                vector<int> adjacent;
                for (int other : contacts[v])
                    if (alive[other]) adjacent.push_back(other);
                if (adjacent.size() > 63 || bases[v].size() > 63) continue;
                int privateMines = 0;
                for (int cell : mines[v])
                    privateMines += mineUsers[cell] == 1;
                int threshold = 2 + privateMines - int(bases[v].size());
                if (threshold < 0) continue;
                if (threshold >= int(adjacent.size())) {
                    victim = v;
                    break;
                }
                vector<uint64_t> links(adjacent.size()), hits(adjacent.size());
                for (size_t i = 0; i < adjacent.size(); ++i) {
                    int other = adjacent[i];
                    for (size_t j = 0; j < adjacent.size(); ++j)
                        if (contactBits[other][adjacent[j] / 64] >>
                            (adjacent[j] % 64) & 1)
                            links[i] |= uint64_t(1) << j;
                    for (size_t j = 0; j < bases[v].size(); ++j)
                        if (binary_search(bases[other].begin(),
                                          bases[other].end(), bases[v][j]))
                            hits[i] |= uint64_t(1) << j;
                }
                int best = 0;
                int visited = 0;
                bool exhausted = false;
                auto search = [&](auto &&self, uint64_t available, int chosen,
                                  uint64_t covered) -> void {
                    if (best > threshold || exhausted) return;
                    if (++visited > 20000) {
                        exhausted = true;
                        return;
                    }
                    best = max(best, chosen - popcount(covered));
                    if (best > threshold || !available ||
                        chosen + popcount(available) - popcount(covered) <= best)
                        return;
                    int pivot = countr_zero(available), pivotDegree = -1;
                    for (uint64_t scan = available; scan; scan &= scan - 1) {
                        int at = countr_zero(scan);
                        int degree = popcount(links[at] & available);
                        if (degree > pivotDegree) {
                            pivot = at;
                            pivotDegree = degree;
                        }
                    }
                    uint64_t bit = uint64_t(1) << pivot;
                    self(self, available & ~bit & ~links[pivot], chosen + 1,
                         covered | hits[pivot]);
                    self(self, available & ~bit, chosen, covered);
                };
                uint64_t all = adjacent.empty() ? 0 :
                    (uint64_t(1) << adjacent.size()) - 1;
                search(search, all, 0, 0);
                if (!exhausted && best <= threshold) victim = v;
            }
        }
        if (victim < 0) {
            return Model(m, alive);
        }
        alive[victim] = 0;
        active[victim / 64] &= ~(uint64_t(1) << (victim % 64));
        for (int cell : mines[victim]) --mineUsers[cell];
    }
}
static Result searchModel(const Model &m, const Options &opt, Schedule &sched,
                          bool wholeBoard = true) {
    int emptyCost = m.evaluate(string((m.cells.size() + 7) / 8, '\0'));
    OrderPlan plan = planOrder(m, "columns");
    vector<OrderPlan> alternatives;
    if (wholeBoard && m.cells.size() >= 250) alternatives.push_back(plan);
    opt.report("ordering", 0, int(m.cells.size()), 0, 0, emptyCost, 0, 0, true);
    vector<string> orders = {"rows", "columns-reverse", "rows-reverse"};
    if (m.b.h <= m.b.w)
        orders.insert(orders.end(), {"columns-dp", "columns-dp-reverse",
                                     "columns-dp2", "columns-dp2-reverse"});
    if (m.b.w <= m.b.h)
        orders.insert(orders.end(), {"rows-dp", "rows-dp-reverse",
                                     "rows-dp2", "rows-dp2-reverse"});
    for (const auto &name : orders) {
        opt.report("ordering", 0, int(m.cells.size()), 0, 0, emptyCost, 0, 0);
        auto candidate = planOrder(m, name);
        if (wholeBoard && m.cells.size() >= 250) alternatives.push_back(candidate);
        if (candidate.score < plan.score ||
            (candidate.score == plan.score &&
             candidate.totalScore < plan.totalScore))
            plan = std::move(candidate);
    }
    if (m.cells.size() >= 64)
        for (bool rows : {false, true})
            for (bool reverse : {false, true}) {
                auto candidate = dynamicBandOrder(m, rows, reverse);
                if (wholeBoard && m.cells.size() >= 250) alternatives.push_back(candidate);
                if (candidate.score < plan.score ||
                    (candidate.score == plan.score && candidate.totalScore < plan.totalScore))
                    plan = std::move(candidate);
            }
    // Subset refinement has a fixed planning cost. Reserve it for frontiers
    // wide enough that reducing the exponential search can repay that cost.
    const double rawWork = plan.totalScore;
    const auto rawOrder = plan.order;
    if (plan.score >= 60)
        plan = refineOrder(m, std::move(plan));
    // Wide boards need a global comparison of the whole frontier trajectory.
    // Width alone counts dependent live factors as independent and can prefer
    // broad bands that produce far more DP states than narrower sweeps.
    // The rank calculation costs more than ordinary order scoring, so only
    // spend it when the width model itself predicts a substantial DP search.
    if (wholeBoard && m.cells.size() >= 250 && rawWork >= 1'000'000) {
        vector<int> shortlist;
        for (int i = 0; i < int(alternatives.size()); ++i)
            if (alternatives[i].order != rawOrder &&
                alternatives[i].totalScore <= rawWork * 1.2)
                shortlist.push_back(i);
        if (!shortlist.empty()) {
            const double baselineWork = estimateFrontierWork(m, plan);
            vector<pair<double, int>> ranked;
            ranked.reserve(shortlist.size());
            for (int i : shortlist)
                ranked.emplace_back(estimateFrontierWork(m, alternatives[i]), i);
            sort(ranked.begin(), ranked.end());
            double bestWork = baselineWork;
            OrderPlan best = plan;
            // Local window refinement crosses strip boundaries. Apply it to the
            // best full-order alternatives, including those omitted by the old
            // peak-width selector, then compare their estimated total work.
            for (int k = 0; k < min(2, int(ranked.size())); ++k) {
                auto candidate = std::move(alternatives[ranked[k].second]);
                double work = ranked[k].first;
                if (candidate.score >= 60) {
                    auto refined = refineOrder(m, candidate);
                    double refinedWork = estimateFrontierWork(m, refined);
                    if (refinedWork < work) {
                        candidate = std::move(refined);
                        work = refinedWork;
                    }
                }
                if (work < bestWork * 0.95) {
                    bestWork = work;
                    best = std::move(candidate);
                }
            }
            plan = std::move(best);
        }
    }
    sched = schedule(m, plan);
    return sched.packed ? solve_packed(m, sched, opt)
                        : solve_reference(m, sched, opt);
}
} // namespace minclicks::detail
namespace minclicks {
ExactResult solveExact(const Board &b, const ExactOptions &opt) {
    using namespace detail;
    auto started = Clock::now();
    opt.report("preparing", 0, 0, 0, 0, -1, 0, 0, true);
    Model m = b.w * b.h <= 81 ? Model(b) : reduceCandidates(b);
    auto groups = independentParts(m);
    // A two-way split of a large reduced board often duplicates a mandatory
    // zero across subproblems and can make each piece's order much worse.
    if (groups.size() == 2 && m.cells.size() > 150) groups.clear();
    ExactResult out;
    string chosen((m.cells.size() + 7) / 8, '\0');
    if (groups.size() <= 1) {
        Schedule sched;
        auto r = searchModel(m, opt, sched, true);
        out.exact = r.exact;
        out.clicks = r.best;
        out.reason = r.reason;
        chosen = std::move(r.chosen);
        out.peak = r.peak;
        out.transitions = r.transitions;
        out.dominated = r.dominated;
        out.completed = r.completed;
        out.elapsed = r.elapsed;
        out.order = sched.name;
        out.engine = sched.packed ? "packed" : "reference";
        out.maxConn = sched.maxConn;
        out.maxFactors = sched.maxFactors;
    } else {
        vector<Model> pieces;
        pieces.reserve(groups.size());
        vector<int> costs;
        int zeroCopies = 0;
        for (const auto &vars : groups) {
            pieces.emplace_back(m, vars);
            const auto &piece = pieces.back();
            zeroCopies += int(piece.edges.size() - piece.cells.size());
            costs.push_back(piece.evaluate(string((vars.size() + 7) / 8, '\0')));
        }
        // Duplicating a mandatory articulation zero adds one component for
        // every extra copy, for EVERY selection of candidate chords.
        int nonisolatedZeros = int(m.edges.size() - m.cells.size()) - m.isolatedZeros;
        int constant = m.base - (zeroCopies - nonisolatedZeros);
        int best = constant + accumulate(costs.begin(), costs.end(), 0);
        out.exact = true;
        out.engine = "packed";
        out.order = "components(" + to_string(pieces.size()) + ")";
        for (size_t i = 0; i < pieces.size(); ++i) {
            ExactOptions local = opt;
            if (opt.timeLimit > 0)
                local.timeLimit = max(1e-9, opt.timeLimit - out.elapsed);
            if (opt.onProgress)
                local.onProgress = [&](const Progress &p) {
                    bool hasBound = string(p.phase) == "heuristic" || string(p.phase) == "search";
                    int upper = hasBound && p.best >= 0 ? best - costs[i] + p.best : best;
                    opt.report(p.phase, out.completed + p.completed, int(m.cells.size()), p.states,
                               max(out.peak, p.peak), upper, seconds(started),
                               out.transitions + p.transitions,
                               string(p.phase) == "heuristic" && p.completed == 0);
                };
            Schedule sched;
            auto r = searchModel(pieces[i], local, sched, false);
            best += r.best - costs[i];
            costs[i] = r.best;
            for (int v = 0; v < int(groups[i].size()); ++v)
                if ((uint8_t)r.chosen[v / 8] >> (v % 8) & 1)
                    flip(chosen, groups[i][v]);
            out.peak = max(out.peak, r.peak);
            out.transitions += r.transitions;
            out.dominated += r.dominated;
            out.completed += r.completed;
            out.elapsed += r.elapsed;
            out.maxConn = max(out.maxConn, sched.maxConn);
            out.maxFactors = max(out.maxFactors, sched.maxFactors);
            if (!sched.packed)
                out.engine = "reference";
            if (!r.exact) {
                out.exact = false;
                out.reason = r.reason;
                break;
            }
        }
        out.clicks = best;
    }
    if (m.evaluate(chosen, &out.breakdown) != out.clicks)
        throw logic_error("Internal objective mismatch");
    if (opt.includeActions) {
        out.actions = witness(m, chosen);
        if (int(out.actions.size()) != out.clicks)
            throw logic_error("Internal witness cost mismatch");
    }
    out.candidates = int(m.cells.size());
    out.removed = m.removed;
    opt.report(out.exact ? "complete" : "limited", out.completed, out.candidates,
               0, out.peak, out.clicks, out.elapsed, out.transitions, true);
    return out;
}
} // namespace minclicks
