#include "relief.hpp"
#include <algorithm>
#include <cmath>

namespace otto {
namespace {
template<float SurfacePoint::*member>
float geometrySample(const ReliefField& f,double x,double y) {
    if(x<0 || y<0 || x>=f.width-1 || y>=f.height-1) return 0;
    int ix=int(x),iy=int(y); float fx=float(x-ix),fy=float(y-iy);
    auto i=size_t(iy)*f.width+ix;
    const SurfacePoint* p[]{&f.pixels[i],&f.pixels[i+1],&f.pixels[i+f.width],&f.pixels[i+f.width+1]};
    float weights[]{(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy},value=0,coverage=0;
    for(int j=0;j<4;++j) { float w=weights[j]*p[j]->coverage; coverage+=w; value+=w*(p[j]->*member); }
    return coverage>.001f ? value/coverage : 0;
}
} // namespace
ReliefField::ReliefField(int w,int h,double pixelsPerUnit,double originX,double originY)
    :width(w),height(h),scale(pixelsPerUnit),left(originX),top(originY),pixels(size_t(w)*h) {}
float ReliefField::sampleHeight(double x,double y) const {
    return geometrySample<&SurfacePoint::height>(*this,x,y);
}
float ReliefField::sampleBaseHeight(double x,double y) const {
    return geometrySample<&SurfacePoint::baseHeight>(*this,x,y);
}
SurfacePoint ReliefField::sample(double x,double y) const {
    x=std::clamp(x,0.,double(width-1)); y=std::clamp(y,0.,double(height-1));
    int ix=std::min(int(x),width-2),iy=std::min(int(y),height-2);
    float fx=float(x-ix),fy=float(y-iy); auto i=size_t(iy)*width+ix;
    const SurfacePoint* points[]{&pixels[i],&pixels[i+1],&pixels[i+width],&pixels[i+width+1]};
    float weights[]{(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy};
    SurfacePoint result{0,0,0,0,0,0,0,0};
    for(int j=0;j<4;++j) {
        const auto& p=*points[j]; float w=weights[j]*p.coverage;
        result.r+=p.r*w; result.g+=p.g*w; result.b+=p.b*w; result.height+=p.height*w;
        result.roughness+=p.roughness*w; result.specular+=p.specular*w; result.baseHeight+=p.baseHeight*w; result.coverage+=w;
    }
    if(result.coverage>.001f) {
        float factor=1/result.coverage;
        result.r*=factor; result.g*=factor; result.b*=factor; result.height*=factor;
        result.roughness*=factor; result.specular*=factor; result.baseHeight*=factor;
    }
    return result;
}
std::vector<uint8_t> ReliefField::proximity(double maxHeight) const {
    int radius=int(std::ceil(maxHeight*.55/.94*scale))+3;
    std::vector<uint8_t> horizontal(pixels.size()),result(pixels.size());
    // A sliding box dilation bounds the view ray's possible footprint without
    // tracing rays for the large, empty part of each slice texture.
    for(int y=0;y<height;++y) {
        int sum=0; auto occupied=[&](int x) { return x>=0 && x<width && pixels[size_t(y)*width+x].height>.01f ? 1:0; };
        for(int x=0;x<=radius;++x) sum+=occupied(x);
        for(int x=0;x<width;++x) { horizontal[size_t(y)*width+x]=uint8_t(sum>0); sum+=occupied(x+radius+1)-occupied(x-radius); }
    }
    for(int x=0;x<width;++x) {
        int sum=0; auto occupied=[&](int y) { return y>=0 && y<height ? horizontal[size_t(y)*width+x]:0; };
        for(int y=0;y<=radius;++y) sum+=occupied(y);
        for(int y=0;y<height;++y) { result[size_t(y)*width+x]=uint8_t(sum>0); sum+=occupied(y+radius+1)-occupied(y-radius); }
    }
    return result;
}
SurfaceHit ReliefField::intersect(double x,double y,double angle,double maxHeight,bool nearby) const {
    if(!nearby) return {x,y,0,sampleHeight(x,y)<.01};
    // Invert the renderer's .94*y - .55*z projection. Ray marching, rather than
    // a one-shot UV offset, lets raised silhouettes occlude the cheese behind.
    double dx=std::sin(angle)*(.55/.94)*scale,dy=std::cos(angle)*(.55/.94)*scale;
    constexpr double step=.35;
    double previous=maxHeight+step;
    for(double z=maxHeight;z>0;z-=step) {
        if(sampleHeight(x+dx*z,y+dy*z)>=z) {
            double lo=z,hi=previous;
            for(int j=0;j<5;++j) { double mid=(lo+hi)*.5;
                if(sampleHeight(x+dx*mid,y+dy*mid)>=mid) lo=mid; else hi=mid; }
            double h=(lo+hi)*.5; return {x+dx*h,y+dy*h,h};
        }
        previous=z;
    }
    return {x,y,0,sampleHeight(x,y)<.01};
}
std::vector<float> ReliefField::shadow(double angle) const {
    std::vector<float> blocked(pixels.size()),horizontal(pixels.size()),result(pixels.size());
    double cs=std::cos(angle),sn=std::sin(angle),lx=-160*cs-200*sn,ly=160*sn-200*cs;
    for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
        const auto& p=pixels[size_t(y)*width+x];
        double h=p.height;
        if(p.coverage<.01f || h<.08 || (h-p.baseHeight<.08 && p.baseHeight<3)) continue;
        double px=left+(x+.5)/scale,py=top+(y+.5)/scale;
        double sx=0,sy=0,receiver=0;
        // Start below the dough, then converge on its actual receiving surface.
        // This lets the high crust cast onto the lower interior without treating
        // every patch of the raised base as an ingredient hovering above zero.
        for(int j=0;j<4;++j) {
            double factor=(302-receiver)/(302-h);
            sx=(lx+(px-lx)*factor-left)*scale-.5;
            sy=(ly+(py-ly)*factor-top)*scale-.5;
            receiver=sampleBaseHeight(sx,sy);
        }
        if(h-receiver<.12) continue;
        int ix=int(std::floor(sx)),iy=int(std::floor(sy));
        // Cover the source texel's footprint before filtering; a sparse point
        // splat would leave holes in the cast shadow at subpixel offsets.
        for(int j=0;j<2;++j) for(int i=0;i<2;++i) if(ix+i>=0 && ix+i<width && iy+j>=0 && iy+j<height)
            blocked[size_t(iy+j)*width+ix+i]=1;
    }
    constexpr float weights[]{1/16.f,4/16.f,6/16.f,4/16.f,1/16.f};
    for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
        float sum=0; for(int k=-2;k<=2;++k) if(x+k>=0 && x+k<width) sum+=blocked[size_t(y)*width+x+k]*weights[k+2];
        horizontal[size_t(y)*width+x]=sum;
    }
    for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
        float sum=0; for(int k=-2;k<=2;++k) if(y+k>=0 && y+k<height) sum+=horizontal[size_t(y+k)*width+x]*weights[k+2];
        result[size_t(y)*width+x]=sum;
    }
    return result;
}
} // namespace otto
