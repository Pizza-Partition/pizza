#pragma once
#include <algorithm>
#include <array>
#include <cmath>

namespace otto {
inline constexpr double pi = 3.14159265358979323846;
inline constexpr double intro = 3, assemble = 4.2, cycle = 3.6;
inline constexpr double finish = assemble + 8 * cycle, duration = finish + 1.8;
inline double clamp(double x) { return std::clamp(x, 0.0, 1.0); }
inline double smooth(double x) { x = clamp(x); return x*x*(3-2*x); }
inline double anticipate(double x, double strength = .12) {
    x = clamp(x); return x*x*((1+strength)*x-strength);
}
inline double spring(double x, double overshoot = 1.06) {
    x = clamp(x); return x-(1-x)*std::sin(x*pi)*(overshoot-1);
}
inline double expo(double x) { return 1-std::pow(2., -10*clamp(x)); }
inline double cubic(double x) {
    x = clamp(x); return x<.5 ? 4*x*x*x : 1-std::pow(-2*x+2, 3)/2;
}
struct Frame {
    int index{}, completed{}, phase{};
    double local{}, reveal{}, lift{}, rotation{}, unfolded{}, offset{};
    double wheelOpacity{}, wheelPosition{};
    bool finishing{};
};
inline Frame frameAt(double time) {
    // Invalid input is contained at the boundary; seeking remains deterministic.
    time = std::isfinite(time) ? std::clamp(time, 0.0, duration) : 0;
    constexpr std::array offsets{0., .08, -.05, .12, -.03, .09, -.06, .04};
    Frame f;
    double elapsed = std::max(0., time-assemble);
    f.index = std::min(7, int(std::floor(elapsed/cycle)));
    f.local = elapsed-f.index*cycle;
    f.finishing = time>=finish;
    double adjust = offsets[f.index];
    f.reveal = time<assemble ? 0 : f.finishing ? 1 : anticipate((f.local-.35+adjust)/2.15, .08);
    double turn = f.index<7 ? spring((f.local-2.95)/.65, 1.03) : 0;
    double down = smooth((f.local-2.5)/.45);
    double lift = expo(f.local/.4)*(1-down);
    double wobble = std::sin(clamp((f.local-.4)/2.1)*pi*2.5)*.015*lift*(1-down);
    f.lift = time<assemble || f.finishing ? 0 : lift+wobble;
    f.unfolded = cubic((time-.25)/2.5);
    f.offset = expo((time-intro)/1.2)*(1-smooth((time-finish-.25)/1.4));
    double wheel = (time-intro-.3)/.9;
    double wheelIn = wheel<=.3 ? anticipate(wheel/.3) : wheel<=1 ? expo((wheel-.3)/.7) : 1;
    f.wheelOpacity = wheelIn*(1-smooth((time-finish)/.65));
    f.wheelPosition = f.index+spring((f.local-.15+adjust*.5)/1.8, 1.02);
    f.rotation = -45*(f.index+turn);
    f.completed = f.finishing ? 8 : time<assemble ? 0 : f.index+(f.reveal>=.99 ? 1 : 0);
    f.phase = time<intro ? 0 : f.finishing ? 2 : 1;
    return f;
}
struct Playback {
    double time = 0, speed = 1;
    bool playing = true, dialog = false, resumeAfterDialog = false;
    void seek(double value) { time = std::clamp(value, 0., duration); }
    void tick(double delta) {
        if (playing && !dialog) {
            seek(time+std::max(0., delta)*speed);
            if (time>=duration) playing = false;
        }
    }
    void toggle() {
        if (dialog) return;
        if (time>=duration) { time = 0; playing = true; }
        else playing = !playing;
    }
    void replay() { time = 0; playing = true; }
    void nextSpeed() { speed = speed==1 ? 1.5 : speed==1.5 ? 2 : 1; }
    void openDialog() { if (!dialog) { resumeAfterDialog = playing; playing = false; dialog = true; } }
    void closeDialog() { if (dialog) { dialog = false; playing = resumeAfterDialog && time<duration; } }
};
} // namespace otto
