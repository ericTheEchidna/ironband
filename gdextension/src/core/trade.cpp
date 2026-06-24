#include "core/trade.h"
#include <algorithm>
#include <cmath>

namespace ib {

static const double BASE_BUY        = 1.0;
static const double NOT_HERE_BUY    = 1.5;
static const double BASE_SELL       = 0.15;
static const double NOT_HERE_SELL   = 1.01;
static const double CULT_BUY_PEN    = 1.5;
static const double CULT_SELL_BONUS = 1.1;

// Python3 round(): round-half-to-even (banker's rounding).
static int py_round(double v) {
    double fl = std::floor(v);
    double diff = v - fl;
    if (diff < 0.5) return (int)fl;
    if (diff > 0.5) return (int)fl + 1;
    long long f = (long long)fl;
    return (f % 2 == 0) ? (int)f : (int)f + 1;
}

static std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c){ return (char)std::tolower(c); });
    return s;
}

Price calc_prices(const TradeGood& g, const Market& m) {
    bool is_prod = std::find(m.producing.begin(), m.producing.end(), g.building)
                   != m.producing.end();
    bool is_local = (g.culture == "Neutral")
                 || (lower(m.culture) == lower(g.culture))
                 || m.has_port;

    double buy_f = g.value * m.town_buy_mult * m.player_buy_mult
                 * (is_prod  ? BASE_BUY  : NOT_HERE_BUY)
                 * (is_local ? 1.0       : CULT_BUY_PEN);
    double sell_f = g.value * m.town_sell_mult * m.player_sell_mult
                 * (is_prod  ? BASE_SELL : NOT_HERE_SELL)
                 * (is_local ? 1.0       : CULT_SELL_BONUS);

    Price p;
    p.buy  = py_round(buy_f);
    p.sell = (int)sell_f;   // Python int(): truncation toward zero
    p.is_producing = is_prod;
    p.is_local_culture = is_local;
    return p;
}

} // namespace ib
