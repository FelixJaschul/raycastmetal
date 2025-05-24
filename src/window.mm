#include "res.h"
#include "main.h"

extern struct Developer_Config dev;
extern struct Config state;

int load_sectors(const char *path) {
    state.sectors.n = 1;
    for (usize i = 0; i < SECTOR_MAX; ++i) state.sectors.arr[i].id = 0;

    state.walls.n = 0;
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int retval = 0;
    enum ScanState { SCAN_SECTOR, SCAN_WALL, SCAN_NONE };
    ScanState ss = SCAN_NONE;
    char line[1024], buf[64];
    while (fgets(line, sizeof(line), f)) {
        const char *p = line;
        while (isspace(static_cast<unsigned char>(*p))) p++;
        if (*p == '\0' || *p == '#') continue;
        if (*p == '[') { size_t len = strcspn(p + 1, "]");
            if (p[1 + len] == ']') { strncpy(buf, p + 1, len); buf[len] = '\0';
                if (!strcmp(buf, "SECTOR")) ss = SCAN_SECTOR;
                else if (!strcmp(buf, "WALL")) ss = SCAN_WALL;
                else { retval = -3; goto done; }
            } else { retval = -2; goto done; }
        } else {
            switch (ss) {
                case SCAN_WALL: {
                    if (state.walls.n >= sizeof(state.walls.arr) / sizeof(state.walls.arr[0])) { retval = -7; goto done; }
                    Wall *wall = &state.walls.arr[state.walls.n++];
                    v2i temp_a; v2i temp_b;
                    if (sscanf(p, "%d %d %d %d %d", &temp_a.x, &temp_a.y, &temp_b.x, &temp_b.y, &wall->portal) != 5) { retval = -4; goto done; }
                    wall->a = to_v2(temp_a); wall->b = to_v2(temp_b);
                } break;
                case SCAN_SECTOR: {
                    if (state.sectors.n >= sizeof(state.sectors.arr) / sizeof(state.sectors.arr[0])) { retval = -8; goto done; }
                    Sector *sector = &state.sectors.arr[state.sectors.n++];
                    if (sscanf(p, "%d %zu %zu %f %f", &sector->id, &sector->firstwall, &sector->nwalls, &sector->zfloor, &sector->zceil) != 5) { retval = -5; goto done; }
                } break;
                default: retval = -6; goto done;
            }
        }
    }
    if (ferror(f)) retval = -128;
    done:
    fclose(f);
    return retval;
}

int save_sectors(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return -1;

    fprintf(f, "[SECTOR]\n");
    for (usize i = 1; i < state.sectors.n; ++i) {
        if (state.sectors.arr[i].id == 0) continue;
        const Sector *sector = &state.sectors.arr[i];
        fprintf(f, "%d %zu %zu %.3f %.3f\n",
            sector->id,
            sector->firstwall,
            sector->nwalls,
            sector->zfloor,
            sector->zceil);
    }

    fprintf(f, "\n[WALL]\n");
    for (usize i = 0; i < state.walls.n; ++i) {
        const Wall *wall = &state.walls.arr[i];
        fprintf(f, "%d %d %d %d %d\n",
            static_cast<int>(std::round(wall->a.x)),
            static_cast<int>(std::round(wall->a.y)),
            static_cast<int>(std::round(wall->b.x)),
            static_cast<int>(std::round(wall->b.y)),
            wall->portal);
    }

    fclose(f);
    return 0;
}

void render_metal_frame_with_imgui() {
    if (state.gameViewMetalTexture && state.pixels) {
        MTLRegion region = { {0, 0, 0}, {(NSUInteger)SCREEN_WIDTH, (NSUInteger)SCREEN_HEIGHT, 1} };
        NSUInteger bytesPerRow = SCREEN_WIDTH * sizeof(u32);
        [state.gameViewMetalTexture replaceRegion:region mipmapLevel:0 withBytes:state.pixels bytesPerRow:bytesPerRow];
    }

    state.drawable = [state.layer nextDrawable];
    if (!state.drawable) return;

    state.renderPassDescriptor.colorAttachments[0].texture = state.drawable.texture;

    state.commandBuffer = [state.commandQueue commandBuffer];
    ASSERT(state.commandBuffer, "Failed to create command buffer");
    state.commandBuffer.label = @"MainFrameCommandBuffer";

    state.renderEncoder = [state.commandBuffer renderCommandEncoderWithDescriptor:state.renderPassDescriptor];
    ASSERT(state.renderEncoder, "Failed to create render command encoder");
    state.renderEncoder.label = @"MainFrameRenderEncoder";

    [state.renderEncoder pushDebugGroup:@"FrameRender"];

    ImGui_ImplMetal_NewFrame(state.renderPassDescriptor);
    ImGui_ImplSDL2_NewFrame();
    ImGui::NewFrame();

    const ImGuiViewport *viewport = ImGui::GetMainViewport();
    ImVec2 window_pos = viewport ? viewport->WorkPos : ImVec2(0, 0);
    ImVec2 window_size = viewport ? viewport->WorkSize : ImGui::GetIO().DisplaySize;

    ImGui::SetNextWindowPos(window_pos);
    ImGui::SetNextWindowSize(window_size);

    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));

    ImGuiWindowFlags game_view_flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNavFocus | ImGuiWindowFlags_NoBackground;

    ImGui::Begin("GameViewHost", nullptr, game_view_flags);
    ImGui::PopStyleVar(3);

    if (state.gameViewMetalTexture) {
        ImVec2 uv0 = {1.0f, 1.0f};
        ImVec2 uv1 = {0.0f, 0.0f};
        ImGui::Image((ImTextureID)state.gameViewMetalTexture, window_size, uv0, uv1);
    }
    ImGui::End();

    // Render gun if not in UI or level editor mode
    if (!dev.show_ui && !dev.show_level_in_top_view && state.gunTexture) {
        static bool first_render = true;
        if (first_render) first_render = false;

        ImGui::SetNextWindowPos(ImVec2(0, 0));
        ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
        ImGui::Begin("GunOverlay", nullptr,
            ImGuiWindowFlags_NoTitleBar |
            ImGuiWindowFlags_NoResize |
            ImGuiWindowFlags_NoMove |
            ImGuiWindowFlags_NoScrollbar |
            ImGuiWindowFlags_NoScrollWithMouse |
            ImGuiWindowFlags_NoCollapse |
            ImGuiWindowFlags_NoBackground |
            ImGuiWindowFlags_NoSavedSettings |
            ImGuiWindowFlags_NoInputs);

        // Calculate position to center the gun at the bottom of the screen
        float gunScale = 0.5f;
        float scaledWidth = state.gunWidth * gunScale;
        float scaledHeight = state.gunHeight * gunScale;

        float baseXPos = (ImGui::GetIO().DisplaySize.x - scaledWidth) * 0.5f;
        float baseYPos = ImGui::GetIO().DisplaySize.y - scaledHeight;

        float verticalBob = std::sin(state.camera.bob_time) * 10.0f;
        float horizontalBob = std::cos(state.camera.bob_time) * 5.0f;

        float xPos = baseXPos + horizontalBob;
        float yPos = baseYPos + verticalBob;

        ImGui::SetCursorPos(ImVec2(xPos, yPos));
        ImGui::Image((ImTextureID)state.gunTexture, ImVec2(scaledWidth, scaledHeight));

        ImGui::End();
        ImGui::PopStyleVar(2);
    } else if (state.gunTexture) {
        static bool first_skip = true;
        if (first_skip) first_skip = false;
    }

    if (dev.show_ui) {
        // Engine
        ImGui::Begin("Engine Config", &dev.show_ui);
        if (ImGui::Button("Toggle Window Size")) dev.toggle_window_size = !dev.toggle_window_size;
        ImGui::Separator();
        // Engine -> Camera Config
        if (ImGui::Button("Camera Config")) dev.camera.show_ui_of_camera = !dev.camera.show_ui_of_camera;
        if (dev.camera.show_ui_of_camera) {
            ImGui::Begin("Camera Config", &dev.camera.show_ui_of_camera);
            ImGui::Text("Camera Pos: (%.2f, %.2f)", state.camera.pos.x, state.camera.pos.y);
            if (ImGui::SliderAngle("Angle##Cam", &state.camera.angle)) {
                state.camera.anglecos = std::cos(state.camera.angle);
                state.camera.anglesin = std::sin(state.camera.angle);
            }
            ImGui::Text("Calculated Sin: %.2f, Cos: %.2f", state.camera.anglesin, state.camera.anglecos);
            ImGui::Text("Current Sector ID: %d", state.camera.sector);
            ImGui::SliderFloat("Mouse Sensitivity (Horizontal)", &dev.camera.mouse_sensitivity, 0.0001f, 0.01f, "%.4f");
            ImGui::SliderFloat("Mouse Sensitivity (Vertical)", &dev.camera.mouse_sensitivity_vertical, 0.0001f, 0.01f, "%.4f");
            ImGui::Text("Mouse Captured: %s", dev.mouse_captured ? "Yes" : "No");
            ImGui::Text("Controls: WASD to move, Mouse to look, ESC to toggle mouse capture");
            ImGui::End(); // End Camera Config
        }
        // Engine -> Renderer Config
        ImGui::SameLine();
        if (ImGui::Button("Rendering Config")) dev.renderer.show_ui_of_rendering = ! dev.renderer.show_ui_of_rendering;
        if (dev.renderer.show_ui_of_rendering) {
            ImGui::Begin("Rendering Config", &dev.renderer.show_ui_of_rendering);
            ImGui::End(); // End Renderer Config
        }
        // Engine -> Level Config
        ImGui::SameLine();
        if (ImGui::Button("Level Config")) dev.level.show_ui_of_level = ! dev.level.show_ui_of_level;
        if (dev.level.show_ui_of_level) {
            ImGui::Begin("Level Config" , &dev.level.show_ui_of_level);
            ImGui::Text("Level File: %s, %lu", dev.level.data.file_buf, sizeof(dev.level.data.file_buf));
            if (ImGui::Button("Reset Current Highlights (wall + sec)")) { dev.level.wall.idx = -1; dev.level.sector.idx = -1; }
            if (ImGui::Button("Load Top down view")) dev.show_level_in_top_view = !dev.show_level_in_top_view;
            ImGui::SameLine();
            if (ImGui::Button("Reload Level")) {
                int load_ret = load_sectors(dev.level.data.file_buf);
                if (load_ret != 0) SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Load Error",("Failed to load level: " + std::to_string(load_ret)).c_str(), state.window);
                else {
                    printf("Reloaded %s: %zu sectors, %zu walls\n", dev.level.data.file_buf, state.sectors.n, state.walls.n);
                    state.camera.pos = {3.0f, 3.0f};
                    state.camera.angle = 0.0f;
                    state.camera.sector = 1;
                }
            }
            ImGui::SameLine();
            if (ImGui::Button("Save Level")) {
                int save_ret = save_sectors(dev.level.data.file_buf);
                if (save_ret != 0) SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Save Error",("Failed to save level: " + std::to_string(save_ret)).c_str(), state.window);
                else {
                    printf("Saved %s: %zu sectors, %zu walls\n", dev.level.data.file_buf, state.sectors.n, state.walls.n);
                }
            }
            ImGui::Text("Loaded Sectors: %zu (max_id %zu)", std::count_if(state.sectors.arr + 1, state.sectors.arr + state.sectors.n, [](const Sector &s){ return s.id != 0; }), state.sectors.n > 0 ? state.sectors.n - 1 : 0);
            ImGui::Text("Loaded Walls: %zu", state.walls.n);
            // Engine -> Level Config -> Sector Config
            if (ImGui::Button("Sector Config")) dev.level.sector.show_ui_of_sector = ! dev.level.sector.show_ui_of_sector;
            if (dev.level.sector.show_ui_of_sector) {
                ImGui::Begin("Sector Config", &dev.level.sector.show_ui_of_sector);
                ImGui::Text("\nSectors:");
                if (ImGui::BeginListBox("##SectorsList", ImVec2(-FLT_MIN, 5 * ImGui::GetTextLineHeightWithSpacing()))) {
                    for (usize i = 1; i < state.sectors.n; ++i) {
                        if (state.sectors.arr[i].id == 0) continue;
                        const bool is_selected = (dev.level.sector.idx == (int)i);
                        char label[128];
                        snprintf(label, sizeof(label), "Sector %d (Walls: %zu, Floor: %.1f, Ceil: %.1f)", state.sectors.arr[i].id, state.sectors.arr[i].nwalls, state.sectors.arr[i].zfloor, state.sectors.arr[i].zceil);
                        if (ImGui::Selectable(label, is_selected)) dev.level.sector.idx = i;
                        if (is_selected) ImGui::SetItemDefaultFocus();
                    }
                    ImGui::EndListBox();
                }

                if (dev.level.sector.idx != -1 && dev.level.sector.idx > 0 && dev.level.sector.idx < (int)state.sectors.n) {
                    Sector& selected_s = state.sectors.arr[dev.level.sector.idx];
                    ImGui::Text("Editing Sector ID: %d", selected_s.id);
                    ImGui::PushID(selected_s.id);
                    ImGui::DragFloat("Floor Z", &selected_s.zfloor, 0.05f);
                    ImGui::DragFloat("Ceil Z", &selected_s.zceil, 0.05f);
                    ImGui::Text("First Wall Index: %zu, Num Walls: %zu", selected_s.firstwall, selected_s.nwalls);
                    ImGui::PopID();
                } // End Sector Config
                ImGui::End();
            }
            // Engine -> Level Config -> Wall Config
            ImGui::SameLine();
            if (ImGui::Button("Wall Config")) dev.level.wall.show_ui_of_wall = !dev.level.wall.show_ui_of_wall;
            if (dev.level.wall.show_ui_of_wall) {
                static v2 s_original_drag_start_pos_float;
                static std::vector<std::pair<int, char>> s_linked_points_for_this_drag;
                static int s_active_drag_wall_idx = -1;
                static char s_active_drag_point_char = 0;

                ImGui::Begin("Wall Config", &dev.level.wall.show_ui_of_wall);
                if (ImGui::BeginListBox("##WallsList", ImVec2(-FLT_MIN, 5 * ImGui::GetTextLineHeightWithSpacing()))) {
                    for (usize i = 0; i < state.walls.n; ++i) {
                        const bool is_selected = (dev.level.wall.idx == (int)i);
                        char label[128];
                        Wall& w = state.walls.arr[i];
                        snprintf(label, sizeof(label), "Wall %zu: [(%.2f,%.2f)-(%.2f,%.2f)] Portal: %d", i, w.a.x, w.a.y, w.b.x, w.b.y, w.portal);

                        if (ImGui::Selectable(label, is_selected)) {
                            if (dev.level.wall.idx != (int)i) {
                                s_active_drag_wall_idx = -1;
                                s_active_drag_point_char = 0;
                                s_linked_points_for_this_drag.clear();
                            }
                            dev.level.wall.idx = i;
                        }
                        if (is_selected) ImGui::SetItemDefaultFocus();
                    }
                    ImGui::EndListBox();
                }

                ImGui::Checkbox("Clip/Connect Neighboring Walls", &dev.level.wall.clip_to_neighboring_wall);
                ImGui::Separator();

                if (dev.level.wall.idx != -1 && dev.level.wall.idx >=0 && dev.level.wall.idx < (int)state.walls.n) {
                    Wall& selected_w = state.walls.arr[dev.level.wall.idx];
                    ImGui::Text("Editing Wall Index: %d", dev.level.wall.idx);
                    ImGui::PushID(dev.level.wall.idx);

                    v2 pre_drag_a = selected_w.a;
                    v2 pre_drag_b = selected_w.b;

                    bool any_point_widget_active_this_frame = false;
                    float drag_speed = 0.01f;

                    ImGui::PushID("PointAControls");
                    ImGui::Text("Point A"); ImGui::SameLine();
                    if (ImGui::DragFloat2("##CoordsA", &selected_w.a.x, drag_speed)) {
                        if (s_active_drag_wall_idx == dev.level.wall.idx && s_active_drag_point_char == 'A') {
                            if (dev.level.wall.clip_to_neighboring_wall) {
                                for (const auto& linked_info : s_linked_points_for_this_drag) {
                                    Wall& linked_wall = state.walls.arr[linked_info.first];
                                    if (linked_info.second == 'A') linked_wall.a = selected_w.a;
                                    else linked_wall.b = selected_w.a;
                                }
                            }
                        }
                    }
                    if (ImGui::IsItemActivated()) {
                        s_active_drag_wall_idx = dev.level.wall.idx;
                        s_active_drag_point_char = 'A';
                        s_original_drag_start_pos_float = pre_drag_a;
                        s_linked_points_for_this_drag.clear();
                        if (dev.level.wall.clip_to_neighboring_wall) {
                            constexpr f32 epsilon = 0.0001f;
                            for (usize i_other = 0; i_other < state.walls.n; ++i_other) {
                                if ((int)i_other == dev.level.wall.idx) continue;
                                Wall& other_w = state.walls.arr[i_other];
                                if (std::fabs(other_w.a.x - s_original_drag_start_pos_float.x) < epsilon &&
                                    std::fabs(other_w.a.y - s_original_drag_start_pos_float.y) < epsilon) {
                                    s_linked_points_for_this_drag.push_back({(int)i_other, 'A'});
                                }
                                if (std::fabs(other_w.b.x - s_original_drag_start_pos_float.x) < epsilon &&
                                    std::fabs(other_w.b.y - s_original_drag_start_pos_float.y) < epsilon) {
                                    s_linked_points_for_this_drag.push_back({(int)i_other, 'B'});
                                }
                            }
                        }
                        if (dev.level.wall.clip_to_neighboring_wall) {
                             for (const auto& linked_info : s_linked_points_for_this_drag) {
                                Wall& linked_wall = state.walls.arr[linked_info.first];
                                if (linked_info.second == 'A') linked_wall.a = selected_w.a;
                                else linked_wall.b = selected_w.a;
                            }
                        }
                    }
                    if (ImGui::IsItemActive()) any_point_widget_active_this_frame = true;
                    ImGui::PopID();

                    ImGui::PushID("PointBControls");
                    ImGui::Text("Point B"); ImGui::SameLine();
                    if (ImGui::DragFloat2("##CoordsB", &selected_w.b.x, drag_speed)) {
                         if (s_active_drag_wall_idx == dev.level.wall.idx && s_active_drag_point_char == 'B') {
                            if (dev.level.wall.clip_to_neighboring_wall) {
                                for (const auto &linked_info : s_linked_points_for_this_drag) {
                                    Wall& linked_wall = state.walls.arr[linked_info.first];
                                    if (linked_info.second == 'A') linked_wall.a = selected_w.b;
                                    else linked_wall.b = selected_w.b;
                                }
                            }
                        }
                    }
                     if (ImGui::IsItemActivated()) {
                        s_active_drag_wall_idx = dev.level.wall.idx;
                        s_active_drag_point_char = 'B';
                        s_original_drag_start_pos_float = pre_drag_b;
                        s_linked_points_for_this_drag.clear();
                        if (dev.level.wall.clip_to_neighboring_wall) {
                            constexpr f32 epsilon = 0.0001f;
                            for (usize i_other = 0; i_other < state.walls.n; ++i_other) {
                                if ((int)i_other == dev.level.wall.idx) continue;
                                Wall& other_w = state.walls.arr[i_other];
                                if (std::fabs(other_w.a.x - s_original_drag_start_pos_float.x) < epsilon &&
                                    std::fabs(other_w.a.y - s_original_drag_start_pos_float.y) < epsilon) {
                                    s_linked_points_for_this_drag.push_back({(int)i_other, 'A'});
                                }
                                if (std::fabs(other_w.b.x - s_original_drag_start_pos_float.x) < epsilon &&
                                    std::fabs(other_w.b.y - s_original_drag_start_pos_float.y) < epsilon) {
                                    s_linked_points_for_this_drag.push_back({(int)i_other, 'B'});
                                }
                            }
                        }
                        if (dev.level.wall.clip_to_neighboring_wall) {
                            for (const auto &linked_info : s_linked_points_for_this_drag) {
                                Wall& linked_wall = state.walls.arr[linked_info.first];
                                if (linked_info.second == 'A') linked_wall.a = selected_w.b;
                                else linked_wall.b = selected_w.b;
                            }
                        }
                    }
                    if (ImGui::IsItemActive()) {
                        any_point_widget_active_this_frame = true;
                    }
                    ImGui::PopID();

                    if (s_active_drag_wall_idx == dev.level.wall.idx && !any_point_widget_active_this_frame && s_active_drag_point_char != 0) {
                        s_active_drag_wall_idx = -1;
                        s_active_drag_point_char = 0;
                        s_linked_points_for_this_drag.clear();
                    }

                    ImGui::InputInt("Portal To Sector ID", &selected_w.portal);
                    if (selected_w.portal < SECTOR_NONE || selected_w.portal >= SECTOR_MAX) selected_w.portal = SECTOR_NONE;
                    ImGui::PopID();
                } // Eng Wall Config
                ImGui::End();
            } // End Level Config
            ImGui::End();
        }
        ImGui::Separator();
        ImGui::Text("Application average %.3f ms/frame (%.1f FPS)", 1000.0f / ImGui::GetIO().Framerate, ImGui::GetIO().Framerate);
        ImGui::End(); // End Engine
    }

    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), state.commandBuffer, state.renderEncoder);

    [state.renderEncoder popDebugGroup];
    [state.renderEncoder endEncoding];

    [state.commandBuffer presentDrawable:state.drawable];
    [state.commandBuffer commit];
}