#pragma once
#include "schedule.hpp"
namespace minclicks::detail {
struct PackedKey {
    uint64_t lo = 0, hi = 0, factors = 0;
    bool operator==(const PackedKey &) const = default;
    unsigned label(int i) const {
        return unsigned((i < 12 ? lo >> (5 * i) : hi >> (5 * (i - 12))) & 31);
    }
    void put(int i, unsigned label) {
        (i < 12 ? lo : hi) |= uint64_t(label) << (5 * (i < 12 ? i : i - 12));
    }
};
inline uint64_t mix(uint64_t x) {
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}
inline uint64_t hashKey(const PackedKey &k) {
    return mix(k.lo + 0x9e3779b97f4a7c15ULL) ^ rotl(mix(k.hi), 21) ^
           rotl(mix(k.factors), 42);
}
struct ConnectionResult {
    uint64_t lo = 0, hi = 0;
    int seeds = 0;
    bool live = false;
};
struct ConnectionCacheEntry {
    int generation = 0;
    array<ConnectionResult, 2> next;
    array<uint32_t, 2> target;
};
// Exact fallback when more than 64 distinct future-contact patterns are live:
// a union is represented by all boundary positions whose contacts it contains.
inline uint32_t contactClosure(uint32_t members, const Step &st) {
    uint32_t closure = members;
    for (int v = 0; v < int(st.contacts.size()); ++v) {
        if (members >> v & 1)
            continue;
        bool contained = true;
        for (uint32_t contact : st.contacts[v])
            if (!(contact & members)) {
                contained = false;
                break;
            }
        if (contained)
            closure |= uint32_t(1) << v;
    }
    return closure;
}
struct ContactPartition {
    array<uint64_t, 24> components{};
    uint8_t count = 0;
    uint64_t united = 0;
    ContactPartition(const PackedKey &key, const Step &st) {
        if (st.futureSignatures.size() == st.contacts.size()) {
            array<uint64_t, 32> signatures{};
            uint32_t present = 0;
            for (int v = 0; v < int(st.contacts.size()); ++v)
                if (unsigned label = key.label(v)) {
                    present |= uint32_t(1) << label;
                    signatures[label] |= st.futureSignatures[v];
                }
            for (uint32_t labels = present; labels; labels &= labels - 1) {
                uint64_t signature = signatures[countr_zero(labels)];
                united |= signature;
                components[count++] = signature;
            }
        } else {
            array<uint32_t, 32> members{};
            uint32_t all = 0;
            for (int v = 0; v < int(st.contacts.size()); ++v)
                if (unsigned label = key.label(v))
                    all |= members[label] |= uint32_t(1) << v;
            united = contactClosure(all, st);
            for (auto mask : members)
                if (mask)
                    components[count++] = contactClosure(mask, st);
        }
        sort(components.begin(), components.begin() + count);
    }
};
// Every fine component must map into a coarse one; every coarse component
// needs a distinct fine anchor so it cannot add a new seed liability.
inline bool contactCoarsens(const ContactPartition &coarse,
                            const ContactPartition &fine) {
    if (coarse.united != fine.united || coarse.count > fine.count)
        return false;
    if (coarse.count == 0)
        return fine.count == 0;
    if (coarse.count == 1)
        return true;
    array<uint32_t, 24> eligible{};
    uint32_t covered = 0;
    for (size_t c = 0; c < coarse.count; ++c)
        for (size_t f = 0; f < fine.count; ++f)
            if (!(fine.components[f] & ~coarse.components[c]))
                covered |= eligible[c] |= uint32_t(1) << f;
    if (covered != (uint32_t(1) << fine.count) - 1)
        return false;
    array<int, 24> match;
    match.fill(-1);
    auto augment = [&](auto &&self, int c, uint32_t &seen) -> bool {
        uint32_t available = eligible[c] & ~seen;
        while (available) {
            int f = countr_zero(available);
            available &= available - 1;
            seen |= uint32_t(1) << f;
            if (match[f] < 0 || self(self, match[f], seen)) {
                match[f] = c;
                return true;
            }
        }
        return false;
    };
    for (int c = 0; c < int(coarse.count); ++c) {
        uint32_t seen = 0;
        if (!augment(augment, c, seen))
            return false;
    }
    return true;
}
inline array<ConnectionResult, 2> connectionTransitions(const PackedKey &key,
                                                        const Step &st) {
    int old = (int)st.before.size(), count = (int)st.expanded.size();
    array<uint8_t, 32> original{};
    unsigned highest = 0;
    for (int j = 0; j < old; ++j) {
        original[j] = uint8_t(key.label(j));
        highest = max(highest, unsigned(original[j]));
    }
    for (int j = old; j < count - 1; ++j)
        original[j] = uint8_t(++highest);
    array<ConnectionResult, 2> result;
    for (int take = 0; take <= 1; ++take) {
        auto labels = original;
        if (take) {
            unsigned component = highest + 1;
            labels[count - 1] = uint8_t(component);
            uint32_t merged = 0;
            for (int j : st.neighbors)
                merged |= uint32_t(1) << labels[j];
            merged &= ~uint32_t(1);
            for (int j = 0; j < count - 1; ++j)
                if (merged >> labels[j] & 1)
                    labels[j] = uint8_t(component);
        }
        uint32_t present = 0, surviving = 0;
        for (int j = 0; j < count; ++j)
            present |= uint32_t(1) << labels[j];
        PackedKey out;
        array<uint8_t, 32> rename{};
        unsigned fresh = 0;
        for (int j = 0; j < (int)st.keep.size(); ++j) {
            unsigned label = labels[st.keep[j]];
            surviving |= uint32_t(1) << label;
            if (label && !rename[label])
                rename[label] = uint8_t(++fresh);
            out.put(j, rename[label]);
        }
        {
            // Labels represent future contacts, not necessarily selected
            // physical vertices. Adding or removing representatives must
            // preserve each component's contact union. Factors/witnesses retain
            // actual choices.
            array<uint32_t, 32> members{};
            for (int j = 0; j < (int)st.keep.size(); ++j)
                if (out.label(j))
                    members[out.label(j)] |= uint32_t(1) << j;
            for (int j = 0; j < (int)st.keep.size(); ++j)
                if (!out.label(j)) {
                    for (unsigned label = 1; label <= fresh; ++label) {
                        bool covered = true;
                        for (uint32_t contact : st.contacts[j])
                            if (!(members[label] & contact)) {
                                covered = false;
                                break;
                            }
                        if (covered) {
                            out.put(j, label);
                            members[label] |= uint32_t(1) << j;
                            break;
                        }
                    }
                }
            for (int j = (int)st.keep.size() - 1; j >= 0; --j)
                if (unsigned label = out.label(j)) {
                    uint32_t others = members[label] & ~(uint32_t(1) << j);
                    bool redundant = others != 0;
                    for (uint32_t contact : st.contacts[j])
                        if (!(others & contact)) {
                            redundant = false;
                            break;
                        }
                    if (redundant)
                        members[label] = others;
                }
            PackedKey reduced;
            rename.fill(0);
            fresh = 0;
            for (int j = 0; j < (int)st.keep.size(); ++j) {
                unsigned label = out.label(j);
                if (!(members[label] >> j & 1))
                    continue;
                if (!rename[label])
                    rename[label] = uint8_t(++fresh);
                reduced.put(j, rename[label]);
            }
            out = reduced;
        }
        result[take] = {out.lo, out.hi,
                        popcount(present & ~surviving & ~uint32_t(1)),
                        bool(surviving & ~uint32_t(1))};
    }
    return result;
}
// Connectivity is shared by many factor states. IDs are local to one layer;
// collisions are resolved by checking the full pair of packed label words.
struct ConnectionPool {
    struct Key { uint64_t lo, hi; };
    vector<Key> keys;
    vector<uint32_t> buckets = vector<uint32_t>(16);
    void clear() {
        keys.clear();
        fill(buckets.begin(), buckets.end(), 0);
    }
    static uint64_t hash(uint64_t lo, uint64_t hi) {
        return mix(lo ^ rotl(hi, 27));
    }
    void rehash(size_t size) {
        buckets.assign(size, 0);
        for (size_t i = 0; i < keys.size(); ++i) {
            size_t slot = hash(keys[i].lo, keys[i].hi) & (size - 1);
            while (buckets[slot]) slot = (slot + 1) & (size - 1);
            buckets[slot] = uint32_t(i + 1);
        }
    }
    uint32_t intern(uint64_t lo, uint64_t hi) {
        if ((keys.size() + 1) * 4 > buckets.size() * 3)
            rehash(buckets.size() * 2);
        size_t slot = hash(lo, hi) & (buckets.size() - 1);
        while (buckets[slot]) {
            uint32_t id = buckets[slot] - 1;
            if (keys[id].lo == lo && keys[id].hi == hi) return id;
            slot = (slot + 1) & (buckets.size() - 1);
        }
        uint32_t id = uint32_t(keys.size());
        keys.push_back({lo, hi});
        buckets[slot] = id + 1;
        return id;
    }
    PackedKey unpack(uint32_t id) const { return {keys[id].lo, keys[id].hi, 0}; }
};
// Sixteen-byte state records; witnesses and connectivity occupy shared slabs.
struct FlatTable {
    struct Node {
        uint64_t factors;
        uint32_t connection;
        int cost;
    };
    static_assert(sizeof(Node) == 16);
    ConnectionPool connections;
    vector<Node> nodes;
    vector<uint64_t> choices;
    vector<uint32_t> buckets;
    int words;
    explicit FlatTable(int nw) : words(nw) { buckets.resize(16); }
    void clear() {
        nodes.clear();
        choices.clear();
        connections.clear();
        fill(buckets.begin(), buckets.end(), 0);
    }
    void rehash(size_t size) {
        buckets.assign(size, 0);
        for (size_t i = 0; i < nodes.size(); ++i) {
            size_t slot = hash(nodes[i].connection, nodes[i].factors) & (size - 1);
            while (buckets[slot])
                slot = (slot + 1) & (size - 1);
            buckets[slot] = uint32_t(i + 1);
        }
    }
    void insert(const PackedKey &key, int cost, const uint64_t *source,
                int take = -1) {
        insertPrepared(connections.intern(key.lo, key.hi), key.factors, cost,
                       source, take);
    }
    static uint64_t hash(uint32_t connection, uint64_t factors) {
        return mix(factors ^ (uint64_t(connection) * 0x9e3779b97f4a7c15ULL));
    }
    PackedKey unpack(const Node &node) const {
        PackedKey key = connections.unpack(node.connection);
        key.factors = node.factors;
        return key;
    }
    void insertPrepared(uint32_t connection, uint64_t factors, int cost,
                        const uint64_t *source, int take = -1) {
        if ((nodes.size() + 1) * 4 > buckets.size() * 3)
            rehash(buckets.size() * 2);
        size_t slot = hash(connection, factors) & (buckets.size() - 1);
        while (buckets[slot]) {
            const auto &node = nodes[buckets[slot] - 1];
            if (node.connection == connection && node.factors == factors) break;
            slot = (slot + 1) & (buckets.size() - 1);
        }
        size_t index;
        if (buckets[slot]) {
            index = buckets[slot] - 1;
            if (nodes[index].cost <= cost)
                return;
            nodes[index].cost = cost;
        } else {
            index = nodes.size();
            nodes.push_back({factors, connection, cost});
            buckets[slot] = uint32_t(index + 1);
            choices.resize(choices.size() + words);
        }
        for (int j = 0; j < words; ++j)
            choices[index * words + j] = source[j];
        if (take >= 0)
            choices[index * words + take / 64] |= uint64_t(1) << (take % 64);
    }
    size_t pruneFactors(const Step &st) {
        constexpr size_t crossThreshold = 4;
        if (nodes.size() < 2 || (st.liveWeights.empty() &&
            (st.contacts.empty() || nodes.size() < crossThreshold)))
            return 0;
        // For equal connectivity, c(A)+weight(P(B) minus P(A)) <= c(B)
        // proves that A is no worse for every continuation. See the round-3
        // proof.
        vector<uint32_t> order(nodes.size());
        auto cheaper = [&](uint32_t a, uint32_t b) {
            if (nodes[a].cost != nodes[b].cost)
                return nodes[a].cost < nodes[b].cost;
            return nodes[a].factors > nodes[b].factors;
        };
        // IDs give exact linear-time grouping, regardless of frontier width.
        vector<size_t> offsets(connections.keys.size() + 1);
        for (const auto &node : nodes) ++offsets[node.connection + 1];
        for (size_t i = 1; i < offsets.size(); ++i) offsets[i] += offsets[i - 1];
        auto positions = offsets;
        for (uint32_t i = 0; i < nodes.size(); ++i)
            order[positions[nodes[i].connection]++] = i;
        for (size_t i = 0; i < connections.keys.size(); ++i)
            sort(order.begin() + offsets[i], order.begin() + offsets[i + 1], cheaper);
        vector<pair<uint64_t, int>> extra;
        for (auto [bit, w] : st.liveWeights)
            if (w > 1)
                extra.push_back({bit, w - 1});
        vector<uint8_t> removed(nodes.size());
        vector<uint32_t> survivors;
        uint32_t lastConnection = ~uint32_t(0);
        for (uint32_t i : order) {
            const auto &node = nodes[i];
            if (lastConnection != node.connection) {
                survivors.clear();
                lastConnection = node.connection;
            }
            for (uint32_t j : survivors) {
                uint64_t missing = node.factors & ~nodes[j].factors;
                if (!missing) {
                    removed[i] = 1;
                    break;
                }
                if (nodes[j].cost == node.cost)
                    continue;
                int penalty = popcount(missing);
                for (auto [bit, w] : extra)
                    if (missing & bit)
                        penalty += w;
                if (nodes[j].cost + penalty <= node.cost) {
                    removed[i] = 1;
                    break;
                }
            }
            if (!removed[i])
                survivors.push_back(i);
        }
        // Small layers rarely repay cross-partition matching overhead.
        if (nodes.size() >= crossThreshold) {
            // Compare groups in an acyclic order: fewer components first, then
            // larger contact sets. Equal-size coarsening is a bijection and cannot
            // decrease the sum of future-contact populations.
            struct Group {
                ContactPartition contacts;
                size_t begin = 0, end = 0;
                int population = 0;
                array<uint8_t, 24> sizes{};
            };
            vector<Group> groups;
            vector<uint32_t> survivorOrder;
            survivorOrder.reserve(order.size());
            for (size_t first = 0; first < order.size();) {
                size_t last = first + 1;
                uint32_t connection = nodes[order[first]].connection;
                while (last < order.size() && nodes[order[last]].connection == connection)
                    ++last;
                size_t begin = survivorOrder.size();
                for (size_t j = first; j < last; ++j)
                    if (!removed[order[j]])
                        survivorOrder.push_back(order[j]);
                if (survivorOrder.size() != begin) {
                    Group group{ContactPartition(connections.unpack(connection), st), begin,
                                survivorOrder.size()};
                    for (int c = 0; c < group.contacts.count; ++c) {
                        auto size = popcount(group.contacts.components[c]);
                        group.population += size;
                        group.sizes[c] = uint8_t(size);
                    }
                    sort(group.sizes.begin(),
                         group.sizes.begin() + group.contacts.count);
                    groups.push_back(std::move(group));
                }
                first = last;
            }
            sort(groups.begin(), groups.end(), [](const Group &a, const Group &b) {
                if (a.contacts.united != b.contacts.united)
                    return a.contacts.united < b.contacts.united;
                if (a.contacts.count != b.contacts.count)
                    return a.contacts.count < b.contacts.count;
                if (a.population != b.population)
                    return a.population > b.population;
                return lexicographical_compare(
                    a.contacts.components.begin(),
                    a.contacts.components.begin() + a.contacts.count,
                    b.contacts.components.begin(),
                    b.contacts.components.begin() + b.contacts.count);
            });
            for (size_t start = 0; start < groups.size();) {
                size_t end = start + 1;
                while (end < groups.size() && groups[end].contacts.united == groups[start].contacts.united)
                    ++end;
                for (size_t f = start + 1; f < end; ++f) {
                    auto &fine = groups[f];
                    for (size_t c = start; c < f; ++c) {
                        const auto &coarse = groups[c];
                        if (coarse.contacts.count > fine.contacts.count)
                            break;
                        if (nodes[survivorOrder[coarse.begin]].cost >
                                nodes[survivorOrder[fine.end - 1]].cost)
                            continue;
                        // A coarser partition needs distinct fine anchors.
                        // Their sorted sizes and largest component provide
                        // cheap necessary checks before the exact match test.
                        bool possible = true;
                        for (int k = 0; k < coarse.contacts.count; ++k)
                            if (fine.sizes[k] > coarse.sizes[k]) {
                                possible = false;
                                break;
                            }
                        if (!possible ||
                            (coarse.contacts.count &&
                             fine.sizes[fine.contacts.count - 1] >
                                 coarse.sizes[coarse.contacts.count - 1]) ||
                            !contactCoarsens(coarse.contacts, fine.contacts))
                            continue;
                        for (size_t ti = fine.begin; ti < fine.end; ++ti) {
                            uint32_t target = survivorOrder[ti];
                            if (removed[target])
                                continue;
                            for (size_t si = coarse.begin; si < coarse.end; ++si) {
                                uint32_t source = survivorOrder[si];
                                int allowance = nodes[target].cost - nodes[source].cost;
                                if (allowance < 0)
                                    break;
                                uint64_t missing = nodes[target].factors & ~nodes[source].factors;
                                int penalty = popcount(missing);
                                for (auto [bit, weight] : extra)
                                    if (missing & bit)
                                        penalty += weight;
                                if (penalty <= allowance) {
                                    removed[target] = 1;
                                    break;
                                }
                            }
                        }
                    }
                }
                start = end;
            }
        }
        size_t kept = 0, old = nodes.size();
        for (size_t i = 0; i < old; ++i)
            if (!removed[i]) {
                if (kept != i) {
                    nodes[kept] = nodes[i];
                    for (int j = 0; j < words; ++j)
                        choices[kept * words + j] = choices[i * words + j];
                }
                ++kept;
            }
        nodes.resize(kept);
        choices.resize(kept * words);
        // Index deliberately stale: next use is clear(), never a lookup.
        return old - kept;
    }
};
} // namespace minclicks::detail
