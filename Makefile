# You need vulkan (brew) and sdl (brew) and be on a mac
# Just do make run in the terminal and ba boom we got it

CXX = clang++

EXE = $(BIN_DIR)/metal
IMGUI_DIR = /Library/Developer/CommandLineTools/usr/include/IMGUI
BIN_DIR = bin
SOURCES = main.mm
SOURCES += $(IMGUI_DIR)/imgui.cpp $(IMGUI_DIR)/imgui_demo.cpp $(IMGUI_DIR)/imgui_draw.cpp $(IMGUI_DIR)/imgui_tables.cpp $(IMGUI_DIR)/imgui_widgets.cpp
SOURCES += $(IMGUI_DIR)/backends/imgui_impl_sdl2.cpp $(IMGUI_DIR)/backends/imgui_impl_metal.mm
OBJS = $(addprefix $(BIN_DIR)/, $(addsuffix .o, $(basename $(notdir $(SOURCES)))))

LIBS = -framework Metal -framework MetalKit -framework Cocoa -framework IOKit -framework CoreVideo -framework QuartzCore
LIBS += `sdl2-config --libs`
LIBS += -L/usr/local/lib

CXXFLAGS = -std=c++20 -I$(IMGUI_DIR) -I$(IMGUI_DIR)/backends -I/usr/local/include
CXXFLAGS += `sdl2-config --cflags`
CXXFLAGS += -Wall -Wformat
CFLAGS = $(CXXFLAGS)

$(BIN_DIR)/%.o:%.cpp | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BIN_DIR)/%.o:$(IMGUI_DIR)/%.cpp | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BIN_DIR)/%.o:$(IMGUI_DIR)/backends/%.cpp | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BIN_DIR)/%.o:%.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -ObjC++ -fobjc-weak -fobjc-arc -c -o $@ $<

$(BIN_DIR)/%.o:$(IMGUI_DIR)/backends/%.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -ObjC++ -fobjc-weak -fobjc-arc -c -o $@ $<

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

all: $(BIN_DIR) $(EXE)
	@echo Build complete

$(EXE): $(OBJS)
	$(CXX) -o $@ $(OBJS) $(CXXFLAGS) $(LIBS)

clean:
	rm -f $(EXE) $(OBJS)
	rmdir $(BIN_DIR) 2>/dev/null || true

run:
	clear
	make clean
	make all
	./bin/metal

# Force rebuild of object files
.PHONY: force
force:
	touch main.mm
	make

# Debug target
.PHONY: debug
debug:
	@echo "SOURCES: $(SOURCES)"
	@echo "OBJS: $(OBJS)"
	@echo "BIN_DIR: $(BIN_DIR)"
