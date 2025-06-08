glslc --target-env=vulkan1.0 raw/shaders/draw.vert -o data/shaders/draw.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/draw.frag -o data/shaders/draw.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/present.vert -o data/shaders/present.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/present.frag -o data/shaders/present.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/clear.comp -o data/shaders/clear.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/voxelization.comp -o data/shaders/voxelization.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/shading.comp -o data/shaders/shading.comp.spv
