glslc --target-env=vulkan1.0 raw/shaders/draw.vert -o data/shaders/draw.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/draw.frag -o data/shaders/draw.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/prepass.frag -o data/shaders/prepass.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/shadowmap.frag -o data/shaders/shadowmap.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/present.vert -o data/shaders/present.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/present.frag -o data/shaders/present.frag.spv
