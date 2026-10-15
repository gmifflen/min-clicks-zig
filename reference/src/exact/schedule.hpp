#pragma once
#include "model.hpp"
namespace minclicks::detail {

constexpr int CONN_WEIGHT = 300;
constexpr int FACTOR_WEIGHT = 200;
constexpr int WEIGHT_SCALE = 100;
constexpr double WIDTH_EXP_SCALE = 8.0;
constexpr double RATIO_WEIGHT = static_cast<double>(CONN_WEIGHT) / FACTOR_WEIGHT;

struct FactorFold {
    uint64_t mines = 0, targets = 0;
    int weight = 1, targetCount = 0;
    vector<uint64_t> zeroMasks;
};
struct Step {
    int var;
    // Earlier selected chords that make taking this chord redundant.
    vector<int> chordDominators;
    vector<int> before, expanded, after, keep, neighbors;
    vector<int> oldFactors, newFactors, factorOld, factorTouch, factorClose,
        factorKeep, factorWeight;
    int freshZeros = 0;
    uint64_t touchMask = 0, closeMines = 0, closeTargets = 0;
    uint64_t mineMask = 0;
    vector<pair<uint64_t, int>> extraMineWeights, extraTargetWeights;
    vector<pair<uint64_t, int>> boundMasks;
    int boundConstant = 0;
    bool futureZero = false;
    vector<FactorFold> folds;
    // Each mask lists boundary positions touching one remaining candidate.
    // A component's future behavior is exactly the union of these contacts.
    vector<vector<uint32_t>> contacts;
    // One bit per distinct future candidate contact pattern, when <=64.
    vector<uint64_t> futureSignatures;
    vector<pair<uint64_t, int>> liveWeights;
};
struct Schedule {
    vector<Step> steps;
    int maxConn = 0, maxFactors = 0;
    double score = 0;
    double totalScore = 0;
    string name;
    bool packed = true;
};

struct OrderPlan {
    vector<int> order;
    string name;
    double score = 0, totalScore = 0;
};
OrderPlan planOrder(const Model &model, string name);
OrderPlan refineOrder(const Model &model, OrderPlan plan);
OrderPlan dynamicBandOrder(const Model &model, bool rows, bool reverse);
double estimateFrontierWork(const Model &model, const OrderPlan &plan);
Schedule schedule(const Model &model, const OrderPlan &plan);
void optimizeStrips(const Model &model, std::vector<int> &order, bool rows,
                    int bandSize = 1);
void optimizeWindows(const Model &model, std::vector<int> &order, int size,
                     int offset);
Schedule schedule(const Model &model, std::string name);
} // namespace minclicks::detail
