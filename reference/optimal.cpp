// Command-line and WebAssembly adapter. Build with python build.py.
#include "src/board.hpp"
#include "src/exact.hpp"
#include "src/zini.hpp"
#include <cmath>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
// clang-format off
EM_JS(void, browser_progress,
      (const char *phase, int completed, int total, double states, double peak,
       int best, double elapsed, double transitions),
      {
          const callback = Module['onSolverProgress'];
          if (typeof callback === 'function')
              callback({
                  phase : UTF8ToString(phase),
                  completed,
                  total,
                  states,
                  peak,
                  best,
                  elapsed,
                  transitions,
                  heapBytes : HEAPU8.buffer.byteLength
              });
      });
// clang-format on
#endif
using namespace std;
using namespace minclicks;
#ifdef __EMSCRIPTEN__
// Short batches let generation yield to worker cancellation messages.
extern "C" EMSCRIPTEN_KEEPALIVE const char *web_generate(
    int width, int height, int mines, int minBV, int maxBV,
    uint32_t seedLow, uint32_t seedHigh, double minEff) {
    static string response;
    if (width < 1 || width > 99 || height < 1 || height > 99 ||
        mines < 0 || mines > width * height || minBV < 0 ||
        maxBV > 9801 || minBV > maxBV)
        return "{\"error\":\"Invalid generation parameters.\"}";
    try {
        uint64_t seed = (uint64_t(seedHigh) << 32) | seedLow;
        auto began = chrono::steady_clock::now();
        int attempts = 0;
        double maxEff = -1; // percent; -1 when no board reached the 8-way stage
        auto stats = [&]() {
            string s = "{\"attempts\":" + to_string(attempts);
            if (maxEff >= 0) s += ",\"maxEff\":" + to_string(maxEff);
            return s;
        };
        do {
            auto board = randomBoard64(width, height, mines, seed++);
            ++attempts;
            int bv = board.bv();
            if (bv < minBV || bv > maxBV) continue;
            if (minEff > 0) {
                int clicks = eightWayZiniClicks(board);
                double eff = clicks > 0 ? 100.0 * bv / clicks : 0;
                maxEff = max(maxEff, eff);
                if (eff < minEff - 1e-9) continue;
            }
            response = stats() + ",\"url\":\"" + board.url() + "\"}";
            return response.c_str();
        } while (chrono::steady_clock::now() - began < chrono::milliseconds(25));
        response = stats() + "}";
        return response.c_str();
    } catch (const exception &) {
        return "{\"error\":\"Board generation failed.\"}";
    }
}
#endif
static unsigned long long natural(const string &s) {
    if (s.empty() || s.find_first_not_of("0123456789") != string::npos)
        throw runtime_error("Expected nonnegative integer: " + s);
    return stoull(s);
}
int main(int argc, char **argv) {
    try {
        ExactOptions options;
        string input, algorithm = "optimal";
        bool random = false, all = false, json = false, witness = false,
             random64 = false;
        int w = 0, h = 0, mines = 0;
        uint64_t seed = 0;
        for (int i = 1; i < argc; ++i) {
            string a = argv[i];
            auto arg = [&]() {
                if (++i >= argc) throw runtime_error("Missing value for " + a);
                return string(argv[i]);
            };
            auto integer = [&]() {
                auto v = natural(arg());
                if (v > numeric_limits<int>::max())
                    throw runtime_error("Integer out of range");
                return int(v);
            };
            if (a == "--help") {
                cout << "Usage: optimal URL [options]\n"
                     << "       optimal --random WIDTH HEIGHT MINES SEED [--64b] "
                        "[options]\n"
                     << "  --64b       Use mt19937_64 and a uint64 seed for random "
                        "boards\n"
                     << "  --algorithm optimal|8way|lzini|hzini (default optimal)\n"
                     << "  --all       All four algorithms, one JSON object, no "
                        "progress\n"
                     << "  --json      Machine-readable output for one algorithm\n"
                     << "  --witness   Include actions (F flag, O open, C chord)\n"
                     << "  --quiet     Suppress stderr progress\n"
                     << "  --time-limit SECONDS / --max-states N (default 0: "
                        "unlimited)\n"
                     << "Exit: 0 success, 2 exact search limited, 1 invalid "
                        "input/error.\n";
                return 0;
            } else if (a == "--random") {
                random = true;
                w = integer();
                h = integer();
                mines = integer();
                seed = natural(arg());
            } else if (a == "--64b") random64 = true;
            else if (a == "--algorithm") algorithm = arg();
            else if (a == "--all") all = true;
            else if (a == "--json") json = true;
            else if (a == "--quiet") options.progress = false;
            else if (a == "--witness") witness = true;
            else if (a == "--max-states") {
                auto n = natural(arg());
                if (n > numeric_limits<size_t>::max())
                    throw runtime_error("State limit out of range");
                options.maxStates = size_t(n);
            } else if (a == "--time-limit") {
                string v = arg();
                size_t used;
                options.timeLimit = stod(v, &used);
                if (used != v.size() || !isfinite(options.timeLimit) ||
                    options.timeLimit < 0)
                    throw runtime_error("Invalid time limit");
            } else if (a.starts_with("--")) throw runtime_error("Unknown option: " + a);
            else if (input.empty()) input = a;
            else throw runtime_error("Unexpected argument: " + a);
        }
        if (algorithm != "optimal" && algorithm != "8way" && algorithm != "lzini" &&
            algorithm != "hzini")
            throw runtime_error("Unknown algorithm: " + algorithm);
        if (all && algorithm != "optimal")
            throw runtime_error("Choose --all or --algorithm");
        if (random == !input.empty())
            throw runtime_error("Supply either a URL or --random; see --help");
        if (random64 && !random) throw runtime_error("--64b requires --random");
        if (random && !random64 && seed > UINT32_MAX)
            throw runtime_error("Seed out of range");
        if (!input.empty() && input.starts_with("b=")) input = "?" + input;
        Board b = random ? (random64 ? randomBoard64(w, h, mines, seed)
                                     : randomBoard(w, h, mines, uint32_t(seed)))
                         : decodeBoard(input);
        json = json || all;
        if (json) options.progress = false;
#ifdef __EMSCRIPTEN__
        if (!json)
            options.onProgress = [](const Progress &p) {
                browser_progress(p.phase, p.completed, p.total, double(p.states),
                                 double(p.peak), p.best, p.elapsed,
                                 double(p.transitions));
            };
#endif
        ExactResult exact;
        HeuristicResult heuristic;
        LegacyZiniResults legacy;
        HeuristicResult eight;
        if (all || algorithm == "optimal") exact = solveExact(b, options);
        if (all) {
            legacy = legacyZini(b);
            if (witness) eight = eightWayZini(b);
            else eight.clicks = eightWayZiniClicks(b);
        } else if (algorithm == "hzini") heuristic = hzini(b);
        else if (algorithm == "lzini") heuristic = lzini(b);
        else if (algorithm == "8way") {
            if (witness) heuristic = eightWayZini(b);
            else heuristic.clicks = eightWayZiniClicks(b);
        }
        bool isExact = all || algorithm == "optimal";
        const auto &actions = isExact ? exact.actions : heuristic.actions;
        if (json) {
            cout << setprecision(9) << "{\"url\":\"" << b.url()
                 << "\",\"width\":" << b.w << ",\"height\":" << b.h
                 << ",\"mines\":" << b.mineCount() << ",\"three_bv\":" << b.bv()
                 << ",\"status\":\""
                 << (isExact ? (exact.exact ? "optimal" : "resource limit")
                             : "heuristic")
                 << "\"";
            if (isExact)
                cout << ",\"minclicks\":"
                     << (exact.exact ? to_string(exact.clicks) : "null")
                     << ",\"upper_bound\":" << exact.clicks
                     << ",\"peak_states\":" << exact.peak
                     << ",\"solve_seconds\":" << exact.elapsed;
            else
                cout << ",\"algorithm\":\"" << algorithm
                     << "\",\"clicks\":" << heuristic.clicks;
            if (all)
                cout << ",\"8way\":" << eight.clicks
                     << ",\"lzini\":" << legacy.lzini.clicks
                     << ",\"hzini\":" << legacy.hzini.clicks;
            if (witness) {
                auto emit = [&](const vector<Action> &a) {
                    cout << '[';
                    bool comma = false;
                    for (auto v : a) {
                        if (comma) cout << ',';
                        comma = true;
                        cout << "[\"" << v.kind << "\"," << v.cell % b.w << ','
                             << v.cell / b.w << ']';
                    }
                    cout << ']';
                };
                cout << ",\"actions\":";
                if (all) {
                    cout << "{\"optimal\":";
                    emit(actions);
                    cout << ",\"8way\":";
                    emit(eight.actions);
                    cout << ",\"lzini\":";
                    emit(legacy.lzini.actions);
                    cout << ",\"hzini\":";
                    emit(legacy.hzini.actions);
                    cout << '}';
                } else emit(actions);
            }
            cout << "}\n";
        } else {
            cout << "Board: " << b.w << 'x' << b.h << ", " << b.mineCount()
                 << " mines\nURL: " << b.url() << "\n3BV: " << b.bv() << '\n';
            if (isExact) {
                const auto &r = exact;
                const auto &c = r.breakdown;
                cout << "Candidates: " << r.candidates << " (removed " << r.removed
                     << ")\nDP: " << r.order << "\nEngine: " << r.engine << '\n'
                     << "Status: "
                     << (r.exact ? "optimal" : "resource limit: " + r.reason) << '\n'
                     << (r.exact ? "Optimal clicks: " : "Upper bound clicks: ")
                     << r.clicks << '\n'
                     << "Breakdown: " << c[0] << " flags + " << c[1] << " chords + "
                     << c[2] << " chains + " << c[3] << " remaining 3BV\n"
                     << "Peak states: " << r.peak << "\nTransitions: " << r.transitions
                     << "\nCompleted candidates: " << r.completed << '/' << r.candidates
                     << "\nMax connectivity: " << r.maxConn << ", max factors: " << r.maxFactors
                     << "\nFinal order: " << r.order << "\nSolve time: " << r.elapsed
                     << " seconds\nDominated states: " << r.dominated << '\n';
            } else
                cout << "Algorithm: " << algorithm
                     << "\nStatus: heuristic\nUpper bound clicks: " << heuristic.clicks
                     << '\n';
            if (witness)
                for (auto a : actions)
                    cout << "Action: " << a.kind << ' ' << a.cell % b.w << ' '
                         << a.cell / b.w << '\n';
        }
        return isExact && !exact.exact ? 2 : 0;
    } catch (const exception &e) {
        cerr << "Error: " << e.what() << '\n';
        return 1;
    }
}
