#pragma once
#include "timeline.hpp"
#include <cstdint>
#include <vector>

namespace otto {
struct SurfacePoint {
    float r=0,g=0,b=0,height=0,roughness=.7f,specular=.04f;
    float baseHeight=0,coverage=1;
};
struct SurfaceHit { double x,y,height; bool valid=true; };

// All coordinates passed to the field are in texture pixels. Height is in the
// same physical units as the slice, so normals and parallax share one scale.
class ReliefField {
public:
    int width,height;
    double scale,left,top;
    std::vector<SurfacePoint> pixels;
    ReliefField(int w,int h,double pixelsPerUnit,double originX,double originY);
    float sampleHeight(double x,double y) const;
    float sampleBaseHeight(double x,double y) const;
    SurfacePoint sample(double x,double y) const;
    std::vector<uint8_t> proximity(double maxHeight) const;
    SurfaceHit intersect(double x,double y,double angle,double maxHeight,bool nearby) const;
    std::vector<float> shadow(double angle) const;
};
} // namespace otto
