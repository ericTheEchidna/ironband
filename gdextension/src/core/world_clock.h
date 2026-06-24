#pragma once

namespace ib {

class WorldClock {
public:
    static constexpr double HOURS_PER_SECOND = 4.0;

    void set_scale(double s) { scale_ = s < 0.0 ? 0.0 : s; }
    double scale() const { return scale_; }
    void pause() { scale_ = 0.0; }
    bool paused() const { return scale_ == 0.0; }

    int advance(double real_seconds);

    double game_hours() const { return hours_; }
    int    game_day() const { return (int)(hours_ / 24.0); }
    double game_hour_of_day() const { return hours_ - game_day() * 24.0; }

private:
    double scale_ = 1.0;
    double hours_ = 0.0;
};

} // namespace ib
