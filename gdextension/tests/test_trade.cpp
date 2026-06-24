#include "doctest.h"
#include "core/trade.h"

using namespace ib;

static Market plain(const char* culture, bool port,
                    std::vector<std::string> producing) {
    Market m;
    m.culture = culture; m.has_port = port; m.producing = std::move(producing);
    return m;
}

TEST_CASE("local producing town buys at base price") {
    TradeGood salt{"Salt", 340, "Neutral", "salt_mine"};
    Price p = calc_prices(salt, plain("neutral", false, {"salt_mine"}));
    CHECK(p.buy == 340);
    CHECK(p.is_producing == true);
}

TEST_CASE("non-producing town applies buy markup") {
    TradeGood salt{"Salt", 340, "Neutral", "salt_mine"};
    Price p = calc_prices(salt, plain("neutral", false, {}));
    CHECK(p.buy == 510); // 340 * 1.5
}

TEST_CASE("producing town applies sell penalty (floor)") {
    TradeGood furs{"Furs", 300, "Northern", "trapper"};
    Price p = calc_prices(furs, plain("northern", false, {"trapper"}));
    CHECK(p.sell == 45); // floor(300 * 0.15)
}

TEST_CASE("cross-culture non-producing sell bonus") {
    TradeGood silk{"Silk", 460, "Southern", "silk_farm"};
    Price p = calc_prices(silk, plain("northern", false, {}));
    CHECK(p.sell == 511); // int(460 * 1.01 * 1.1)
    CHECK(p.is_local_culture == false);
}
