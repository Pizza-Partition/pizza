#pragma once
#include "timeline.hpp"

namespace otto {
inline constexpr double revealWidth = 24;
inline double revealCoverage(double localX,double progress) {
    return progress>=.999 ? 1 : smooth((clamp(progress)*240-localX)/revealWidth);
}
struct SideRevealBand { double start,end; };
// Extrusion changes only screen Y. Therefore a side's local X is constant on
// every vertical column, and this screen-X gradient matches the top's mask.
// Call only for nonconstant local X; equal-X edges have uniform coverage.
inline SideRevealBand sideRevealBand(double localA,double localB,double screenA,double screenB,double progress) {
    double scale=(screenB-screenA)/(localB-localA),front=clamp(progress)*240;
    return {screenA+(front-revealWidth-localA)*scale,screenA+(front-localA)*scale};
}
} // namespace otto
