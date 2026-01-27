# voxel-radiance-cascades

![Screenshot](view0.png?raw=true)

An implementation of a cascaded voxel cone tracer that handles dynamic geometry
and large scenes (at least for voxelization, lighting a large scene isn't that good).
To get the scene to run it you need a copy of the sponza scene
`https://github.com/KhronosGroup/glTF-Sample-Assets/blob/main/Models/Sponza/README.md`
which then needs to be preprocessed using the .ipynb notebook in this repository.

After that, it should build and run with `zig build run` (zig version 0.15.2)
