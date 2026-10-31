#pragma once
#include <blend2d.h>
#include <array>
#include <cstdint>
#include <string_view>
#include <vector>
#include "timeline.hpp"

namespace otto {
struct Recipe {
    const char* name;
    const char* note;
    std::array<const char*,3> ingredients;
    uint32_t color;
    std::array<const char*,3> toppings;
    std::array<uint32_t,3> crust;
    uint32_t sauce;
    std::array<uint32_t,2> cheese;
    uint32_t edge;
    const char* style;
};
extern const std::array<Recipe,8> recipes;
BLPath svgPath(const char* source);
BLPath wedge(double radius = 201);
void check(BLResult result, const char* operation);
inline BLRgba32 rgba(uint32_t color) { return BLRgba32(0xff000000u|color); }
void stroke(BLContext& ctx, const BLPath& path, uint32_t color, double width = 1);
void line(BLContext& ctx, double x0, double y0, double x1, double y1, uint32_t color, double width = 1);

class Artwork {
public:
    // Texture coordinates cover the original local artwork at 2x resolution.
    static constexpr int width = 432, height = 328, angles = 8;
    static constexpr double left = -4, top = -82, scale = 2;
    Artwork();
    const BLImage& image(int index, double angle, double reveal);
private:
    struct Sprite {
        BLImage scratch;
        std::array<BLImage,angles> lit,ghost;
        // Quantized source-X displacement keeps reveal attached to the actual
        // raised surface, including while two cached view directions blend.
        std::array<std::vector<int8_t>,angles> revealOffset;
        double lastAngle = -1e10, lastReveal = -1e10;
    };
    std::array<Sprite,8> sprites_;
    void bake(int index);
};
} // namespace otto
