#pragma once
#include "board.hpp"

namespace minclicks {
HeuristicResult hzini(const Board &board);
// LZini is min(legacy Wom ZiNi, HZiNi), including the chosen witness.
HeuristicResult lzini(const Board &board);
struct LegacyZiniResults {
    HeuristicResult hzini, lzini;
};
LegacyZiniResults
legacyZini(const Board &board); // Avoid computing HZiNi twice.
HeuristicResult eightWayZini(const Board &board);
// Same count and traversal choices; omit action materialization for filtering.
int eightWayZiniClicks(const Board &board);
} // namespace minclicks
