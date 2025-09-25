glslc --target-env=vulkan1.0 raw/shaders/draw.vert -o data/shaders/draw.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/draw.frag -o data/shaders/draw.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/prepass.frag -o data/shaders/prepass.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/shadowmap.frag -o data/shaders/shadowmap.frag.spv
glslc --target-env=vulkan1.0 raw/shaders/present.vert -o data/shaders/present.vert.spv
glslc --target-env=vulkan1.0 raw/shaders/present.frag -o data/shaders/present.frag.spv

glslc --target-env=vulkan1.0 raw/shaders/triangle_binning.comp -o data/shaders/triangle_binning.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/target_update.comp -o data/shaders/target_update.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/voxelization.comp -o data/shaders/voxelization.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/cascade_update.comp -o data/shaders/cascade_update.comp.spv

# glslc --target-env=vulkan1.0 raw/shaders/clear.comp -o data/shaders/clear.comp.spv
# glslc --target-env=vulkan1.0 raw/shaders/voxelize.comp -o data/shaders/voxelize.comp.spv
# glslc --target-env=vulkan1.0 raw/shaders/average.comp -o data/shaders/average.comp.spv
# glslc --target-env=vulkan1.0 raw/shaders/count.comp -o data/shaders/count.comp.spv
# glslc --target-env=vulkan1.0 raw/shaders/prefix.comp -o data/shaders/prefix.comp.spv
# glslc --target-env=vulkan1.0 raw/shaders/assign.comp -o data/shaders/assign.comp.spv
# glslc --target-env=vulkan1.0 raw/shaders/inject.comp -o data/shaders/inject.comp.spv

glslc --target-env=vulkan1.0 raw/shaders/debug.comp -o data/shaders/debug.comp.spv

glslc --target-env=vulkan1.0 raw/shaders/upsample.comp -o data/shaders/upsample.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/tracing.comp -o data/shaders/tracing.comp.spv
glslc --target-env=vulkan1.0 raw/shaders/downsample.comp -o data/shaders/downsample.comp.spv

