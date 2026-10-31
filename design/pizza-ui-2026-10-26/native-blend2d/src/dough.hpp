#pragma once
#include "timeline.hpp"
#include <cstdint>

namespace otto {
inline double doughNoise(double x,double y,int seed) {
    int ix=int(std::floor(x)),iy=int(std::floor(y));
    auto hash=[&](int px,int py) {
        uint32_t h=uint32_t(px)*0x9e3779b1u ^ uint32_t(py)*0x85ebca77u ^ uint32_t(seed+1)*0xc2b2ae3du;
        h^=h>>16; h*=0x7feb352du; h^=h>>15; h*=0x846ca68bu; h^=h>>16;
        return (h&65535)/32767.5-1;
    };
    double u=smooth(x-ix),v=smooth(y-iy);
    return std::lerp(std::lerp(hash(ix,iy),hash(ix+1,iy),u),std::lerp(hash(ix,iy+1),hash(ix+1,iy+1),u),v);
}
// Physical displacement above the original 18-unit dough slab. The same model
// drives the baked surface, cut walls, ingredient support and shadow casters.
inline double doughHeight(double x,double y,int recipe) {
    double r=std::hypot(x,y);
    double crumb=1.5+.42*doughNoise(x/12,y/12,recipe)
        +.2*doughNoise(x/5.2,y/5.2,recipe+19)+.07*doughNoise(x/2.2,y/2.2,recipe+43);
    double rim=std::exp(-.5*std::pow((r-191.5)/7.7,2));
    double puff=8.3+.7*doughNoise(x/9,y/9,recipe+11)+.25*doughNoise(x/4,y/4,recipe+31);
    return std::max(.6,crumb+rim*puff);
}
inline double doughRim(double x,double y) { return smooth((std::hypot(x,y)-176)/13); }
} // namespace otto
