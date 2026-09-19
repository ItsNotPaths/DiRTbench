package gfx

// Scene rendering through SDL_GPU (Vulkan underneath). SDL owns the window and
// input in window.odin; this file owns the GPU device, the shared shaders and
// pipelines, static mesh buffers, and the per-frame debug batch.
//
// Two draw kinds share one shader pair (unlit, vertex-coloured):
// static meshes (road, terrain) uploaded once per rebuild, and immediate-mode
// lines and triangles (grid, handles, vegetation, markers) rebuilt on the CPU
// every frame. Static draws are recorded during the frame and flushed, with
// the debug batch, by EndMode3D; nothing records GPU commands directly.

import "core:math"
import sdl "vendor:sdl3"

Material :: struct {}

// One interleaved vertex: 12 bytes of position plus 4 bytes of colour.
Upload_Vertex :: struct {
	pos: Vector3,
	col: Color,
}

Mesh :: struct {
	buffer: ^sdl.GPUBuffer,
	verts:  u32,
}

Scene_Draw :: struct {
	mesh: Mesh,
	mvp:  Matrix,
	wire: bool,
	cull: bool,
}

BATCH_MAX_VERTS :: 1 << 18

mesh_vert_spv := #load("../../build/shaders/mesh.vert.spv", []u8)
mesh_frag_spv := #load("../../build/shaders/mesh.frag.spv", []u8)

gpu_device:  ^sdl.GPUDevice
gpu_format:  sdl.GPUTextureFormat
vert_shader: ^sdl.GPUShader
frag_shader: ^sdl.GPUShader

Pipeline_Slot :: enum { Tri_Fill, Tri_Fill_Cull, Tri_Line, Tri_Line_Cull, Lines }
pipelines: [Pipeline_Slot]^sdl.GPUGraphicsPipeline

// Indexed [wire][cull].
PIPELINE_FOR_FILL := [2][2]Pipeline_Slot{{.Tri_Fill, .Tri_Fill_Cull}, {.Tri_Line, .Tri_Line_Cull}}

batch_buf:  ^sdl.GPUBuffer
batch_xfer: ^sdl.GPUTransferBuffer

scene_draws: [dynamic]Scene_Draw
batch_lines: [dynamic]Upload_Vertex
batch_tris:  [dynamic]Upload_Vertex

active_camera:     Camera3D
active_projection: Matrix
clip_near: f32 = 0.1
clip_far:  f32 = 10000
wire_mode: bool
cull_mode: bool = true

// Where the scene pass draws. A capture (capture.odin) takes precedence over
// the active window, so the same draw calls fill a thumbnail or a viewport with
// nothing in between knowing which.
Render_Target :: struct {
	cmd:   ^sdl.GPUCommandBuffer,
	color: ^sdl.GPUTexture,
	depth: ^sdl.GPUTexture,
	w, h:  i32,
	clear: sdl.FColor,
}

render_target :: proc() -> Render_Target {
	if c := active_capture; c != nil {
		return {c.cmd, c.color, c.depth, c.w, c.h, c.clear}
	}
	if w := active_window; w != nil {
		return {w.cmd, w.swapchain, w.depth, w.swapchain_w, w.swapchain_h, w.clear}
	}
	return {}
}

LoadMaterialDefault :: proc() -> Material {
	return {}
}
UnloadMaterial :: proc(material: Material) {}

// The device properties SDL needs to select the Vulkan backend. The SPIR-V
// flag is what selects it.
gpu_device_props :: proc() -> sdl.PropertiesID {
	props := sdl.CreateProperties()
	sdl.SetStringProperty(props, sdl.PROP_GPU_DEVICE_CREATE_NAME_STRING, "vulkan")
	sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true)
	when ODIN_DEBUG {
		sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, true)
	}
	return props
}

ensure_gpu :: proc() -> bool {
	if gpu_device != nil {
		return true
	}
	props := gpu_device_props()
	defer sdl.DestroyProperties(props)
	gpu_device = sdl.CreateGPUDeviceWithProperties(props)
	if gpu_device == nil {
		return false
	}
	vert_shader = make_shader(mesh_vert_spv, .VERTEX, 1)
	frag_shader = make_shader(mesh_frag_spv, .FRAGMENT, 0)
	if vert_shader == nil || frag_shader == nil {
		drop_gpu()
		return false
	}
	batch_buf = sdl.CreateGPUBuffer(gpu_device, {usage = {.VERTEX}, size = u32(BATCH_MAX_VERTS * size_of(Upload_Vertex))})
	batch_xfer = sdl.CreateGPUTransferBuffer(gpu_device, {usage = .UPLOAD, size = u32(BATCH_MAX_VERTS * size_of(Upload_Vertex))})
	if batch_buf == nil || batch_xfer == nil {
		drop_gpu()
		return false
	}
	return true
}

make_shader :: proc(code: []u8, stage: sdl.GPUShaderStage, uniforms: u32) -> ^sdl.GPUShader {
	return sdl.CreateGPUShader(
		gpu_device,
		{
			code_size = uint(len(code)),
			code = raw_data(code),
			entrypoint = "main",
			format = {.SPIRV},
			stage = stage,
			num_uniform_buffers = uniforms,
		},
	)
}

ensure_pipelines :: proc(format: sdl.GPUTextureFormat) -> bool {
	if pipelines[.Tri_Fill] != nil && gpu_format == format {
		return true
	}
	release_pipelines()
	gpu_format = format
	pipelines[.Tri_Fill] = make_pipeline(.TRIANGLELIST, .FILL, .NONE)
	pipelines[.Tri_Fill_Cull] = make_pipeline(.TRIANGLELIST, .FILL, .BACK)
	pipelines[.Tri_Line] = make_pipeline(.TRIANGLELIST, .LINE, .NONE)
	pipelines[.Tri_Line_Cull] = make_pipeline(.TRIANGLELIST, .LINE, .BACK)
	pipelines[.Lines] = make_pipeline(.LINELIST, .FILL, .NONE)
	for p in pipelines {
		if p == nil {
			release_pipelines()
			return false
		}
	}
	return true
}

make_pipeline :: proc(topology: sdl.GPUPrimitiveType, fill: sdl.GPUFillMode, cull: sdl.GPUCullMode) -> ^sdl.GPUGraphicsPipeline {
	buffer_desc := sdl.GPUVertexBufferDescription{slot = 0, pitch = u32(size_of(Upload_Vertex)), input_rate = .VERTEX}
	attrs := [2]sdl.GPUVertexAttribute{{location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0}, {location = 1, buffer_slot = 0, format = .UBYTE4_NORM, offset = 12}}
	targets := [1]sdl.GPUColorTargetDescription{{format = gpu_format}}
	// No Y mirror in the projection, so counter-clockwise stays front-facing.
	return sdl.CreateGPUGraphicsPipeline(
		gpu_device,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			vertex_input_state = {vertex_buffer_descriptions = &buffer_desc, num_vertex_buffers = 1, vertex_attributes = &attrs[0], num_vertex_attributes = 2},
			primitive_type = topology,
			rasterizer_state = {fill_mode = fill, cull_mode = cull, front_face = .COUNTER_CLOCKWISE},
			multisample_state = {sample_count = ._1},
			depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
			target_info = {color_target_descriptions = &targets[0], num_color_targets = 1, depth_stencil_format = .D32_FLOAT, has_depth_stencil_target = true},
		},
	)
}

release_pipelines :: proc() {
	if gpu_device == nil {
		return
	}
	for p, i in pipelines {
		if p != nil {
			sdl.ReleaseGPUGraphicsPipeline(gpu_device, p)
			pipelines[i] = nil
		}
	}
}

drop_gpu :: proc() {
	if gpu_device == nil {
		return
	}
	release_pipelines()
	if batch_buf != nil {
		sdl.ReleaseGPUBuffer(gpu_device, batch_buf)
		batch_buf = nil
	}
	if batch_xfer != nil {
		sdl.ReleaseGPUTransferBuffer(gpu_device, batch_xfer)
		batch_xfer = nil
	}
	if vert_shader != nil {
		sdl.ReleaseGPUShader(gpu_device, vert_shader)
		vert_shader = nil
	}
	if frag_shader != nil {
		sdl.ReleaseGPUShader(gpu_device, frag_shader)
		frag_shader = nil
	}
	sdl.DestroyGPUDevice(gpu_device)
	gpu_device = nil
	clear(&scene_draws)
	clear(&batch_lines)
	clear(&batch_tris)
}

// --- static meshes ----------------------------------------------------------

mesh_upload :: proc(verts: []Upload_Vertex) -> Mesh {
	if len(verts) == 0 {
		return {}
	}
	if gpu_device == nil {
		return {verts = u32(len(verts))}
	}
	size := u32(len(verts) * size_of(Upload_Vertex))
	buf := sdl.CreateGPUBuffer(gpu_device, {usage = {.VERTEX}, size = size})
	xfer := sdl.CreateGPUTransferBuffer(gpu_device, {usage = .UPLOAD, size = size})
	if buf == nil || xfer == nil {
		if buf != nil {
			sdl.ReleaseGPUBuffer(gpu_device, buf)
		}
		if xfer != nil {
			sdl.ReleaseGPUTransferBuffer(gpu_device, xfer)
		}
		return {verts = u32(len(verts))}
	}
	dst := sdl.MapGPUTransferBuffer(gpu_device, xfer, false)
	copy(([^]Upload_Vertex)(dst)[:len(verts)], verts)
	sdl.UnmapGPUTransferBuffer(gpu_device, xfer)
	cmd := sdl.AcquireGPUCommandBuffer(gpu_device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = xfer}, {buffer = buf, size = size}, false)
	sdl.EndGPUCopyPass(copy_pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	_ = sdl.WaitForGPUFences(gpu_device, true, &fence, 1)
	sdl.ReleaseGPUFence(gpu_device, fence)
	sdl.ReleaseGPUTransferBuffer(gpu_device, xfer)
	return {buffer = buf, verts = u32(len(verts))}
}

mesh_free :: proc(mesh: ^Mesh) {
	if mesh == nil {
		return
	}
	if mesh.buffer != nil && gpu_device != nil {
		sdl.ReleaseGPUBuffer(gpu_device, mesh.buffer)
	}
	mesh^ = {}
}

// Model, then view, then projection: projection applies last.
scene_mvp :: proc(transform: Matrix) -> Matrix {
	return active_projection * GetCameraMatrix(active_camera) * transform
}

DrawMesh :: proc(mesh: Mesh, material: Material, transform: Matrix) {
	if mesh.verts == 0 {
		return
	}
	append(&scene_draws, Scene_Draw{mesh = mesh, mvp = scene_mvp(transform), wire = wire_mode, cull = cull_mode})
}

SetClipPlanes :: proc(near, far: f32) {
	clip_near, clip_far = near, far
}
GetCullDistanceNear :: proc() -> f32 {
	return clip_near
}
GetCullDistanceFar :: proc() -> f32 {
	return clip_far
}
EnableWireMode :: proc() {
	wire_mode = true
}
DisableWireMode :: proc() {
	wire_mode = false
}
EnableBackfaceCulling :: proc() {
	cull_mode = true
}
DisableBackfaceCulling :: proc() {
	cull_mode = false
}

// --- frame ------------------------------------------------------------------

BeginMode3D :: proc(camera: Camera3D) {
	active_camera = camera
	aspect := f32(GetScreenWidth()) / f32(max(1, GetScreenHeight()))
	active_projection = MatrixPerspective(camera.fovy * DEG2RAD, aspect, clip_near, clip_far)
	clear(&scene_draws)
	clear(&batch_lines)
	clear(&batch_tris)
	batch_dropped = 0
}

// Uploads the debug batch, then draws it after every static mesh, in one
// render pass over the swapchain. A frame with no 3D draws opens no pass;
// the ImGui pass clears instead.
EndMode3D :: proc() {
	t := render_target()
	defer clear(&scene_draws)
	defer clear(&batch_lines)
	defer clear(&batch_tris)
	if t.cmd == nil || t.color == nil || t.depth == nil || gpu_device == nil {
		return
	}
	// A window with nothing to draw opens no pass; the ImGui pass clears it
	// instead. A capture has no ImGui pass behind it, so it must open one
	// anyway or the texture is read back holding whatever was there before.
	if len(scene_draws) == 0 && len(batch_lines) == 0 && len(batch_tris) == 0 &&
	   active_capture == nil {
		return
	}
	if total := len(batch_lines) + len(batch_tris); total > 0 {
		// Lines first: the tri draw below starts at first_vertex = line count.
		dst := sdl.MapGPUTransferBuffer(gpu_device, batch_xfer, false)
		out := ([^]Upload_Vertex)(dst)[:total]
		copy(out[:len(batch_lines)], batch_lines[:])
		copy(out[len(batch_lines):], batch_tris[:])
		sdl.UnmapGPUTransferBuffer(gpu_device, batch_xfer)
		copy_pass := sdl.BeginGPUCopyPass(t.cmd)
		sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = batch_xfer}, {buffer = batch_buf, size = u32(total) * size_of(Upload_Vertex)}, true)
		sdl.EndGPUCopyPass(copy_pass)
	}
	depth_info := sdl.GPUDepthStencilTargetInfo{texture = t.depth, clear_depth = 1, load_op = .CLEAR, store_op = .DONT_CARE, stencil_load_op = .DONT_CARE, stencil_store_op = .DONT_CARE}
	color_info := sdl.GPUColorTargetInfo{texture = t.color, clear_color = t.clear, load_op = .CLEAR, store_op = .STORE}
	pass := sdl.BeginGPURenderPass(t.cmd, &color_info, 1, &depth_info)
	sdl.SetGPUViewport(pass, {w = f32(t.w), h = f32(t.h), min_depth = 0, max_depth = 1})
	for d in scene_draws {
		if d.mesh.buffer == nil {
			continue
		}
		sdl.BindGPUGraphicsPipeline(pass, pipelines[PIPELINE_FOR_FILL[int(d.wire)][int(d.cull)]])
		binding := sdl.GPUBufferBinding{buffer = d.mesh.buffer}
		sdl.BindGPUVertexBuffers(pass, 0, &binding, 1)
		push_mvp(t.cmd, d.mvp)
		sdl.DrawGPUPrimitives(pass, d.mesh.verts, 1, 0, 0)
	}
	if len(batch_lines) > 0 {
		sdl.BindGPUGraphicsPipeline(pass, pipelines[.Lines])
		binding := sdl.GPUBufferBinding{buffer = batch_buf}
		sdl.BindGPUVertexBuffers(pass, 0, &binding, 1)
		push_mvp(t.cmd, scene_mvp(Matrix(1)))
		sdl.DrawGPUPrimitives(pass, u32(len(batch_lines)), 1, 0, 0)
	}
	if len(batch_tris) > 0 {
		sdl.BindGPUGraphicsPipeline(pass, pipelines[.Tri_Fill])
		binding := sdl.GPUBufferBinding{buffer = batch_buf}
		sdl.BindGPUVertexBuffers(pass, 0, &binding, 1)
		push_mvp(t.cmd, scene_mvp(Matrix(1)))
		sdl.DrawGPUPrimitives(pass, u32(len(batch_tris)), 1, u32(len(batch_lines)), 0)
	}
	sdl.EndGPURenderPass(pass)
	if active_capture == nil && active_window != nil {
		active_window.scene_drawn = true
	}
}

push_mvp :: proc(cmd: ^sdl.GPUCommandBuffer, mvp: Matrix) {
	v := MatrixToFloatV(mvp)
	sdl.PushGPUVertexUniformData(cmd, 0, &v, u32(size_of(v)))
}

ClearBackground :: proc(color: Color) {
	c := sdl.FColor{f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255}
	if active_capture != nil {
		active_capture.clear = c
	} else if active_window != nil {
		active_window.clear = c
	}
}

// --- immediate mode ---------------------------------------------------------

// Verts the batch had to refuse this frame. The buffer is a fixed size and the
// overlay it carries is not — a big stage's sculpt nodes and its trees both scale
// with the stage — so what does not fit is counted and reported (see the Veg
// panel) rather than vanishing. Whatever draws last is what goes missing.
batch_dropped: int

batch_dropped_verts :: proc() -> int {
	return batch_dropped
}

batch_has_room :: proc(n: int) -> bool {
	if len(batch_lines) + len(batch_tris) + n <= BATCH_MAX_VERTS {
		return true
	}
	batch_dropped += n
	return false
}

batch_tri :: proc(a, b, c: Vector3, color: Color) {
	if !batch_has_room(3) {
		return
	}
	append(&batch_tris, Upload_Vertex{a, color}, Upload_Vertex{b, color}, Upload_Vertex{c, color})
}

DrawLine3D :: proc(start, end: Vector3, color: Color) {
	if !batch_has_room(2) {
		return
	}
	append(&batch_lines, Upload_Vertex{start, color}, Upload_Vertex{end, color})
}

DrawGrid :: proc(slices: i32, spacing: f32) {
	half := f32(slices) * spacing * 0.5
	for i in 0 ..= slices {
		p := -half + f32(i) * spacing
		color := Color{80, 80, 80, 255}
		if i == slices / 2 {
			color = {120, 120, 120, 255}
		}
		DrawLine3D({p, 0, -half}, {p, 0, half}, color)
		DrawLine3D({-half, 0, p}, {half, 0, p}, color)
	}
}

DrawSphere :: proc(center: Vector3, radius: f32, color: Color) {
	DrawSphereEx(center, radius, 12, 12, color)
}
// Where a generated primitive's triangles land. The overlay batch is one sink and
// is rebuilt every frame; a mesh builder is the other, for scenery uploaded once.
// The shape maths lives in one place either way.
Tri_Sink :: struct {
	emit: proc(user: rawptr, a, b, c: Vector3, col: Color),
	user: rawptr,
}

batch_sink :: proc() -> Tri_Sink {
	return {emit = proc(user: rawptr, a, b, c: Vector3, col: Color) {
		batch_tri(a, b, c, color = col)
	}}
}

DrawSphereEx :: proc(center: Vector3, radius: f32, rings, slices: i32, color: Color) {
	SphereEx(batch_sink(), center, radius, rings, slices, color)
}

SphereEx :: proc(sink: Tri_Sink, center: Vector3, radius: f32, rings, slices: i32, color: Color) {
	ring_count, slice_count := max(rings, 3), max(slices, 3)
	for ring in 0 ..< ring_count {
		lat0 := -math.PI / 2 + math.PI * f32(ring) / f32(ring_count)
		lat1 := -math.PI / 2 + math.PI * f32(ring + 1) / f32(ring_count)
		for slice in 0 ..< slice_count {
			lon0 := 2 * math.PI * f32(slice) / f32(slice_count)
			lon1 := 2 * math.PI * f32(slice + 1) / f32(slice_count)
			p00 := center + radius * Vector3{math.cos(lat0) * math.sin(lon0), math.sin(lat0), math.cos(lat0) * math.cos(lon0)}
			p01 := center + radius * Vector3{math.cos(lat0) * math.sin(lon1), math.sin(lat0), math.cos(lat0) * math.cos(lon1)}
			p10 := center + radius * Vector3{math.cos(lat1) * math.sin(lon0), math.sin(lat1), math.cos(lat1) * math.cos(lon0)}
			p11 := center + radius * Vector3{math.cos(lat1) * math.sin(lon1), math.sin(lat1), math.cos(lat1) * math.cos(lon1)}
			sink.emit(sink.user, p00, p10, p11, color)
			sink.emit(sink.user, p00, p11, p01, color)
		}
	}
}

DrawDiamond :: proc(centre: Vector3, radius, half_height: f32, color: Color) {
	Diamond(batch_sink(), centre, radius, half_height, color)
}

// An octahedron standing on its point: the map-pin shape, readable from any
// angle. Faces are shaded off a fixed light, because the overlay batch carries
// no lighting and one flat colour reads as a hexagon rather than a solid.
Diamond :: proc(sink: Tri_Sink, centre: Vector3, radius, half_height: f32, color: Color) {
	top := centre + Vector3{0, half_height, 0}
	bottom := centre - Vector3{0, half_height, 0}
	ring := [4]Vector3{
		centre + {radius, 0, 0}, centre + {0, 0, radius},
		centre + {-radius, 0, 0}, centre + {0, 0, -radius},
	}
	for i in 0 ..< 4 {
		a, b := ring[i], ring[(i + 1) % 4]
		for tri in ([2][3]Vector3{{top, a, b}, {bottom, b, a}}) {
			normal := Vector3Normalize(
				Vector3CrossProduct(tri[1] - tri[0], tri[2] - tri[0]),
			)
			sink.emit(sink.user, tri[0], tri[1], tri[2], shade_face(color, normal))
		}
	}
}

// Lambert against one overhead light, floored so no face goes black.
shade_face :: proc(col: Color, normal: Vector3) -> Color {
	lit := 0.55 + 0.45 * max(0, Vector3DotProduct(normal, Vector3Normalize({0.35, 1, 0.2})))
	return {u8(f32(col.r) * lit), u8(f32(col.g) * lit), u8(f32(col.b) * lit), col.a}
}

DrawCylinderEx :: proc(start, end: Vector3, start_radius, end_radius: f32, sides: i32, color: Color) {
	CylinderEx(batch_sink(), start, end, start_radius, end_radius, sides, color)
}

CylinderEx :: proc(
	sink: Tri_Sink,
	start, end: Vector3,
	start_radius, end_radius: f32,
	sides: i32,
	color: Color,
) {
	axis := Vector3Normalize(end - start)
	ref := abs(axis.y) < 0.99 ? Vector3{0, 1, 0} : Vector3{1, 0, 0}
	u := Vector3Normalize(Vector3CrossProduct(axis, ref))
	v := Vector3CrossProduct(axis, u)
	side_count := max(sides, 3)
	for i in 0 ..< side_count {
		a0 := 2 * math.PI * f32(i) / f32(side_count)
		a1 := 2 * math.PI * f32(i + 1) / f32(side_count)
		d0 := u * math.cos(a0) + v * math.sin(a0)
		d1 := u * math.cos(a1) + v * math.sin(a1)
		a, b, c0, d := start + d0 * start_radius, start + d1 * start_radius, end + d0 * end_radius, end + d1 * end_radius
		sink.emit(sink.user, a, c0, d, color)
		sink.emit(sink.user, a, d, b, color)
		sink.emit(sink.user, start, b, a, color)
		sink.emit(sink.user, end, c0, d, color)
	}
}

GetScreenToWorldRay :: proc(position: Vector2, camera: Camera3D) -> Ray {
	w, h := f32(max(1, GetScreenWidth())), f32(max(1, GetScreenHeight()))
	forward := Vector3Normalize(camera.target - camera.position)
	right := Vector3Normalize(Vector3CrossProduct(forward, camera.up))
	up := Vector3CrossProduct(right, forward)
	x := (2 * position.x / w - 1) * (w / h) * math.tan(camera.fovy * DEG2RAD * 0.5)
	y := (1 - 2 * position.y / h) * math.tan(camera.fovy * DEG2RAD * 0.5)
	return {position = camera.position, direction = Vector3Normalize(forward + right * x + up * y)}
}
