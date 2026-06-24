#pragma once
#include <string>
#include <vector>

namespace ib {

struct TradeGood {
    std::string name;
    int value = 0;
    std::string culture;   // "Neutral" | "Northern" | "Southern"
    std::string building;  // producing building slug
};

struct Market {
    std::string culture;          // lowercase culture of the settlement
    bool has_port = false;
    std::vector<std::string> producing;
    double town_buy_mult   = 1.0;
    double town_sell_mult  = 1.0;
    double player_buy_mult  = 1.0;
    double player_sell_mult = 1.0;
};

struct Price {
    int buy = 0;
    int sell = 0;
    bool is_producing = false;
    bool is_local_culture = false;
};

Price calc_prices(const TradeGood& g, const Market& m);

} // namespace ib
