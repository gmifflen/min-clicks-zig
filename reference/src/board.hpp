#pragma once

#include <array>
#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

namespace minclicks {
// A tile has at most eight neighbors. Inline storage avoids hundreds of tiny
// allocations per generated board while retaining the original row-major order.
class Neighbors {
    std::array<int, 8> cells{};
    uint8_t count = 0;

  public:
    void push_back(int cell) {
        assert(count < cells.size());
        cells[count++] = cell;
    }
    const int *begin() const { return cells.data(); }
    const int *end() const { return cells.data() + count; }
    std::size_t size() const { return count; }
};
// Row-major cells: p = y * w + x. Mines have number -1; island -1 means
// nonzero.
struct Board {
    int w, h;
    std::vector<int> mine, number, island;
    std::vector<Neighbors> adj;
    std::vector<std::vector<int>> zeros, borders;
    std::vector<int> targets;
    Board(int width, int height, std::vector<int> mines);
    int bv() const;
    int mineCount() const;
    std::string url() const;
};
Board decodeBoard(const std::string &url);
Board randomBoard(int width, int height, int mines, uint32_t seed);
Board randomBoard64(int width, int height, int mines, uint64_t seed);

struct Action {
    char kind;
    int cell;
}; // F flag, O open, C chord; row-major cell.
struct HeuristicResult {
    int clicks = 0;
    std::vector<Action> actions;
};
} // namespace minclicks
