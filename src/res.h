#pragma once
#define ASSERT(_e, ...) if (!(_e)) { fprintf(stderr, __VA_ARGS__); exit(1); }

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <numeric>
#include <vector>

#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "../lib/imgui.h"
#include "../lib/imgui_impl_metal.h"
#include "../lib/imgui_impl_sdl2.h"

typedef float f32;
typedef double f64;
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t i8;
typedef int16_t i16;
typedef int32_t i32;
typedef int64_t i64;
typedef size_t usize;

struct v2 {
    f32 x, y;
};

struct v2i {
    i32 x, y;
};

constexpr int SECTOR_NONE = 0;
constexpr int SECTOR_MAX = 128;

struct Wall {
    v2 a, b;
    int portal;
};

struct Sector {
    int id;
    usize firstwall, nwalls;
    f32 zfloor, zceil;
};

constexpr f32 PI = 3.14159265359f;
constexpr f32 TAU = 2.0f * PI;
constexpr f32 PI_2 = PI / 2.0f;
constexpr f32 PI_4 = PI / 4.0f;

constexpr bool downscaled = true;

constexpr f32 deg_to_rad(f32 d) { return d * (PI / 180.0f); }
constexpr f32 rad_to_deg(f32 d) { return d * (180.0f / PI); }

constexpr int SCREEN_WIDTH = downscaled ? 384 * 2 : 1280;
constexpr int SCREEN_HEIGHT = downscaled ? 216 * 2: 720;

constexpr int WINDOW_WIDTH = 1280;
constexpr int WINDOW_HEIGHT = 720;

static struct {
    int offsetX = downscaled ? ((SCREEN_WIDTH / 2) - 100) * 2 : (SCREEN_WIDTH / 2) + 300;
    int offsetY = downscaled ? ((SCREEN_HEIGHT / 2) + 10) * 2 : (SCREEN_HEIGHT / 2) + 360;
} top_down_view;

constexpr f32 EYE_Z = 1.65f;
constexpr f32 HFOV = deg_to_rad(120.0f);
constexpr f32 VFOV = 0.25f;

constexpr f32 ZNEAR = 0.0001f;
constexpr f32 ZFAR = 128.0f;

extern const char *LEVEL_FILE;
extern const char *GUN_TEXTURE_FILE;

struct Developer_Config{
    bool show_ui = false;
    bool show_level_in_top_view = false;
    bool toggle_window_size = false;
    bool mouse_captured = false;

    struct Camera_Config {
        bool show_ui_of_camera = true;
        f32 EYE_Z_runtime = EYE_Z;
        f32 HFOV_runtime = HFOV;
        f32 VFOV_runtime = VFOV;
        f32 ZNEAR_runtime = ZNEAR;
        f32 ZFAR_runtime = ZFAR;
        f32 mouse_sensitivity = 0.0025f;
        f32 mouse_sensitivity_vertical = 0.0025f;
        f32 vertical_angle = 0.0f;
    } camera;

    struct Rendering_Config {
        bool show_ui_of_rendering = true;
    } renderer;

    struct Level_Config {
        bool show_ui_of_level = true;

        struct Level_Data_Config {
            bool show_ui_of_data = true;
            char file_buf[256];
        } data;

        struct Level_Sector_Config {
            bool show_ui_of_sector = true;
            int idx = -1;
        } sector;

        struct Level_Wall_Config {
            bool show_ui_of_wall = true;
            bool clip_to_neighboring_wall;
            int idx = -1;
            bool is_creating_wall = false;
            v2 wall_start_point;
            int hovered_wall_idx = -1;
            char hovered_point = 0;
        } wall;

    } level;

};

struct Config{
    SDL_Window *window;
    SDL_Renderer *renderer;

    CAMetalLayer *layer;
    MTLRenderPassDescriptor *renderPassDescriptor;

    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLTexture> gameViewMetalTexture;
    id<MTLRenderCommandEncoder> renderEncoder;
    id<CAMetalDrawable> drawable;
    id<MTLCommandBuffer> commandBuffer;

    // Add gun texture
    id<MTLTexture> gunTexture;
    int gunWidth;
    int gunHeight;

    u32 *pixels;
    bool quit;

    struct { Sector arr[SECTOR_MAX]; usize n; } sectors;
    struct { Wall arr[256]; usize n; } walls;

    u16 y_lo[SCREEN_WIDTH], y_hi[SCREEN_WIDTH];

    struct {
        v2 pos = {3.0f, 3.0f};
        f32 angle = 0.0f;
        f32 anglecos, anglesin;
        int sector = 1;
        f32 current_height = EYE_Z;
        f32 target_height = EYE_Z;
        f32 bob_time = 0.0f;
        f32 bob_offset = 0.0f;
    } camera;

};

inline v2i to_v2i(const v2 &v) {
    return { static_cast<i32>(std::round(v.x)), static_cast<i32>(std::round(v.y)) };
}

inline v2 to_v2(const v2i &v) {
    return { static_cast<f32>(v.x), static_cast<f32>(v.y) };
}