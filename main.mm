#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_metal.h"
#include <cstdio>
#include <SDL2/SDL.h>

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#define ASSERT(_e, ...) if (!(_e)) { fprintf(stderr, __VA_ARGS__); exit(1); }

static struct {
  // SDL2
  SDL_Window *window{};
  SDL_Renderer *renderer{};

  // Metal
  CAMetalLayer *layer;
  MTLRenderPassDescriptor* renderPassDescriptor;

  id <MTLRenderCommandEncoder> renderEncoder;
  id<CAMetalDrawable> drawable;
  id<MTLCommandQueue> commandQueue;
  id<MTLCommandBuffer> commandBuffer;

  // Imgui
  bool show_demo_window{};
  bool show_another_window{};

  // Game
  bool done{};
} state;

int main(int, char**) {
    // Setup Dear ImGui context
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;  // Enable Keyboard Controls
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;   // Enable Gamepad Controls

    // Setup style
    ImGui::StyleColorsDark();

    // Setup SDL
    // (Some versions of SDL before <2.0.10 appears to have performance/stalling issues on a minority of Windows systems,
    // depending on whether SDL_INIT_GAMECONTROLLER is enabled or disabled.. updating to latest version of SDL is recommended!)
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER) != 0)
    ASSERT(0, "SDL_Init failed: %s\n", SDL_GetError());

    // Inform SDL that we will be using metal for rendering. Without this hint initialization of metal renderer may fail.
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");

    // Enable native IME.
    SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");

    state.window =
        SDL_CreateWindow("Dear ImGui SDL+Metal example",
                         SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                         1280, 720,
                         SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    ASSERT(state.window, "Failed to create window: %s\n", SDL_GetError());

    state.renderer =
        SDL_CreateRenderer(state.window, -1,
                           SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    ASSERT(state.renderer, "Error creating renderer: %s\n", SDL_GetError());

    // Setup Platform/Renderer backends
    state.layer = (__bridge CAMetalLayer*)
        SDL_RenderGetMetalLayer(state.renderer);
    state.layer.pixelFormat =
        MTLPixelFormatBGRA8Unorm;

    ImGui_ImplMetal_Init(state.layer.device);
    ImGui_ImplSDL2_InitForMetal(state.window);

    state.commandQueue =
        [state.layer.device newCommandQueue];
    state.renderPassDescriptor =
        [MTLRenderPassDescriptor new];

    // Our state
    state.show_demo_window = true;
    state.show_another_window = false;
    float clear_color[4] = {0.45f, 0.55f, 0.60f, 1.00f};

    // Main loop
    state.done = false;
    while (!state.done) {
        @autoreleasepool {
            SDL_Event event;
            while (SDL_PollEvent(&event)) {
                ImGui_ImplSDL2_ProcessEvent(&event);
                if (event.type == SDL_QUIT)
                    state.done = true;
                if (event.type == SDL_WINDOWEVENT
                    && event.window.event
                    == SDL_WINDOWEVENT_CLOSE
                    && event.window.windowID
                    == SDL_GetWindowID(state.window))
                    state.done = true;
            }

            int width, height;
            SDL_GetRendererOutputSize(state.renderer, &width, &height);
            state.layer.drawableSize = CGSizeMake(width, height);
            state.drawable = [state.layer nextDrawable];

            state.commandBuffer = [state.commandQueue commandBuffer];
            state.renderPassDescriptor.colorAttachments[0].clearColor =
                MTLClearColorMake(clear_color[0]
                    * clear_color[3], clear_color[1]
                    * clear_color[3], clear_color[2]
                    * clear_color[3], clear_color[3]);
            state.renderPassDescriptor.colorAttachments[0].texture =
                state.drawable.texture;
            state.renderPassDescriptor.colorAttachments[0].loadAction =
                MTLLoadActionClear;
            state.renderPassDescriptor.colorAttachments[0].storeAction =
                MTLStoreActionStore;
            state.renderEncoder =
                [state.commandBuffer renderCommandEncoderWithDescriptor:state.renderPassDescriptor];
            [state.renderEncoder pushDebugGroup:@"ImGui demo"];

            // Start the Dear ImGui frame
            ImGui_ImplMetal_NewFrame(state.renderPassDescriptor);
            ImGui_ImplSDL2_NewFrame();
            ImGui::NewFrame();

            // 1. Show the big demo window (Most of the sample code is in ImGui::ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
            if (state.show_demo_window) ImGui::ShowDemoWindow(&state.show_demo_window);

            // 2. Show a simple window that we create ourselves. We use a Begin/End pair to create a named window.
            {
                static float f = 0.0f;
                static int counter = 0;

                ImGui::Begin("Hello, world!");

                ImGui::Text("This is some useful text.");
                ImGui::Checkbox("Demo Window", &state.show_demo_window);
                ImGui::Checkbox("Another Window", &state.show_another_window);

                ImGui::SliderFloat("float", &f, 0.0f, 1.0f);
                ImGui::ColorEdit3("clear color", (float*)&clear_color);

                if (ImGui::Button("Button")) counter++;
                ImGui::SameLine();
                ImGui::Text("counter = %d", counter);

                ImGui::Text("Application average %.3f ms/frame (%.1f FPS)", 1000.0f / io.Framerate, io.Framerate);
                ImGui::End();
            }

            // 3. Show another simple window.
            if (state.show_another_window) {
                ImGui::Begin("Another Window", &state.show_another_window);
                ImGui::Text("Hello from another window!");
                if (ImGui::Button("Close Me")) state.show_another_window = false;
                ImGui::End();
            }

            // Rendering
            ImGui::Render();
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), state.commandBuffer, state.renderEncoder);

            [state.renderEncoder popDebugGroup];
            [state.renderEncoder endEncoding];

            [state.commandBuffer presentDrawable:state.drawable];
            [state.commandBuffer commit];
        }
    }

    // Cleanup
    ImGui_ImplMetal_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();

    SDL_DestroyRenderer(state.renderer);
    SDL_DestroyWindow(state.window);
    SDL_Quit();

    return 0;
}
