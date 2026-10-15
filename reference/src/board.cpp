#include "board.hpp"
#include <algorithm>
#include <numeric>
#include <random>
#include <stdexcept>
namespace minclicks {
using namespace std;
template <class T> static void unique_sort(vector<T> &v) {
    sort(v.begin(), v.end());
    v.erase(unique(v.begin(), v.end()), v.end());
}
Board::Board(int width, int height, vector<int> mines)
    : w(width), h(height), mine(std::move(mines)) {
    if (w < 1 || h < 1 || w > 99 || h > 99 || mine.size() != size_t(w * h) ||
        any_of(mine.begin(), mine.end(),
               [](int v) { return v != 0 && v != 1; }))
        throw invalid_argument("Invalid board dimensions or mine map");
    int n = w * h;
    number.resize(n);
    island.assign(n, -1);
    adj.resize(n);
    for (int p = 0; p < n; ++p) {
        for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
                int x = p % w + dx, y = p / w + dy;
                if ((dx || dy) && x >= 0 && x < w && y >= 0 && y < h)
                    adj[p].push_back(y * w + x);
            }
        for (int q : adj[p])
            number[p] += mine[q];
        if (mine[p])
            number[p] = -1;
    }
    for (int p = 0; p < n; ++p)
        if (number[p] == 0 && island[p] < 0) {
            int z = (int)zeros.size();
            zeros.push_back({p});
            island[p] = z;
            for (size_t i = 0; i < zeros[z].size(); ++i)
                for (int q : adj[zeros[z][i]])
                    if (number[q] == 0 && island[q] < 0) {
                        island[q] = z;
                        zeros[z].push_back(q);
                    }
        }
    borders.resize(zeros.size());
    for (int p = 0; p < n; ++p)
        if (number[p] > 0) {
            bool border = false;
            for (int q : adj[p])
                if (island[q] >= 0) {
                    borders[island[q]].push_back(p);
                    border = true;
                }
            if (!border)
                targets.push_back(p);
        }
    for (auto &v : borders)
        unique_sort(v);
}

int Board::bv() const { return int(zeros.size() + targets.size()); }

int Board::mineCount() const { return int(count(mine.begin(), mine.end(), 1)); }
string Board::url() const {
    string b;
    if (w == 9 && h == 9)
        b = "1";
    else if (w == 16 && h == 16)
        b = "2";
    else if (w == 30 && h == 16)
        b = "3";
    else if (w < 10 && h < 10)
        b = to_string(w) + to_string(h);
    else {
        b = (w < 10 ? "0" : "") + to_string(w) + (h < 10 ? "0" : "") +
            to_string(h);
    }
    string m, alphabet = "0123456789abcdefghijklmnopqrstuv";
    for (size_t i = 0; i < mine.size(); i += 5) {
        int v = 0;
        for (int j = 0; j < 5; ++j)
            v = 2 * v + (i + j < mine.size() ? mine[i + j] : 0);
        m += alphabet[v];
    }
    return "https://llamasweeper.com/#/game/zini-explorer?b=" + b + "&m=" + m;
}
static string parameter(const string &s, const string &name) {
    for (char delimiter : {'?', '&'}) {
        string prefix = string(1, delimiter) + name + "=";
        size_t i = s.find(prefix);
        if (i != string::npos) {
            i += prefix.size();
            return s.substr(i, s.find_first_of("&#", i) - i);
        }
    }
    throw runtime_error("URL missing parameter '" + name + "'");
}
static int integer(const string &s) {
    if (s.empty() || s.find_first_not_of("0123456789") != string::npos)
        throw runtime_error("Expected nonnegative integer: " + s);
    size_t used = 0;
    int v = stoi(s, &used);
    if (used != s.size())
        throw runtime_error("Invalid integer: " + s);
    return v;
}
Board decodeBoard(const string &url) {
    string b = parameter(url, "b"), m = parameter(url, "m");
    int w, h;
    if (b == "1") {
        w = h = 9;
    } else if (b == "2") {
        w = h = 16;
    } else if (b == "3") {
        w = 30;
        h = 16;
    } else if (b.size() == 2 || b.size() == 4) {
        w = integer(b.substr(0, b.size() / 2));
        h = integer(b.substr(b.size() / 2));
    } else
        throw runtime_error("Invalid board size");
    if (w < 1 || h < 1 || w > 99 || h > 99)
        throw runtime_error("Board dimensions must be 1..99");
    if (m.size() * 5 < (size_t)(w * h))
        throw runtime_error("Mine encoding too short");
    vector<int> mines;
    string alphabet = "0123456789abcdefghijklmnopqrstuv";
    for (char c : m) {
        size_t v = alphabet.find(c);
        if (v == string::npos)
            throw runtime_error("Invalid base-32 mine encoding");
        for (int bit = 4; bit >= 0; --bit)
            if (mines.size() < (size_t)(w * h))
                mines.push_back((v >> bit) & 1);
    }
    return Board(w, h, std::move(mines));
}
Board randomBoard(int w, int h, int mines, uint32_t seed) {
    if (w < 1 || h < 1 || w > 99 || h > 99 || mines < 0 || mines > w * h)
        throw invalid_argument("Invalid random board dimensions/mine count");
    vector<int> mine(w * h), order(w * h);
    iota(order.begin(), order.end(), 0);
    mt19937 rng(seed);
    for (int i = w * h - 1; i > 0; --i) {
        uint32_t bound = i + 1, threshold = uint32_t(-bound) % bound, x;
        do {
            x = rng();
        } while (x < threshold);
        swap(order[i], order[x % bound]);
    }
    for (int i = 0; i < mines; ++i)
        mine[order[i]] = 1;
    return Board(w, h, std::move(mine));
}
Board randomBoard64(int w, int h, int mines, uint64_t seed) {
    if (w < 1 || h < 1 || w > 99 || h > 99 || mines < 0 || mines > w * h)
        throw invalid_argument("Invalid random board dimensions/mine count");
    vector<int> mine(w * h), order(w * h);
    iota(order.begin(), order.end(), 0);
    mt19937_64 rng(seed);
    for (int i = w * h - 1; i > 0; --i) {
        uint64_t bound = uint64_t(i) + 1, threshold = uint64_t(-bound) % bound, x;
        do {
            x = rng();
        } while (x < threshold);
        swap(order[i], order[x % bound]);
    }
    for (int i = 0; i < mines; ++i)
        mine[order[i]] = 1;
    return Board(w, h, std::move(mine));
}
} // namespace minclicks
