#pragma once

#include "model.hpp"

namespace minclicks::detail {
// Only mandatory zero vertices may be separators. Variables connected by a
// factor must stay together, even if their geometric graph has no direct edge.
inline vector<vector<int>> independentParts(const Model &m) {
    int n = int(m.cells.size()), total = int(m.edges.size());
    auto graph = m.edges;
    for (const auto &factor : m.factors)
        for (size_t j = 1; j < factor.vars.size(); ++j) {
            int a = factor.vars[0], b = factor.vars[j];
            graph[a].push_back(b);
            graph[b].push_back(a);
        }
    for (auto &adjacent : graph) unique_sort(adjacent);
    // Split biconnected edge blocks, then reunite blocks sharing an optional
    // chord vertex. Only mandatory zero articulation vertices may remain shared.
    // Removing ALL zero cut vertices at once is unsafe: two cut vertices can
    // belong to the same cycle, and their simultaneous removal can split that
    // cycle into pieces with two shared zeros. The seed correction then depends
    // on which chords were chosen rather than being a fixed constant.
    vector<int> discovered(total, -1), low(total);
    vector<pair<int, int>> edgeStack;
    DSU samePiece(n);
    int time = 0;
    auto dfs = [&](auto &&self, int v, int parent) -> void {
        discovered[v] = low[v] = time++;
        for (int u : graph[v])
            if (u != parent) {
                if (discovered[u] < 0) {
                    edgeStack.push_back({v, u});
                    self(self, u, v);
                    low[v] = min(low[v], low[u]);
                    if (low[u] >= discovered[v]) {
                        int anchor = -1;
                        pair<int, int> edge;
                        do {
                            edge = edgeStack.back();
                            edgeStack.pop_back();
                            for (int endpoint : {edge.first, edge.second})
                                if (endpoint < n) {
                                    if (anchor < 0) anchor = endpoint;
                                    else samePiece.join(anchor, endpoint);
                                }
                        } while (edge != pair{v, u});
                    }
                } else if (discovered[u] < discovered[v]) {
                    edgeStack.push_back({v, u});
                    low[v] = min(low[v], discovered[u]);
                }
            }
    };
    for (int v = 0; v < total; ++v)
        if (discovered[v] < 0) dfs(dfs, v, -1);
    vector<vector<int>> parts;
    vector<int> partFor(n, -1);
    for (int v = 0; v < n; ++v) {
        int root = samePiece.root(v);
        if (partFor[root] < 0) {
            partFor[root] = int(parts.size());
            parts.emplace_back();
        }
        parts[partFor[root]].push_back(v);
    }
    return parts;
}
}  // namespace minclicks::detail
