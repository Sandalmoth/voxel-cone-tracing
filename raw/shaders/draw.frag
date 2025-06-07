#version 460

layout(location = 0) in vec3 frag_normal;
// these could have been fragment shader uniforms instead
layout(location = 1) in vec3 frag_diffuse;
layout(location = 2) in vec3 frag_emissive;
layout(location = 3) in float frag_roughness;
layout(location = 4) in vec3 frag_position;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler3D cascades_coverage;
layout(set = 2, binding = 1) uniform sampler3D cascades_radiance;

bool inBounds(vec3 position) {
    vec3 a = abs(position);
    float b = max(a.x, max(a.y, a.z));
    return b <= 504.0;
}

float sampleCoverageAt1(vec3 position, uint cascade) {
    float cascade_world_size = 64.0 * 0.125 * float(1 << cascade);
    vec3 uvw = position / cascade_world_size + 0.5;

    if (uvw.x < 0.0 || uvw.x > 1.0 || uvw.y < 0.0 || uvw.y > 1.0 ||
        uvw.z < 0.0 || uvw.z > 1.0) {
        return 0.0;
    }

    vec3 cascade_pos = vec3(
        0.125 * (uvw.x + float(cascade)),
        0.5 * uvw.y,
        uvw.z
    );

    vec3 cascade_texel_half = 0.5 / vec3(512.0, 128.0, 64.0);
    vec3 cascade_min = vec3(0.125 * float(cascade), 0.0, 0.0);
    vec3 cascade_max = vec3(0.125 * (1.0 + float(cascade)), 0.5, 1.0);
    
    vec3 safe_pos = clamp(
        cascade_pos,
        cascade_min + cascade_texel_half,
        cascade_max - cascade_texel_half
    );

    return texture(cascades_coverage, safe_pos).r;
}

float sampleCoverageAt(vec3 position, float diameter) {
    float fcascade = clamp(log2(diameter / 0.125), 0, 7);
    uint low_cascade = uint(fcascade);
    uint high_cascade = min(low_cascade + 1, 7);
    float cascade_fraction = fcascade - float(low_cascade);
    
    float low_coverage = sampleCoverageAt1(position, low_cascade);
    float high_coverage = sampleCoverageAt1(position, high_cascade);
    return (1 - cascade_fraction) * low_coverage + cascade_fraction * high_coverage;
}

float shadowRayDir(vec3 origin, vec3 light_dir, float voxel_size, vec3 normal) {
    float scale_factor = 0.05;

    origin += normal * voxel_size * 1;

    float acc = 0.0;
    origin += 1 * light_dir * voxel_size;
    float radius = 1 * scale_factor * voxel_size;

    while (acc < 0.95 && inBounds(origin)) {
        float cov = sampleCoverageAt(origin, 2 * radius);
        cov = cov * cov;
        acc += (1 - acc) * cov;
    
        radius = radius * (1 + scale_factor);
        float distance = radius * 0.5;
        
        origin += light_dir * distance;
    }

    return (acc < 0.95) ? acc : 1.0;
}

float diffuse_scale_factor = 0.44;
vec3 diffuse_cones[6] = vec3[](
    vec3(0.0, 1.0, 0.0),        
    vec3(0.894427, 0.447214, 0.0),
    vec3(0.276393, 0.447214, 0.850651),
    vec3(-0.723607, 0.447214, 0.525731),
    vec3(-0.723607, 0.447214, -0.525731),
    vec3(0.276393, 0.447214, -0.850651)
);

mat3 getAlignmentMatrix(vec3 normal) {
    vec3 new_y = normalize(normal);
    vec3 helper = vec3(0.0, 1.0, 0.0);
    if (abs(dot(new_y, helper)) > 0.999) {
        helper = vec3(1.0, 0.0, 0.0);
    }
    vec3 new_x = normalize(cross(helper, new_y));
    vec3 new_z = cross(new_y, new_x);
    return mat3(new_x, new_y, new_z);
}

vec4 sampleRadianceAt1(vec3 position, uint cascade) {
    float cascade_world_size = 64.0 * 0.125 * float(1 << cascade);
    vec3 uvw = position / cascade_world_size + 0.5;

    if (uvw.x < 0.0 || uvw.x > 1.0 || uvw.y < 0.0 || uvw.y > 1.0 ||
        uvw.z < 0.0 || uvw.z > 1.0) {
        return vec4(0.0, 0.0, 0.0, 0.0);
    }

    vec3 cascade_pos = vec3(
        0.125 * (uvw.x + float(cascade)),
        0.5 * uvw.y,
        uvw.z
    );

    vec3 cascade_texel_half = 0.5 / vec3(512.0, 128.0, 64.0);
    vec3 cascade_min = vec3(0.125 * float(cascade), 0.0, 0.0);
    vec3 cascade_max = vec3(0.125 * (1.0 + float(cascade)), 0.5, 1.0);
    
    vec3 safe_pos = clamp(
        cascade_pos,
        cascade_min + cascade_texel_half,
        cascade_max - cascade_texel_half
    );

    return texture(cascades_radiance, safe_pos);
}

vec4 sampleRadianceAt(vec3 position, float diameter) {
    float fcascade = clamp(log2(diameter / 0.125), 0, 7);
    uint low_cascade = uint(fcascade);
    uint high_cascade = min(low_cascade + 1, 7);
    float cascade_fraction = fcascade - float(low_cascade);
    vec4 low_radiance = sampleRadianceAt1(position, low_cascade);
    vec4 high_radiance = sampleRadianceAt1(position, high_cascade);
    return (1 - cascade_fraction) * low_radiance + cascade_fraction * high_radiance;
}

vec3 traceDiffuse(vec3 origin, vec3 cone_dir, float voxel_size) {
    float scale_factor = 0.5;

    vec4 acc = vec4(0.0, 0.0, 0.0, 0.0);
    origin += 0.5 * cone_dir * voxel_size;
    float radius = 1.0 * scale_factor * voxel_size;

    while (acc.a < 0.95 && inBounds(origin)) {
        vec4 rad = sampleRadianceAt(origin, 2 * radius);
        float cov = rad.a * rad.a;
        acc.rgb += (1.0 - acc.a) * rad.rgb * cov;
        acc.a += (1.0 - acc.a) * cov;
    
        radius = radius * (1 + scale_factor);
        float distance = radius * 0.666;
        
        origin += cone_dir * distance;
    }

    return acc.rgb;
}

vec3 gatherDiffuse(vec3 origin, float voxel_size, vec3 normal) {
    mat3 amat = getAlignmentMatrix(normal);
    vec3 acc = vec3(0.0, 0.0, 0.0);
    origin += normal * voxel_size * 2.0;
    for (int i = 0; i < 6; ++i) {
        vec3 cone_dir = amat * diffuse_cones[i];
        acc += traceDiffuse(origin, cone_dir, voxel_size);
    }
    return acc;
}

void main() {
    vec3 light_dir = normalize(vec3(1.0, 2.0, 0.5));
    float light_intensity = 1.0;

    vec3 a = abs(frag_position);
    float b = max(a.x, max(a.y, a.z));
    float cascade = clamp(log2(b) - 2, 0, 7);
    float voxel_size = clamp(0.0625 * b, 0.125, 16);

    vec3 rad =
        frag_diffuse * max(0.01,
            light_intensity *
            max(dot(frag_normal, light_dir), 0.0) *
            (1.0 - shadowRayDir(frag_position, light_dir, voxel_size, frag_normal))
        );
    rad += frag_emissive;
    rad += frag_diffuse * gatherDiffuse(frag_position, voxel_size, frag_normal) / 3.141592;
    // rad = gatherDiffuse(frag_position, voxel_size, frag_normal) / 3.141592;

    out_color = vec4(rad, 1.0);
}
