glslc --target-env=vulkan1.0 raw/shaders/draw.vert -o data/shaders/draw.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/draw.frag -o data/shaders/draw.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/prepass.frag -o data/shaders/prepass.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/shadowmap.frag -o data/shaders/shadowmap.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/present.vert -o data/shaders/present.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/present.frag -o data/shaders/present.frag.spv

glslc --target-env=vulkan1.0 raw/shaders/target_update.comp -o data/shaders/target_update.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/clear_bins.comp -o data/shaders/clear_bins.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/triangle_binning_a.comp -o data/shaders/triangle_binning_a.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/triangle_binning_b.comp -o data/shaders/triangle_binning_b.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/voxelization.comp -o data/shaders/voxelization.comp.spv

glslc --target-env=vulkan1.0 raw/shaders/blend_color.comp -o data/shaders/blend_color.comp.spv

glslc --target-env=vulkan1.0 raw/shaders/prefix.comp -o data/shaders/prefix.comp.spv

glslc --target-env=vulkan1.0 raw/shaders/debug.comp -o data/shaders/debug.comp.spv

