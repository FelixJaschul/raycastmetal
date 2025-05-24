# Simple Makefile for Metal project

CXX = clang++
CXXFLAGS = -std=c++20 -Ilib -I/usr/local/include -I. `sdl2-config --cflags` -Wall -Wformat
OBJCXXFLAGS = $(CXXFLAGS) -ObjC++ -fobjc-weak -fobjc-arc

SRCS = main.mm \
       lib/imgui.cpp lib/imgui_demo.cpp lib/imgui_draw.cpp lib/imgui_tables.cpp lib/imgui_widgets.cpp \
       lib/imgui_impl_sdl2.cpp lib/imgui_impl_metal.mm

OBJS = $(SRCS:.cpp=.o)
OBJS := $(OBJS:.mm=.o)
OBJS := $(addprefix obj/,$(notdir $(OBJS)))

LIBS = -framework Metal -framework MetalKit -framework Cocoa -framework IOKit -framework CoreVideo -framework QuartzCore `sdl2-config --libs` -L/usr/local/lib -lSDL2_image

TARGET = bin/metal

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJS)
	@mkdir -p bin
	$(CXX) -o $@ $^ $(CXXFLAGS) $(LIBS)

obj/%.o: %.cpp
	@mkdir -p obj
	$(CXX) $(CXXFLAGS) -c $< -o $@

obj/%.o: %.mm
	@mkdir -p obj
	$(CXX) $(OBJCXXFLAGS) -c $< -o $@

obj/%.o: lib/%.cpp
	@mkdir -p obj
	$(CXX) $(CXXFLAGS) -c $< -o $@

obj/%.o: lib/%.mm
	@mkdir -p obj
	$(CXX) $(OBJCXXFLAGS) -c $< -o $@

clean:
	rm -rf obj
	rm -f $(TARGET)

run:
	clear
	make clean
	make all
	./bin/metal

# Touch rebuild
.PHONY: force
force:
	touch $(SRCS)
	make

# Debug info
.PHONY: debug
debug:
	@echo "SRCS: $(SRCS)"
	@echo "OBJS: $(OBJS)"
	@echo "TARGET: $(TARGET)"
