package gfx

// OpenGL rendering through rlgl. SDL owns the window, context, input and audio;
// this is the last small compatibility layer around raylib's low-level GL shim.

import "core:c"
import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import sdl "vendor:sdl3"

foreign import libc "system:c"

Material :: struct {}

Mesh :: struct {
	vertexCount:   c.int,
	triangleCount: c.int,
	vertices:      [^]f32,
	normals:       [^]f32,
	colors:        [^]u8,
	vao_id:        c.uint,
	vbo_id:        [3]c.uint,
}

GetRandomValue :: proc(minimum, maximum: i32) -> i32 {
	if maximum <= minimum { return minimum }
	return minimum + i32(sdl.rand(maximum - minimum + 1))
}

@(default_calling_convention = "c")
foreign libc {
	malloc :: proc(size: c.size_t) -> rawptr ---
	free :: proc(ptr: rawptr) ---
}

MemAlloc :: proc(size: c.uint) -> rawptr { return malloc(c.size_t(size)) }
MemFree :: proc(ptr: rawptr) { free(ptr) }
LoadMaterialDefault :: proc() -> Material { return {} }
UnloadMaterial :: proc(material: Material) {}

UploadMesh :: proc(mesh: ^Mesh, is_dynamic: bool) {
	if mesh == nil || mesh.vertexCount <= 0 { return }
	mesh.vao_id = rlgl.LoadVertexArray()
	_ = rlgl.EnableVertexArray(mesh.vao_id)
	mesh.vbo_id[0] = rlgl.LoadVertexBuffer(mesh.vertices, mesh.vertexCount * 3 * size_of(f32), is_dynamic)
	rlgl.SetVertexAttribute(0, 3, rlgl.FLOAT, false, 0, 0)
	rlgl.EnableVertexAttribute(0)
	mesh.vbo_id[1] = rlgl.LoadVertexBuffer(mesh.normals, mesh.vertexCount * 3 * size_of(f32), is_dynamic)
	rlgl.SetVertexAttribute(3, 3, rlgl.FLOAT, false, 0, 0)
	rlgl.EnableVertexAttribute(3)
	mesh.vbo_id[2] = rlgl.LoadVertexBuffer(mesh.colors, mesh.vertexCount * 4, is_dynamic)
	rlgl.SetVertexAttribute(5, 4, rlgl.UNSIGNED_BYTE, true, 0, 0)
	rlgl.EnableVertexAttribute(5)
	rlgl.DisableVertexArray()
}

UnloadMesh :: proc(mesh: Mesh) {
	if mesh.vao_id != 0 { rlgl.UnloadVertexArray(mesh.vao_id) }
	for id in mesh.vbo_id { if id != 0 { rlgl.UnloadVertexBuffer(id) } }
	if mesh.vertices != nil { free(mesh.vertices) }
	if mesh.normals != nil { free(mesh.normals) }
	if mesh.colors != nil { free(mesh.colors) }
}

DrawMesh :: proc(mesh: Mesh, material: Material, transform: Matrix) {
	if mesh.vao_id == 0 || mesh.vertexCount <= 0 { return }
	rlgl.DrawRenderBatchActive()
	shader := rlgl.GetShaderIdDefault()
	locs := rlgl.GetShaderLocsDefault()
	// These indices are raylib's stable ShaderLocationIndex values.
	model_view := transform * GetCameraMatrix(active_camera)
	mvp := model_view * active_projection
	rlgl.EnableShader(shader)
	rlgl.SetUniformMatrix(locs[6], transmute(rl.Matrix)mvp)
	rlgl.EnableTexture(rlgl.GetTextureIdDefault())
	if rlgl.EnableVertexArray(mesh.vao_id) {
		rlgl.DrawVertexArray(0, mesh.vertexCount)
	}
	rlgl.DisableVertexArray()
	rlgl.DisableTexture()
	rlgl.DisableShader()
}

SetClipPlanes       :: rlgl.SetClipPlanes
GetCullDistanceNear :: rlgl.GetCullDistanceNear
GetCullDistanceFar  :: rlgl.GetCullDistanceFar
EnableWireMode      :: rlgl.EnableWireMode
DisableWireMode     :: rlgl.DisableWireMode
EnableBackfaceCulling  :: rlgl.EnableBackfaceCulling
DisableBackfaceCulling :: rlgl.DisableBackfaceCulling

active_camera: Camera3D
active_projection: Matrix

BeginMode3D :: proc(camera: Camera3D) {
	active_camera = camera
	aspect := f32(GetScreenWidth()) / f32(max(1, GetScreenHeight()))
	active_projection = MatrixPerspective(camera.fovy * DEG2RAD, aspect, f32(GetCullDistanceNear()), f32(GetCullDistanceFar()))
	view := GetCameraMatrix(camera)
	rlgl.SetMatrixProjection(transmute(rl.Matrix)active_projection)
	rlgl.SetMatrixModelview(transmute(rl.Matrix)view)
	rlgl.EnableDepthTest()
}

EndMode3D :: proc() {
	rlgl.DrawRenderBatchActive()
	rlgl.DisableDepthTest()
	w, h := f64(GetScreenWidth()), f64(GetScreenHeight())
	rlgl.MatrixMode(rlgl.PROJECTION)
	rlgl.LoadIdentity()
	rlgl.Ortho(0, w, h, 0, 0, 1)
	rlgl.MatrixMode(rlgl.MODELVIEW)
	rlgl.LoadIdentity()
}

ClearBackground :: proc(color: Color) {
	rlgl.ClearColor(color[0], color[1], color[2], color[3])
	rlgl.ClearScreenBuffers()
}

vertex :: proc(p: Vector3, color: Color) {
	rlgl.Color4ub(color[0], color[1], color[2], color[3])
	rlgl.Vertex3f(p.x, p.y, p.z)
}

DrawLine3D :: proc(start, end: Vector3, color: Color) {
	rlgl.Begin(rlgl.LINES); vertex(start, color); vertex(end, color); rlgl.End()
}

DrawGrid :: proc(slices: i32, spacing: f32) {
	half := f32(slices) * spacing * 0.5
	for i in 0 ..= slices {
		p := -half + f32(i) * spacing
		color := Color{80, 80, 80, 255}
		if i == slices / 2 { color = {120, 120, 120, 255} }
		DrawLine3D({p, 0, -half}, {p, 0, half}, color)
		DrawLine3D({-half, 0, p}, {half, 0, p}, color)
	}
}

DrawSphere :: proc(center: Vector3, radius: f32, color: Color) { DrawSphereEx(center, radius, 12, 12, color) }
DrawSphereEx :: proc(center: Vector3, radius: f32, rings, slices: i32, color: Color) {
	ring_count, slice_count := max(rings, 3), max(slices, 3)
	for ring in 0 ..< ring_count {
		lat0 := -math.PI / 2 + math.PI * f32(ring) / f32(ring_count)
		lat1 := -math.PI / 2 + math.PI * f32(ring + 1) / f32(ring_count)
		rlgl.Begin(rlgl.TRIANGLES)
		for slice in 0 ..< slice_count {
			lon0 := 2 * math.PI * f32(slice) / f32(slice_count)
			lon1 := 2 * math.PI * f32(slice + 1) / f32(slice_count)
			p00 := center + radius * Vector3{math.cos(lat0)*math.sin(lon0), math.sin(lat0), math.cos(lat0)*math.cos(lon0)}
			p01 := center + radius * Vector3{math.cos(lat0)*math.sin(lon1), math.sin(lat0), math.cos(lat0)*math.cos(lon1)}
			p10 := center + radius * Vector3{math.cos(lat1)*math.sin(lon0), math.sin(lat1), math.cos(lat1)*math.cos(lon0)}
			p11 := center + radius * Vector3{math.cos(lat1)*math.sin(lon1), math.sin(lat1), math.cos(lat1)*math.cos(lon1)}
			vertex(p00,color); vertex(p10,color); vertex(p11,color)
			vertex(p00,color); vertex(p11,color); vertex(p01,color)
		}
		rlgl.End()
	}
}

DrawCylinderEx :: proc(start, end: Vector3, start_radius, end_radius: f32, sides: i32, color: Color) {
	axis := Vector3Normalize(end - start)
	ref := abs(axis.y) < 0.99 ? Vector3{0,1,0} : Vector3{1,0,0}
	u := Vector3Normalize(Vector3CrossProduct(axis, ref)); v := Vector3CrossProduct(axis, u)
	side_count := max(sides, 3)
	rlgl.Begin(rlgl.TRIANGLES)
	for i in 0 ..< side_count {
		a0 := 2*math.PI*f32(i)/f32(side_count); a1 := 2*math.PI*f32(i+1)/f32(side_count)
		d0 := u*math.cos(a0)+v*math.sin(a0); d1 := u*math.cos(a1)+v*math.sin(a1)
		a,b,c0,d := start+d0*start_radius, start+d1*start_radius, end+d0*end_radius, end+d1*end_radius
		vertex(a,color); vertex(c0,color); vertex(d,color); vertex(a,color); vertex(d,color); vertex(b,color)
		vertex(start,color); vertex(b,color); vertex(a,color); vertex(end,color); vertex(c0,color); vertex(d,color)
	}
	rlgl.End()
}

GetScreenToWorldRay :: proc(position: Vector2, camera: Camera3D) -> Ray {
	w, h := f32(max(1, GetScreenWidth())), f32(max(1, GetScreenHeight()))
	forward := Vector3Normalize(camera.target - camera.position)
	right := Vector3Normalize(Vector3CrossProduct(forward, camera.up))
	up := Vector3CrossProduct(right, forward)
	x := (2*position.x/w-1) * (w/h) * math.tan(camera.fovy*DEG2RAD*0.5)
	y := (1-2*position.y/h) * math.tan(camera.fovy*DEG2RAD*0.5)
	return {position = camera.position, direction = Vector3Normalize(forward + right*x + up*y)}
}
