glslc --target-env=vulkan1.0 raw/shaders/draw.vert -o data/shaders/draw.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/draw.frag -o data/shaders/draw.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/prepass.frag -o data/shaders/prepass.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/shadowmap.frag -o data/shaders/shadowmap.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/present.vert -o data/shaders/present.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/present.frag -o data/shaders/present.frag.spv

glslc --target-env=vulkan1.0 raw/shaders/clear.comp -o data/shaders/clear.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/voxelize.comp -o data/shaders/voxelize.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/average.comp -o data/shaders/average.comp.spv
