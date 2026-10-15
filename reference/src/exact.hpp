#pragma once
#include "board.hpp"
#include <array>
#include <chrono>
#include <functional>

namespace minclicks {
struct Progress {
    const char *phase;
    int completed, total;
    size_t states, peak;
    int best;
    double elapsed;
    size_t transitions;
};
struct ExactOptions {
    double timeLimit = 0; // Zero means unlimited.
    size_t maxStates = 0;
    bool progress = true; // Human-readable stderr progress.
    bool includeActions = true; // Disable witness construction for count-only callers.
    std::function<void(const Progress &)> onProgress;
    void report(const char *phase, int completed, int total, size_t states,
                size_t peak, int best, double elapsed, size_t transitions,
                bool force = false) const {
        if (!onProgress)
            return;
        auto now = std::chrono::steady_clock::now();
        if (!force && now - lastProgress < std::chrono::milliseconds(200))
            return;
        lastProgress = now;
        onProgress({phase, completed, total, states, peak, best, elapsed,
                    transitions});
    }

  private:
    mutable std::chrono::steady_clock::time_point lastProgress{};
};
struct ExactResult {
    bool exact = false;
    int clicks = 0;
    std::array<int, 4>
        breakdown{}; // Flags, chords, component seeds, direct targets.
    std::vector<Action> actions;
    size_t peak = 0, transitions = 0, dominated = 0;
    int completed = 0, candidates = 0, removed = 0, maxConn = 0, maxFactors = 0,
        attempts = 1;
    double elapsed = 0;
    std::string order, engine, reason;
};
ExactResult solveExact(const Board &board, const ExactOptions &options = {});
} // namespace minclicks
