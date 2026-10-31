#include "relief.hpp"
#include "reveal.hpp"
#include "dough.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace otto;
void require(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
int main() {
    try {
        double lo=100,hi=0;
        for(int recipe=0;recipe<8;++recipe) for(int j=0;j<=32;++j) {
            double a=(-.3752510865888774)+j*(.7505021731777548/32),cs=std::cos(a),sn=std::sin(a);
            require(doughHeight(191.5*cs,191.5*sn,recipe)>doughHeight(160*cs,160*sn,recipe)+6,"crust is higher than the interior");
            require(doughHeight(191.5*cs,191.5*sn,recipe)>doughHeight(201*cs,201*sn,recipe)+2,"crust has a rounded outer shoulder");
            double previous=doughHeight(5,0,recipe);
            for(int r=6;r<=201;++r) {
                double h=doughHeight(r*cs,r*sn,recipe);
                require(std::isfinite(h) && h>.5 && h<12,"bounded physical dough height");
                require(std::abs(h-previous)<1.6,"smooth transition between interior and crust"); previous=h;
                if(r<165) { lo=std::min(lo,h); hi=std::max(hi,h); }
            }
        }
        require(hi-lo>.5 && hi-lo<2,"interior has restrained organic undulations");
        ReliefField plane(64,64,2,-16,-16);
        for(auto& pixel:plane.pixels) pixel.height=4;
        for(int i=0;i<16;++i) {
            double angle=i*pi/8; auto hit=plane.intersect(32,32,angle,4,true);
            require(std::abs(hit.height-4)<.012,"ray intersects a known constant-height plane");
            require(std::abs(hit.x-32-std::sin(angle)*(.55/.94)*2*4)<.015,"physical X parallax");
            require(std::abs(hit.y-32-std::cos(angle)*(.55/.94)*2*4)<.015,"physical Y parallax");
        }
        ReliefField block(64,64,2,-16,-16);
        for(int y=20;y<=43;++y) for(int x=20;x<=43;++x) block.pixels[size_t(y)*64+x].height=5;
        auto nearby=block.proximity(5);
        require(nearby[17*64+32]!=0 && nearby[0]==0,"view-ray proximity bounds");
        auto edge=block.intersect(32,17,0,5,nearby[17*64+32]!=0);
        require(edge.height>4.9 && edge.y>22,"raised silhouette occludes cheese outside its flat footprint");
        auto sideways=block.intersect(17,32,pi/2,5,true);
        require(sideways.height>4.9 && sideways.x>22,"silhouette parallax rotates with the pizza");
        auto empty=block.intersect(1,1,0,5,false); require(empty.height==0,"unoccupied surface stays flat");
        auto center=[](const std::vector<float>& image) {
            double sum=0,x=0,y=0;
            for(int row=0;row<64;++row) for(int col=0;col<64;++col) {
                double v=image[size_t(row)*64+col]; require(v>=0 && v<=1,"bounded shadow opacity");
                sum+=v; x+=col*v; y+=row*v;
            }
            require(sum>0,"nonempty cast shadow"); return std::pair{x/sum,y/sum};
        };
        auto front=center(block.shadow(0)),back=center(block.shadow(pi));
        require(front.first>32 && front.second>32,"key light casts shadows away from upper left");
        require(back.first<31.5 && back.second<31.5,"world light stays fixed as the slice rotates");
        for(int y=24;y<=39;++y) for(int x=24;x<=39;++x) block.pixels[size_t(y)*64+x].height=0;
        auto hole=block.intersect(32,30,0,5,true); require(hole.height==0,"ingredient holes remain open under parallax");
        ReliefField supported(64,64,2,-16,-16);
        for(auto& p:supported.pixels) p.baseHeight=p.height=2;
        for(int y=20;y<=43;++y) for(int x=20;x<=43;++x) supported.pixels[size_t(y)*64+x].height+=5;
        auto cap=supported.intersect(32,32,0,7,true);
        require(cap.height>6.9 && std::abs(supported.sample(cap.x,cap.y).baseHeight-2)<1e-6,"ingredients rest on raised dough");
        for(auto& p:supported.pixels) p.height=p.baseHeight;
        auto noShadow=supported.shadow(0);
        for(auto value:noShadow) require(value==0,"uniformly raised dough does not cast a false shadow onto itself");
        ReliefField silhouette(64,64,2,-16,-16);
        for(int y=0;y<64;++y) for(int x=0;x<64;++x) {
            auto& p=silhouette.pixels[size_t(y)*64+x]; p.coverage=x<32?1.f:0.f; p.height=p.baseHeight=x<32?4.f:0.f;
        }
        require(std::abs(silhouette.sampleHeight(31.5,30)-4)<1e-6,"cut boundary retains its true height");
        require(std::abs(silhouette.sample(31.5,30).coverage-.5)<1e-6,"raised silhouette has independent antialias coverage");
        // The reveal is evaluated in the intersected surface's coordinates,
        // not the screen-projected texture coordinates of a raised ingredient.
        for(int i=0;i<16;++i) for(int j=1;j<100;++j) {
            double angle=i*pi/8; auto hit=plane.intersect(32,32,angle,4,true);
            double displacement=(hit.x-32)/2;
            int offset=int(std::lround(displacement*16)); double localX=42;
            double exact=revealCoverage(localX+displacement,j/100.);
            double quantized=revealCoverage(localX+offset/16.,j/100.);
            require(std::abs(exact-quantized)<.002,"height-aware reveal quantization error");
        }
        std::cout<<"PASS: height intersections, silhouette occlusion, rotation, open holes, directional shadows and height-aware reveal\n";
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}
