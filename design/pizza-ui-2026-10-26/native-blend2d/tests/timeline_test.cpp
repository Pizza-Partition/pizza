#include "timeline.hpp"
#include "reveal.hpp"
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>
using namespace otto;
void require(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
int main() {
    try {
        require(frameAt(0).unfolded==0,"initial unfold"); require(frameAt(3).unfolded==1,"unfold endpoint");
        require(frameAt(duration).completed==8,"eight slices complete"); require(frameAt(duration).offset==0,"final recenter");
        require(frameAt(duration).wheelOpacity==0,"final reel hidden");
        for(int i=0;i<8;++i) {
            auto before=frameAt(assemble+i*cycle+.001),settled=frameAt(assemble+i*cycle+2.96);
            require(before.index==i,"slice index"); require(settled.reveal==1 && settled.lift==0,"settled slice");
            if(i<7) { double boundary=assemble+(i+1)*cycle;
                // The current source's spring ends with a nonzero derivative:
                // 45 / .65 degrees per second, about .00693 at this interval.
                require(std::abs(frameAt(boundary-.0001).rotation-frameAt(boundary+.0001).rotation)<.008,"rotation continuity"); }
            auto lifted=frameAt(assemble+i*cycle+1);
            require(std::abs(i*45+lifted.rotation)<1e-9 && lifted.lift>.9,"active slice alignment and lift");
        }
        for(int i=0;i<=34800;++i) {
            auto f=frameAt(i*.001);
            require(std::isfinite(f.reveal) && std::isfinite(f.wheelPosition),"finite timeline");
            require(f.index>=0 && f.index<8 && f.completed>=0 && f.completed<=8,"valid slice counts");
            require(f.unfolded>=0 && f.unfolded<=1 && f.offset>=0 && f.offset<=1,"bounded positions");
        }
        require(frameAt(std::numeric_limits<double>::quiet_NaN()).unfolded==0,"nonfinite input");
        Playback p; p.seek(10); p.openDialog(); p.tick(5); require(p.time==10 && !p.playing,"modal pauses");
        p.closeDialog(); require(p.playing,"modal resumes"); p.playing=false; p.openDialog(); p.closeDialog(); require(!p.playing,"modal preserves pause");
        p.replay(); p.nextSpeed(); p.tick(2); require(p.time==3,"speed 1.5");
        p.seek(duration-.1); p.tick(1); require(p.time==duration && !p.playing,"completion stops");
        p.toggle(); require(p.time==0 && p.playing,"replay after completion");
        p.seek(-10); require(p.time==0,"seek lower bound"); p.seek(100); require(p.time==duration,"seek upper bound");
        // Long cut sides must reveal progressively, in both screen directions.
        // Compare their screen-space gradient with the top's local-X coverage
        // over rotations, reveal positions and points along the entire edge.
        for(int direction : {-1,1}) for(int step=1;step<99;++step) {
            double progress=step/100.;
            auto band=sideRevealBand(5,187,30,30+direction*143,progress);
            for(int j=0;j<=100;++j) {
                double t=j/100.,localX=5+182*t,screenX=30+direction*143*t;
                double side=smooth(1-(screenX-band.start)/(band.end-band.start));
                require(std::abs(side-revealCoverage(localX,progress))<1e-12,"side/top reveal synchronization");
            }
        }
        require(revealCoverage(30,.4)>revealCoverage(150,.4),"reveal travels along the side instead of appearing all at once");
        std::cout<<"PASS: 34,801 timeline samples, alignment, rotation, playback state and 19,796 side/top reveal comparisons\n";
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return EXIT_FAILURE; }
}
