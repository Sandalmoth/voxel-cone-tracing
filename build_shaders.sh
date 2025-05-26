glslc --target-env=vulkan1.0 raw/shaders/draw.vert -o data/shaders/draw.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/draw.frag -o data/shaders/draw.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/present.vert -o data/shaders/present.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/present.frag -o data/shaders/present.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/voxelize.comp -o data/shaders/voxelize.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/debug_voxel_draw.vert -o data/shaders/debug_voxel_draw.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/debug_voxel_draw.frag -o data/shaders/debug_voxel_draw.frag.spv
