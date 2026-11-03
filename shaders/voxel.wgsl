struct Globals {
    view_proj: mat4x4<f32>,
    cam_pos: vec4<f32>,
    screen: vec4<f32>,
};

@group(0) @binding(0) var<uniform> g: Globals;
@group(0) @binding(1) var scene_tex: texture_2d<f32>;
@group(0) @binding(2) var scene_smp: sampler;
@group(0) @binding(3) var block_tex: texture_2d_array<f32>;
@group(0) @binding(4) var block_smp: sampler;

struct VIn {
    @location(0) pos: vec3<f32>,
    @location(1) color: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) layer: f32,
};

struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) color: vec3<f32>,
    @location(1) wpos: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) @interpolate(flat) layer: u32,
};

@vertex
fn vs_voxel(in: VIn) -> VOut {
    var out: VOut;
    out.clip = g.view_proj * vec4<f32>(in.pos, 1.0);
    out.clip.y = -out.clip.y;
    out.color = in.color;
    out.wpos = in.pos;
    out.uv = in.uv;
    out.layer = u32(in.layer);
    return out;
}

@fragment
fn fs_voxel(in: VOut) -> @location(0) vec4<f32> {
    let albedo = textureSample(block_tex, block_smp, in.uv, in.layer).rgb;
    let horizon = vec3<f32>(0.66, 0.78, 0.94);
    let fog = smoothstep(70.0, 160.0, distance(in.wpos, g.cam_pos.xyz)) * 0.8;
    return vec4<f32>(mix(in.color * albedo, horizon, fog), 1.0);
}

struct HOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs_hud(in: VIn) -> HOut {
    var out: HOut;
    let x = in.pos.x / g.screen.x * 2.0 - 1.0;
    let y = in.pos.y / g.screen.y * 2.0 - 1.0;
    out.clip = vec4<f32>(x, y, 0.0, 1.0);
    out.color = in.color;
    return out;
}

@fragment
fn fs_hud(in: HOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 1.0);
}

@fragment
fn fs_outline(in: VOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 0.4);
}

struct FullOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_fullscreen(@builtin(vertex_index) vi: u32) -> FullOut {
    var p = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    let pos = p[vi];
    var out: FullOut;
    out.clip = vec4<f32>(pos, 0.0, 1.0);
    out.uv = (pos + vec2<f32>(1.0, 1.0)) * 0.5;
    return out;
}

@fragment
fn fs_composite(in: FullOut) -> @location(0) vec4<f32> {
    var col = textureSample(scene_tex, scene_smp, in.uv);
    let centered = (in.uv - vec2<f32>(0.5)) * vec2<f32>(1.02, 1.16);
    let v = smoothstep(0.26, 0.80, length(centered));
    let tint = mix(vec3<f32>(1.0), vec3<f32>(0.93, 0.88, 0.85), v);
    col = vec4<f32>(col.rgb * (1.0 - 0.36 * v) * tint, col.a);
    return col;
}
