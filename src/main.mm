#include "res.h"
#include "window.h"

extern struct Developer_Config dev;
extern struct Config state;

inline f32 dot(const v2 &v0, const v2 &v1) {
    return (v0.x * v1.x) + (v0.y * v1.y);
}

inline f32 length(const v2 &vl) {
    return std::sqrt(dot(vl, vl));
}
inline v2 normalize(const v2 &vn) {
    const f32 l = length(vn);
    if (l == 0.0f) return {0.0f, 0.0f};
    return {vn.x / l, vn.y / l};
}

inline f32 ifnan(f32 x, f32 alt) {
    return std::isnan(x) ? alt : x;
}

inline f32 point_side(const v2 &p, const v2 &a, const v2 &b) {
    return -(((p.x - a.x) * (b.y - a.y)) - ((p.y - a.y) * (b.x - a.x)));
}

static v2 rotate(const v2 v, const f32 a) {
    return { v.x * std::cos(a) - v.y * std::sin(a), v.x * std::sin(a) + v.y * std::cos(a), };
}

static v2 intersect_segs(const v2 a0, const v2 a1, const v2 b0, const v2 b1) {
    const f32 d = (a0.x - a1.x) * (b0.y - b1.y) - (a0.y - a1.y) * (b0.x - b1.x);
    if (std::fabs(d) < 0.000001f) return {NAN, NAN};
    const f32 t = ((a0.x - b0.x) * (b0.y - b1.y) - (a0.y - b0.y) * (b0.x - b1.x)) / d;
    const f32 u = ((a0.x - b0.x) * (a0.y - a1.y) - (a0.y - b0.y) * (a0.x - a1.x)) / d;
    return (t >= 0 && t <= 1 && u >= 0 && u <= 1) ? v2{a0.x + t * (a1.x - a0.x), a0.y + t * (a1.y - a0.y)} : v2{NAN, NAN};
}

static u32 abgr_mul(const u32 col, const u32 a) {
    const u32 br = ((col & 0xFF00FF) * a) >> 8, g = ((col & 0x00FF00) * a) >> 8;
    return 0xFF000000 | (br & 0xFF00FF) | (g & 0x00FF00);
}

static void load_gun() {
    SDL_Surface* gunSurface = IMG_Load(GUN_TEXTURE_FILE);
    if (!gunSurface) printf("Failed to load doom_gun.png: %s\n", SDL_GetError());
    else {
        state.gunWidth = gunSurface->w;
        state.gunHeight = gunSurface->h;
        
        // Convert RGBA to BGRA
        u32* pixels = (u32*)gunSurface->pixels;
        for (int i = 0; i < gunSurface->w * gunSurface->h; i++) {
            u32 pixel = pixels[i];
            u8 r = (pixel >> 0) & 0xFF;
            u8 g = (pixel >> 8) & 0xFF;
            u8 b = (pixel >> 16) & 0xFF;
            u8 a = (pixel >> 24) & 0xFF;
            pixels[i] = (a << 24) | (r << 16) | (g << 8) | b;
        }
        
        MTLTextureDescriptor* gunTextureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:gunSurface->w height:gunSurface->h mipmapped:NO];
        gunTextureDesc.usage = MTLTextureUsageShaderRead;
        gunTextureDesc.storageMode = MTLStorageModeManaged;
        
        state.gunTexture = [state.device newTextureWithDescriptor:gunTextureDesc];
        if (!state.gunTexture) printf("Failed to create gun texture\n");
        else [state.gunTexture replaceRegion:MTLRegionMake2D(0, 0, gunSurface->w, gunSurface->h) mipmapLevel:0 withBytes:gunSurface->pixels bytesPerRow:gunSurface->pitch];
        
        SDL_FreeSurface(gunSurface);
    }
}

static int screen_angle_to_x(const f32 angle) {
    return SCREEN_WIDTH / 2 * (1.0f - std::tan((angle + dev.camera.HFOV_runtime / 2.0f) / dev.camera.HFOV_runtime * PI_2 - PI_4));
}

static f32 normalize_angle(const f32 a) {
    return a - TAU * std::floor((a + PI) / TAU);
}

static v2 world_pos_to_camera(const v2 p) {
    const v2 u = {p.x - state.camera.pos.x, p.y - state.camera.pos.y};
    return { u.x * state.camera.anglesin - u.y * state.camera.anglecos, u.x * state.camera.anglecos + u.y * state.camera.anglesin, };
}

static void verline(const int x, int y0, int y1, const u32 color) {
    if (x < 0 || x >= SCREEN_WIDTH) return;
    y0 = std::clamp(y0, 0, SCREEN_HEIGHT - 1);
    y1 = std::clamp(y1, 0, SCREEN_HEIGHT - 1);
    for (int y = y0; y <= y1; y++) state.pixels[y * SCREEN_WIDTH + x] = color;
}

static bool point_in_sector(const Sector *sector, v2 p) {
    if (!sector || sector->id == SECTOR_NONE) return false;
    for (usize i = 0; i < sector->nwalls; i++) {
        const Wall *wall = &state.walls.arr[sector->firstwall + i];
        if (point_side(p, wall->a, wall->b) > 0.001f) return false;
    }
    return true;
}

static void update_player_sector() {
    constexpr int PLAYER_SECTOR_QUEUE_MAX = SECTOR_MAX;
    int player_q[PLAYER_SECTOR_QUEUE_MAX];
    int head = 0;
    int tail = 0;
    int current_cam_sector_id = state.camera.sector;
    player_q[tail++] = state.camera.sector;
    bool visited[SECTOR_MAX] = {false};
    if (state.camera.sector > 0 && state.camera.sector < SECTOR_MAX) visited[state.camera.sector] = true;
    int found_sector = SECTOR_NONE;
    while (head != tail) {
        int current_sector_id = player_q[head++];
        head %= PLAYER_SECTOR_QUEUE_MAX;
        if (current_sector_id <= 0 || current_sector_id >= static_cast<int>(state.sectors.n) || state.sectors.arr[current_sector_id].id == 0) continue;
        const Sector *sector_ptr = &state.sectors.arr[current_sector_id];
        if (point_in_sector(sector_ptr, state.camera.pos)) { found_sector = current_sector_id; break; }
        for (usize i = 0; i < sector_ptr->nwalls; ++i) {
            const Wall *wall_ptr = &state.walls.arr[sector_ptr->firstwall + i];
            if (wall_ptr->portal != SECTOR_NONE && wall_ptr->portal > 0 && wall_ptr->portal < static_cast<int>(state.sectors.n) && state.sectors.arr[wall_ptr->portal].id != 0 && !visited[wall_ptr->portal]) {
                ASSERT((tail + 1) % PLAYER_SECTOR_QUEUE_MAX != head % PLAYER_SECTOR_QUEUE_MAX, "Player sector queue full!\n"); player_q[tail++] = wall_ptr->portal; tail %= PLAYER_SECTOR_QUEUE_MAX; visited[wall_ptr->portal] = true;
            }
        }
    }
    if (found_sector != SECTOR_NONE) {
        state.camera.sector = found_sector;
        // Update target height when changing sectors
        if (state.camera.sector > 0 && state.camera.sector < static_cast<int>(state.sectors.n)) {
            state.camera.target_height = state.sectors.arr[state.camera.sector].zfloor + EYE_Z;
        }
    }
    else {
        bool truly_lost = true;
        for (usize k = 1; k < state.sectors.n; ++k) {
            if (state.sectors.arr[k].id != 0 && point_in_sector(&state.sectors.arr[k], state.camera.pos)) { state.camera.sector = state.sectors.arr[k].id; truly_lost = false; break; }
        }
        if (truly_lost) state.camera.sector = (current_cam_sector_id > 0 && current_cam_sector_id < static_cast<int>(state.sectors.n) && state.sectors.arr[current_cam_sector_id].id != 0 ? current_cam_sector_id : 1);
        if (state.camera.sector <= 0 || state.camera.sector >= static_cast<int>(state.sectors.n) || state.sectors.arr[state.camera.sector].id == 0) state.camera.sector = 1;
    }
}

static void update_camera_height() {
    const f32 height_lerp_speed_up = 0.1f;
    const f32 height_lerp_speed_down = 0.3f;
    const f32 height_diff = state.camera.target_height - state.camera.current_height;
    const f32 height_lerp_speed = height_diff > 0 ? height_lerp_speed_up : height_lerp_speed_down;
    
    const f32 random_factor = 0.02f * (static_cast<f32>(rand()) / RAND_MAX - 0.5f);
    state.camera.current_height = std::lerp(state.camera.current_height, state.camera.target_height + random_factor, height_lerp_speed);
}

static void apply_view_bobbing(const v2& move_input) {
    const f32 bob_speed = 10.0f;
    const f32 bob_amount = 0.17f;
    
    if (length(move_input) > 0.001f) {
        state.camera.bob_time += 0.016f * bob_speed;
        state.camera.bob_offset = std::sin(state.camera.bob_time) * bob_amount;
    } else {
        state.camera.bob_time = 0.0f;
        state.camera.bob_offset = std::lerp(state.camera.bob_offset, 0.0f, 0.2f);
    }
}

static v2 handle_movement_input(const u8* keystate) {
    v2 move_input = {0.0f, 0.0f};
    const f32 move_speed = 3.0f * 0.016f;

    if (dev.show_level_in_top_view) {
        const int arrow_key_speed = 10;
        if (keystate[SDL_SCANCODE_LEFT]) top_down_view.offsetX -= arrow_key_speed;
        if (keystate[SDL_SCANCODE_RIGHT]) top_down_view.offsetX += arrow_key_speed;
        if (keystate[SDL_SCANCODE_UP]) top_down_view.offsetY -= arrow_key_speed;
        if (keystate[SDL_SCANCODE_DOWN]) top_down_view.offsetY += arrow_key_speed;
    }
    else if (!dev.show_level_in_top_view) {
        if (keystate[SDL_SCANCODE_W]) {
            move_input.x += state.camera.anglecos;
            move_input.y += state.camera.anglesin;
        }
        if (keystate[SDL_SCANCODE_S]) {
            move_input.x -= state.camera.anglecos;
            move_input.y -= state.camera.anglesin;
        }
        if (keystate[SDL_SCANCODE_A]) {
            move_input.x += state.camera.anglesin;
            move_input.y -= state.camera.anglecos;
        }
        if (keystate[SDL_SCANCODE_D]) {
            move_input.x -= state.camera.anglesin;
            move_input.y += state.camera.anglecos;
        }

        if (length(move_input) > 0.001f) {
            v2 move_dir = normalize(move_input);
            state.camera.pos.x += move_dir.x * move_speed;
            state.camera.pos.y += move_dir.y * move_speed;
        }
    }

    return move_input;
}

static void handle_sdl_events() {
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        ImGui_ImplSDL2_ProcessEvent(&ev);
        if (ev.type == SDL_QUIT) state.quit = true;
        if (ev.type == SDL_WINDOWEVENT && ev.window.event == SDL_WINDOWEVENT_CLOSE && ev.window.windowID == SDL_GetWindowID(state.window)) state.quit = true;
        
        if (ev.type == SDL_KEYDOWN) {
            if (ev.key.keysym.sym == SDLK_F2) { 
                dev.show_ui = !dev.show_ui;
                dev.mouse_captured = !dev.show_level_in_top_view && !dev.show_ui;
                SDL_SetRelativeMouseMode(dev.mouse_captured ? SDL_TRUE : SDL_FALSE);
            }
            if (ev.key.keysym.sym == SDLK_ESCAPE) {
                dev.mouse_captured = false;
                SDL_SetRelativeMouseMode(SDL_FALSE);
            }
        }
        
        if (ev.type == SDL_MOUSEBUTTONDOWN && ev.button.button == SDL_BUTTON_LEFT) {
            if (!dev.mouse_captured && !dev.show_level_in_top_view && !dev.show_ui) {
                dev.mouse_captured = true;
                SDL_SetRelativeMouseMode(SDL_TRUE);
            }
            else if ((dev.show_level_in_top_view || dev.show_ui) && (SDL_GetModState() & KMOD_SHIFT)) {
                int mouseX, mouseY;
                SDL_GetMouseState(&mouseX, &mouseY);
                constexpr float scale = downscaled ? 30.0f * 2 : 100.0f;
                const int offsetX = top_down_view.offsetX;
                const int offsetY = top_down_view.offsetY;

                v2 world_pos = {
                    (mouseX - offsetX) / -scale,
                    (mouseY - offsetY) / -scale
                };

                if (!dev.level.wall.is_creating_wall) {
                    dev.level.wall.is_creating_wall = true;
                    dev.level.wall.wall_start_point = world_pos;
                } else {
                    if (state.walls.n < sizeof(state.walls.arr) / sizeof(state.walls.arr[0])) {
                        Wall* new_wall = &state.walls.arr[state.walls.n++];
                        new_wall->a = dev.level.wall.wall_start_point;
                        new_wall->b = world_pos;
                        new_wall->portal = SECTOR_NONE;
                    }
                    dev.level.wall.is_creating_wall = false;
                }
            }
        }
        
        if (ev.type == SDL_MOUSEMOTION) {
            if (dev.mouse_captured && !dev.show_level_in_top_view && !dev.show_ui) {
                state.camera.angle += ev.motion.xrel * dev.camera.mouse_sensitivity;
                state.camera.anglecos = std::cos(state.camera.angle);
                state.camera.anglesin = std::sin(state.camera.angle);
                
                dev.camera.vertical_angle += ev.motion.yrel * dev.camera.mouse_sensitivity_vertical;
                dev.camera.vertical_angle = std::clamp(dev.camera.vertical_angle, -PI_2, PI_2);
            }
        }
    }
}

static void render_game_with_sdl() {
    for (int i = 0; i < SCREEN_WIDTH; i++) { state.y_hi[i] = SCREEN_HEIGHT - 1; state.y_lo[i] = 0; }
    bool sectdraw[SECTOR_MAX];
    std::fill(std::begin(sectdraw), std::end(sectdraw), false);
    const v2 zdl_world = rotate({0.0f, 1.0f}, +(dev.camera.HFOV_runtime / 2.0f));
    const v2 zdr_world = rotate({0.0f, 1.0f}, -(dev.camera.HFOV_runtime / 2.0f));
    const v2 zfl_cam = {zdl_world.x * dev.camera.ZFAR_runtime, zdl_world.y * dev.camera.ZFAR_runtime};
    const v2 zfr_cam = {zdr_world.x * dev.camera.ZFAR_runtime, zdr_world.y * dev.camera.ZFAR_runtime};
    constexpr usize QUEUE_MAX = 64;
    struct QueueEntry { int id; int x0; int x1; };
    struct { QueueEntry arr[QUEUE_MAX]; usize n; } queue = {{{state.camera.sector, 0, SCREEN_WIDTH - 1}}, 1};

    while (queue.n != 0) {
        QueueEntry entry = queue.arr[--queue.n];
        if (entry.id <= 0 || entry.id >= static_cast<int>(state.sectors.n) || state.sectors.arr[entry.id].id == 0 || sectdraw[entry.id]) continue;
        sectdraw[entry.id] = true;
        const Sector *sector = &state.sectors.arr[entry.id];
        bool is_selected_sector = (dev.level.sector.idx > 0 && dev.level.sector.idx < (int)state.sectors.n && state.sectors.arr[dev.level.sector.idx].id == entry.id);

        for (usize i = 0; i < sector->nwalls; i++) {
            const Wall *wall = &state.walls.arr[sector->firstwall + i];
            usize current_wall_global_idx = sector->firstwall + i;
            bool is_selected_wall = (dev.level.wall.idx >= 0 && dev.level.wall.idx < (int)state.walls.n && (int)current_wall_global_idx == dev.level.wall.idx);
            
            v2 cp0_orig = world_pos_to_camera(wall->a);
            v2 cp1_orig = world_pos_to_camera(wall->b);
            v2 cp0 = cp0_orig;
            v2 cp1 = cp1_orig;

            if (cp0.y < dev.camera.ZNEAR_runtime && cp1.y < dev.camera.ZNEAR_runtime) if (cp0.y <= 0 && cp1.y <=0) continue;

            if (cp0.y < dev.camera.ZNEAR_runtime && cp1.y >= dev.camera.ZNEAR_runtime) {
                float t = (dev.camera.ZNEAR_runtime - cp1.y) / (cp0.y - cp1.y);
                cp0 = {cp1.x + t * (cp0.x - cp1.x), dev.camera.ZNEAR_runtime};
            } else if (cp1.y < dev.camera.ZNEAR_runtime && cp0.y >= dev.camera.ZNEAR_runtime) {
                float t = (dev.camera.ZNEAR_runtime - cp0.y) / (cp1.y - cp0.y);
                cp1 = {cp0.x + t * (cp1.x - cp0.x), dev.camera.ZNEAR_runtime};
            } else if (cp0.y < dev.camera.ZNEAR_runtime && cp1.y < dev.camera.ZNEAR_runtime) {
                 cp0.y = dev.camera.ZNEAR_runtime;
                 cp1.y = dev.camera.ZNEAR_runtime;
            }
            
            f32 ap0 = normalize_angle(std::atan2(cp0.y, cp0.x) - PI_2);
            f32 ap1 = normalize_angle(std::atan2(cp1.y, cp1.x) - PI_2);
            float hfov_half = dev.camera.HFOV_runtime / 2.0f;

            if (ap0 > hfov_half) {
                v2 intersect_pt = intersect_segs(cp0_orig, cp1_orig, {0, 0}, {zfl_cam.x, zfl_cam.y});
                if (!std::isnan(intersect_pt.x)) {
                    cp0 = intersect_pt; if (cp0.y < dev.camera.ZNEAR_runtime) cp0.y = dev.camera.ZNEAR_runtime;
                }
                ap0 = hfov_half;
            }
            if (ap1 < -hfov_half) {
                v2 intersect_pt = intersect_segs(cp0_orig, cp1_orig, {0, 0}, {zfr_cam.x, zfr_cam.y});
                if (!std::isnan(intersect_pt.x)) {
                    cp1 = intersect_pt; if (cp1.y < dev.camera.ZNEAR_runtime) cp1.y = dev.camera.ZNEAR_runtime;
                }
                ap1 = -hfov_half;
            }
            
            if (cp0.y < dev.camera.ZNEAR_runtime || cp1.y < dev.camera.ZNEAR_runtime) continue;
            if (ap0 <= ap1) continue;

            const int tx0_wall = screen_angle_to_x(ap0);
            const int tx1_wall = screen_angle_to_x(ap1);
            if (tx0_wall >= tx1_wall) continue;
            const int render_x0 = std::clamp(tx0_wall, entry.x0, entry.x1);
            const int render_x1 = std::clamp(tx1_wall, entry.x0, entry.x1);
            if (render_x0 >= render_x1) continue;

            auto tint_color = [](u32 color, u8 r_add, u8 g_add, u8 b_add) {
                    u8 r = (color >> 0) & 0xFF; u8 g = (color >> 8) & 0xFF; u8 b = (color >> 16) & 0xFF; u8 a = (color >> 24) & 0xFF;
                    r = std::min(0xFF, r + r_add); g = std::min(0xFF, g + g_add); b = std::min(0xFF, b + b_add);
                    return (a << 24) | (b << 16) | (g << 8) | r;
            };

            u32 wall_ceil_color = 0xFFFF0000U; 
            u32 wall_floor_color = 0xFF00FFFFU;
            u32 portal_upper_color = 0xFF00FF00U;
            u32 portal_lower_color = 0xFF0000FFU;
            u32 solid_wall_color = 0xFFD0D0D0U;

            if (is_selected_wall) {
                solid_wall_color = tint_color(solid_wall_color, 0x10, 0x10, 0x30);
                portal_upper_color = tint_color(portal_upper_color, 0x10, 0x10, 0x30);
                portal_lower_color = tint_color(portal_lower_color, 0x10, 0x10, 0x30);
            } else if (is_selected_sector) {
                solid_wall_color = tint_color(solid_wall_color, 0x10, 0x10, 0x30);
                portal_upper_color = tint_color(portal_upper_color, 0x10, 0x10, 0x30);
                portal_lower_color = tint_color(portal_lower_color, 0x10, 0x10, 0x30);
                wall_ceil_color = 0xFFAAAAFFU; 
                wall_floor_color = 0xFFAAFFAAU;
            }

            const int wallshade_val = 16 * (std::sin(std::atan2(wall->b.x - wall->a.x, wall->b.y - wall->a.y)) + 1.0f);
            const f32 z_floor = sector->zfloor, z_ceil = sector->zceil;
            f32 nz_floor = 0, nz_ceil = 0;
            bool is_portal = wall->portal != SECTOR_NONE && wall->portal > 0 && wall->portal < static_cast<int>(state.sectors.n) && state.sectors.arr[wall->portal].id != 0;
            
            if (is_portal) {
                nz_floor = state.sectors.arr[wall->portal].zfloor;
                nz_ceil = state.sectors.arr[wall->portal].zceil;
            }

            const f32 sy0 = ifnan((dev.camera.VFOV_runtime * SCREEN_HEIGHT) / cp0.y, 1e10f);
            const f32 sy1 = ifnan((dev.camera.VFOV_runtime * SCREEN_HEIGHT) / cp1.y, 1e10f);
            const int yf0_curr  = SCREEN_HEIGHT / 2 + static_cast<int>((z_floor  - dev.camera.EYE_Z_runtime) * sy0) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
            const int yc0_curr  = SCREEN_HEIGHT / 2 + static_cast<int>((z_ceil   - dev.camera.EYE_Z_runtime) * sy0) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
            const int yf1_curr  = SCREEN_HEIGHT / 2 + static_cast<int>((z_floor  - dev.camera.EYE_Z_runtime) * sy1) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
            const int yc1_curr  = SCREEN_HEIGHT / 2 + static_cast<int>((z_ceil   - dev.camera.EYE_Z_runtime) * sy1) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
            
            int yf0_neigh = 0, yc0_neigh = 0, yf1_neigh = 0, yc1_neigh = 0;
            if (is_portal) {
                yf0_neigh = SCREEN_HEIGHT / 2 + static_cast<int>((nz_floor - dev.camera.EYE_Z_runtime) * sy0) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
                yc0_neigh = SCREEN_HEIGHT / 2 + static_cast<int>((nz_ceil  - dev.camera.EYE_Z_runtime) * sy0) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
                yf1_neigh = SCREEN_HEIGHT / 2 + static_cast<int>((nz_floor - dev.camera.EYE_Z_runtime) * sy1) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
                yc1_neigh = SCREEN_HEIGHT / 2 + static_cast<int>((nz_ceil  - dev.camera.EYE_Z_runtime) * sy1) + static_cast<int>(dev.camera.vertical_angle * SCREEN_HEIGHT);
            }

            for (int x = render_x0; x < render_x1; x++) {
                if (state.y_lo[x] >= state.y_hi[x]) continue;
                int current_shade = (x == render_x0 || x == render_x1 - 1) ? 192 : (255 - wallshade_val);
                const f32 t_lerp = (tx1_wall - tx0_wall == 0) ? 0.0f : (x - tx0_wall) / static_cast<f32>(tx1_wall - tx0_wall);
                const int yf_c = static_cast<int>(std::lerp(static_cast<f32>(yf0_curr), static_cast<f32>(yf1_curr), t_lerp));
                const int yc_c = static_cast<int>(std::lerp(static_cast<f32>(yc0_curr), static_cast<f32>(yc1_curr), t_lerp));
                int y_ceil_draw_top = state.y_lo[x];
                int y_floor_draw_bottom = state.y_hi[x];
                int yf_c_clamped = std::clamp(yf_c, y_ceil_draw_top, y_floor_draw_bottom);
                int yc_c_clamped = std::clamp(yc_c, y_ceil_draw_top, y_floor_draw_bottom);

                if (yc_c_clamped > y_ceil_draw_top) verline(x, y_ceil_draw_top, yc_c_clamped - 1, wall_ceil_color);
                if (yf_c_clamped < y_floor_draw_bottom) verline(x, yf_c_clamped + 1, y_floor_draw_bottom, wall_floor_color);

                if (is_portal) {
                    const int yf_n = static_cast<int>(std::lerp(static_cast<f32>(yf0_neigh), static_cast<f32>(yf1_neigh), t_lerp));
                    const int yc_n = static_cast<int>(std::lerp(static_cast<f32>(yc0_neigh), static_cast<f32>(yc1_neigh), t_lerp));
                    int yf_n_clamped = std::clamp(yf_n, y_ceil_draw_top, y_floor_draw_bottom);
                    int yc_n_clamped = std::clamp(yc_n, y_ceil_draw_top, y_floor_draw_bottom);

                    if (yc_c_clamped > yc_n_clamped) verline(x, yc_n_clamped, yc_c_clamped - 1, abgr_mul(portal_upper_color, current_shade));
                    if (yf_n_clamped > yf_c_clamped) verline(x, yf_c_clamped + 1, yf_n_clamped, abgr_mul(portal_lower_color, current_shade));
                    
                    state.y_lo[x] = std::max({state.y_lo[x], static_cast<u16>(yf_c_clamped), static_cast<u16>(yf_n_clamped)});
                    state.y_hi[x] = std::min({state.y_hi[x], static_cast<u16>(yc_c_clamped), static_cast<u16>(yc_n_clamped)});
                } else {
                    if (yc_c_clamped >= yf_c_clamped) verline(x, yf_c_clamped, yc_c_clamped, abgr_mul(solid_wall_color, current_shade));
                }
            }
            if (is_portal) {
                ASSERT(queue.n < QUEUE_MAX, "out of queue space");
                queue.arr[queue.n++] = {wall->portal, render_x0, render_x1};
            }
        }
    }
}

static void draw_pixel_solid(int x, int y, u32 color) {
    if (x >= 0 && x < SCREEN_WIDTH && y >= 0 && y < SCREEN_HEIGHT) {
        state.pixels[y * SCREEN_WIDTH + x] = color;
    }
}

static void draw_pixel_alpha(int x, int y, u32 color_with_alpha) {
    if (x >= 0 && x < SCREEN_WIDTH && y >= 0 && y < SCREEN_HEIGHT) {
        u32& dest_pixel_ref = state.pixels[y * SCREEN_WIDTH + x];
        u32 src_color = color_with_alpha;
        u8 alpha_src = (src_color >> 24) & 0xFF;
        if (alpha_src == 0) return;
        u8 r_src = (src_color >> 0) & 0xFF;
        u8 g_src = (src_color >> 8) & 0xFF;
        u8 b_src = (src_color >> 16) & 0xFF;
        u32 dst_color = dest_pixel_ref;
        u8 r_dst = (dst_color >> 0) & 0xFF;
        u8 g_dst = (dst_color >> 8) & 0xFF;
        u8 b_dst = (dst_color >> 16) & 0xFF;
        u8 r_new = (r_src * alpha_src + r_dst * (255 - alpha_src)) / 255;
        u8 g_new = (g_src * alpha_src + g_dst * (255 - alpha_src)) / 255;
        u8 b_new = (b_src * alpha_src + b_dst * (255 - alpha_src)) / 255;
        dest_pixel_ref = (0xFFU << 24) | (b_new << 16) | (g_new << 8) | r_new;
    }
}

static void draw_line_generic(int x0, int y0, int x1, int y1, u32 color, void (*pixel_drawer_func)(int, int, u32)) {
    int dx = std::abs(x1 - x0);
    int dy = -std::abs(y1 - y0);
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    while (true) {
        pixel_drawer_func(x0, y0, color);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) {
            if (x0 == x1) break;
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            if (y0 == y1) break;
            err += dx;
            y0 += sy;
        }
    }
}

static void draw_line_solid(int x0, int y0, int x1, int y1, u32 color) {
    draw_line_generic(x0, y0, x1, y1, color, draw_pixel_solid);
}

static void draw_line_alpha(int x0, int y0, int x1, int y1, u32 color_with_alpha) {
    draw_line_generic(x0, y0, x1, y1, color_with_alpha, draw_pixel_alpha);
}

static void draw_circle(int x0, int y0, int radius, u32 color) {
    int x = radius;
    int y = 0;
    int err = 0;
    while (x >= y) {
        draw_pixel_solid(x0 + x, y0 + y, color);
        draw_pixel_solid(x0 + y, y0 + x, color);
        draw_pixel_solid(x0 - y, y0 + x, color);
        draw_pixel_solid(x0 - x, y0 + y, color);
        draw_pixel_solid(x0 - x, y0 - y, color);
        draw_pixel_solid(x0 - y, y0 - x, color);
        draw_pixel_solid(x0 + y, y0 - x, color);
        draw_pixel_solid(x0 + x, y0 - y, color);
        y += 1;
        if (err <= 0) err += 2 * y + 1;
        if (err > 0) { x -= 1; err -= 2 * x + 1; }
    }
}

static void render_level_with_sdl() {
    memset(state.pixels, 0x1F1F1F, SCREEN_WIDTH * SCREEN_HEIGHT * sizeof(u32));
    constexpr float scale = downscaled ? 30.0f * 2 : 100.0f;
    const int offsetX = top_down_view.offsetX;
    const int offsetY = top_down_view.offsetY;

    // Get mouse position
    int mouseX, mouseY;
    SDL_GetMouseState(&mouseX, &mouseY);

    // Reset hover state
    dev.level.wall.hovered_wall_idx = -1;
    dev.level.wall.hovered_point = 0;

    // Check for wall point hover
    constexpr int hover_radius = 5;
    for (usize i = 0; i < state.walls.n; i++) {
        const Wall *wall = &state.walls.arr[i];
        int x0_map = offsetX - static_cast<int>(std::round(wall->a.x * scale));
        int y0_map = offsetY - static_cast<int>(std::round(wall->a.y * scale));
        int x1_map = offsetX - static_cast<int>(std::round(wall->b.x * scale));
        int y1_map = offsetY - static_cast<int>(std::round(wall->b.y * scale));

        // Check point A
        if (std::abs(mouseX - x0_map) < hover_radius && std::abs(mouseY - y0_map) < hover_radius) {
            dev.level.wall.hovered_wall_idx = i;
            dev.level.wall.hovered_point = 'A';
            draw_circle(x0_map, y0_map, hover_radius, 0xFFFFFF00);
        }
        // Check point B
        else if (std::abs(mouseX - x1_map) < hover_radius && std::abs(mouseY - y1_map) < hover_radius) {
            dev.level.wall.hovered_wall_idx = i;
            dev.level.wall.hovered_point = 'B';
            draw_circle(x1_map, y1_map, hover_radius, 0xFFFFFF00);
        }
    }

    // Draw wall creation preview
    if (dev.level.wall.is_creating_wall) {
        int startX = offsetX - static_cast<int>(std::round(dev.level.wall.wall_start_point.x * scale));
        int startY = offsetY - static_cast<int>(std::round(dev.level.wall.wall_start_point.y * scale));
        draw_line_solid(startX, startY, mouseX, mouseY, 0xFFFFFF00);
        draw_circle(startX, startY, hover_radius, 0xFFFFFF00);
    }

    if (dev.level.sector.idx > 0 && dev.level.sector.idx < (int)state.sectors.n && state.sectors.arr[dev.level.sector.idx].id != 0) {
        const Sector *selected_sector_ptr = &state.sectors.arr[dev.level.sector.idx];
        u32 sector_highlight_color = (0x60U << 24) | (0xFFU << 16) | (0x00U << 8) | 0x00U;
        int min_y_s = SCREEN_HEIGHT, max_y_s = 0;
        std::vector<std::pair<v2i, v2i>> sector_edges_screen;
        for (usize i = 0; i < selected_sector_ptr->nwalls; ++i) {
            const Wall *wall = &state.walls.arr[selected_sector_ptr->firstwall + i];
            v2i p1_screen = { offsetX - static_cast<int>(std::round(wall->a.x * scale)), offsetY - static_cast<int>(std::round(wall->a.y * scale))};
            v2i p2_screen = { offsetX - static_cast<int>(std::round(wall->b.x * scale)), offsetY - static_cast<int>(std::round(wall->b.y * scale))};
            sector_edges_screen.push_back({p1_screen, p2_screen});
            min_y_s = std::min({min_y_s, p1_screen.y, p2_screen.y});
            max_y_s = std::max({max_y_s, p1_screen.y, p2_screen.y});
        }
        if (!sector_edges_screen.empty()) {
            min_y_s = std::clamp(min_y_s, 0, SCREEN_HEIGHT - 1);
            max_y_s = std::clamp(max_y_s, 0, SCREEN_HEIGHT - 1);
            for (int y_scan = min_y_s; y_scan <= max_y_s; ++y_scan) {
                std::vector<int> intersections_x;
                for (const auto& edge : sector_edges_screen) {
                    v2i p1 = edge.first;
                    v2i p2 = edge.second;
                    if ((p1.y <= y_scan && p2.y > y_scan) || (p2.y <= y_scan && p1.y > y_scan)) {
                        float x_intersect = (p1.y == p2.y) ? static_cast<float>(p1.x) : static_cast<float>(p2.x - p1.x) * (y_scan - p1.y) / static_cast<float>(p2.y - p1.y) + p1.x;
                        intersections_x.push_back(static_cast<int>(std::round(x_intersect)));
                    }
                }
                std::sort(intersections_x.begin(), intersections_x.end());
                for (size_t j = 0; j < intersections_x.size(); j += 2) {
                    if (j + 1 < intersections_x.size()) {
                        int x_start = std::clamp(intersections_x[j], 0, SCREEN_WIDTH - 1);
                        int x_end = std::clamp(intersections_x[j+1], 0, SCREEN_WIDTH - 1);
                        for (int x_fill = x_start; x_fill < x_end; ++x_fill) draw_pixel_alpha(x_fill, y_scan, sector_highlight_color);
                    }
                }
            }
        }
    }

    for (usize i = 0; i < state.walls.n; i++) {
        const Wall *wall = &state.walls.arr[i];
        int x0_map = offsetX - static_cast<int>(std::round(wall->a.x * scale));
        int y0_map = offsetY - static_cast<int>(std::round(wall->a.y * scale));
        int x1_map = offsetX - static_cast<int>(std::round(wall->b.x * scale));
        int y1_map = offsetY - static_cast<int>(std::round(wall->b.y * scale));
        u32 line_color = (wall->portal != SECTOR_NONE) ? 0xFF00FF00U : 0xFFFFFFFFU;
        draw_line_solid(x0_map, y0_map, x1_map, y1_map, line_color);
    }

    if (dev.level.wall.idx >= 0 && dev.level.wall.idx < (int)state.walls.n) {
        const Wall *selected_wall_ptr = &state.walls.arr[dev.level.wall.idx];
        int x0_map = offsetX - static_cast<int>(std::round(selected_wall_ptr->a.x * scale));
        int y0_map = offsetY - static_cast<int>(std::round(selected_wall_ptr->a.y * scale));
        int x1_map = offsetX - static_cast<int>(std::round(selected_wall_ptr->b.x * scale));
        int y1_map = offsetY - static_cast<int>(std::round(selected_wall_ptr->b.y * scale));
        u32 wall_highlight_color = (0xA0U << 24) | (0xFFU << 16) | (0x00U << 8) | 0x00U;
        draw_line_alpha(x0_map, y0_map, x1_map, y1_map, wall_highlight_color);
        if (std::abs(x1_map - x0_map) >= std::abs(y1_map - y0_map)) {
            draw_line_alpha(x0_map, y0_map - 1, x1_map, y1_map - 1, wall_highlight_color);
            draw_line_alpha(x0_map, y0_map + 1, x1_map, y1_map + 1, wall_highlight_color);
        } else {
            draw_line_alpha(x0_map - 1, y0_map, x1_map - 1, y1_map, wall_highlight_color);
            draw_line_alpha(x0_map + 1, y0_map, x1_map + 1, y1_map, wall_highlight_color);
        }
    }

    int playerX_map = offsetX - static_cast<int>(std::round(state.camera.pos.x * scale));
    int playerY_map = offsetY - static_cast<int>(std::round(state.camera.pos.y * scale));
    draw_circle(playerX_map, playerY_map, 3, 0xFF0000FFU); 
    int dirX_map_end = playerX_map - static_cast<int>(std::cos(state.camera.angle) * 10.0f);
    int dirY_map_end = playerY_map - static_cast<int>(std::sin(state.camera.angle) * 10.0f);
    draw_line_solid(playerX_map, playerY_map, dirX_map_end, dirY_map_end, 0xFF0000FFU);
}

static void init_sdl_and_state() {
    ASSERT(!SDL_Init(SDL_INIT_VIDEO), "SDL failed to initialize: %s", SDL_GetError());
    ASSERT((IMG_Init(IMG_INIT_PNG) & IMG_INIT_PNG) == IMG_INIT_PNG, "SDL_image failed to initialize: %s", IMG_GetError());
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
    SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");

    state.window = SDL_CreateWindow("DEMO", SDL_WINDOWPOS_CENTERED_DISPLAY(0), SDL_WINDOWPOS_CENTERED_DISPLAY(0), WINDOW_WIDTH, WINDOW_HEIGHT, SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE);
    ASSERT(state.window, "failed to create SDL window: %s\n", SDL_GetError());

    state.renderer = SDL_CreateRenderer(state.window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    ASSERT(state.renderer, "failed to create SDL renderer: %s\n", SDL_GetError());

    state.pixels = new u32[SCREEN_WIDTH * SCREEN_HEIGHT];
    ASSERT(state.pixels, "failed to allocate pixel buffer\n");

    state.quit = false;
}

static void init_metal_pipeline() {
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();

    ASSERT(state.renderer, "SDL Renderer not initialized before Metal setup\n");

    state.layer = (__bridge CAMetalLayer *)SDL_RenderGetMetalLayer(state.renderer);
    ASSERT(state.layer, "Failed to get Metal layer from SDL renderer.\n");

    state.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    state.device = state.layer.device;
    ASSERT(state.device, "CAMetalLayer has no MTLDevice.\n");

    state.commandQueue = [state.device newCommandQueue];
    ASSERT(state.commandQueue, "Failed to create MTLCommandQueue.\n");

    state.renderPassDescriptor = [MTLRenderPassDescriptor new];
    ASSERT(state.renderPassDescriptor, "Failed to create MTLRenderPassDescriptor.\n");

    state.renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    state.renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    state.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    load_gun();

    MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm  width:SCREEN_WIDTH  height:SCREEN_HEIGHT  mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageShaderRead;
    textureDescriptor.storageMode = MTLStorageModeManaged;
    state.gameViewMetalTexture = [state.device newTextureWithDescriptor:textureDescriptor];
    ASSERT(state.gameViewMetalTexture, "Failed to create gameViewMetalTexture.\n");

    state.gameViewMetalTexture.label = @"GameViewSoftwareRenderTexture";
    bool imgui_sdl_init_success = ImGui_ImplSDL2_InitForMetal(state.window);
    ASSERT(imgui_sdl_init_success, "ImGui_ImplSDL2_InitForMetal failed.\n");

    bool imgui_metal_init_success = ImGui_ImplMetal_Init(state.device);
    ASSERT(imgui_metal_init_success, "ImGui_ImplMetal_Init failed.\n");
}

int main(int argc, char *argv[]) {
    int retval = 0;

    strncpy(dev.level.data.file_buf, LEVEL_FILE, sizeof(dev.level.data.file_buf) - 1);
    dev.level.data.file_buf[sizeof(dev.level.data.file_buf) - 1] = '\0';

    init_sdl_and_state();
    init_metal_pipeline();
    retval = load_sectors(LEVEL_FILE);

    ASSERT(retval == 0, "error while loading sectors: %d\n", retval);
    printf("loaded %zu sectors (max_id %zu) with %zu walls\n", std::count_if(state.sectors.arr + 1, state.sectors.arr + state.sectors.n, [](const Sector &s) { return s.id != 0; }), state.sectors.n > 0 ? state.sectors.n - 1 : 0, state.walls.n);

    while (!state.quit) {
        handle_sdl_events();
        if (state.quit) break;

        const u8 *keystate = SDL_GetKeyboardState(nullptr);
        v2 move_input = handle_movement_input(keystate);

        if (dev.toggle_window_size) SDL_MaximizeWindow(state.window);
        else SDL_RestoreWindow(state.window);

        update_player_sector();
        memset(state.pixels, 0x1F1F1F, SCREEN_WIDTH * SCREEN_HEIGHT * sizeof(u32));

        if (dev.show_level_in_top_view) render_level_with_sdl(); 
        else render_game_with_sdl();

        update_camera_height();
        apply_view_bobbing(move_input);
        dev.camera.EYE_Z_runtime = state.camera.current_height + state.camera.bob_offset;

        render_metal_frame_with_imgui();
    }

    delete[] state.pixels;

    ImGui_ImplMetal_Shutdown();
    ImGui_ImplSDL2_Shutdown();

    ImGui::DestroyContext();

    state.gameViewMetalTexture = nil;
    state.renderPassDescriptor = nil;
    state.commandQueue = nil;
    state.gunTexture = nil;

    if (state.renderer) SDL_DestroyRenderer(state.renderer);
    if (state.window) SDL_DestroyWindow(state.window);

    SDL_Quit();
    return 0;
}