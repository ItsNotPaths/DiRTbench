package gfx

// The application-facing graphics seam. Keeping backend names here confines
// the SDL3 migration to this package.

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Mesh          :: rl.Mesh
Material      :: rl.Material
Sound         :: rl.Sound

GetRandomValue             :: rl.GetRandomValue

DrawGrid                   :: rl.DrawGrid
DrawMesh                   :: rl.DrawMesh
LoadMaterialDefault        :: rl.LoadMaterialDefault
UnloadMaterial             :: rl.UnloadMaterial
MemAlloc                   :: rl.MemAlloc
UploadMesh                 :: rl.UploadMesh
UnloadMesh                 :: rl.UnloadMesh

InitAudioDevice            :: rl.InitAudioDevice
CloseAudioDevice           :: rl.CloseAudioDevice
IsAudioDeviceReady         :: rl.IsAudioDeviceReady
SetMasterVolume            :: rl.SetMasterVolume
LoadWaveFromMemory         :: rl.LoadWaveFromMemory
UnloadWave                 :: rl.UnloadWave
LoadSoundFromWave          :: rl.LoadSoundFromWave
UnloadSound                :: rl.UnloadSound
PlaySound                  :: rl.PlaySound
StopSound                  :: rl.StopSound
IsSoundPlaying             :: rl.IsSoundPlaying

SetClipPlanes              :: rlgl.SetClipPlanes
GetCullDistanceNear        :: rlgl.GetCullDistanceNear
GetCullDistanceFar         :: rlgl.GetCullDistanceFar
EnableWireMode             :: rlgl.EnableWireMode
DisableWireMode            :: rlgl.DisableWireMode
EnableBackfaceCulling      :: rlgl.EnableBackfaceCulling
DisableBackfaceCulling     :: rlgl.DisableBackfaceCulling

to_raylib_camera :: proc(camera: Camera3D) -> rl.Camera3D {
	return {
		position = camera.position,
		target = camera.target,
		up = camera.up,
		fovy = camera.fovy,
		projection = camera.projection == .PERSPECTIVE ? .PERSPECTIVE : .ORTHOGRAPHIC,
	}
}

BeginMode3D :: proc(camera: Camera3D) {
	aspect := f32(GetScreenWidth()) / f32(max(1, GetScreenHeight()))
	projection := MatrixPerspective(camera.fovy * DEG2RAD, aspect, f32(GetCullDistanceNear()), f32(GetCullDistanceFar()))
	view := GetCameraMatrix(camera)
	rlgl.SetMatrixProjection(transmute(rl.Matrix)projection)
	rlgl.SetMatrixModelview(transmute(rl.Matrix)view)
}

EndMode3D :: proc() {
	w, h := f64(GetScreenWidth()), f64(GetScreenHeight())
	rlgl.MatrixMode(rlgl.PROJECTION)
	rlgl.LoadIdentity()
	rlgl.Ortho(0, w, h, 0, 0, 1)
	rlgl.MatrixMode(rlgl.MODELVIEW)
	rlgl.LoadIdentity()
}

to_raylib_color :: proc(color: Color) -> rl.Color { return transmute(rl.Color)color }

ClearBackground :: proc(color: Color) {
	rlgl.ClearColor(color[0], color[1], color[2], color[3])
	rlgl.ClearScreenBuffers()
}
DrawLine3D :: proc(start, end: Vector3, color: Color) { rl.DrawLine3D(start, end, to_raylib_color(color)) }
DrawSphere :: proc(center: Vector3, radius: f32, color: Color) { rl.DrawSphere(center, radius, to_raylib_color(color)) }
DrawSphereEx :: proc(center: Vector3, radius: f32, rings, slices: i32, color: Color) {
	rl.DrawSphereEx(center, radius, rings, slices, to_raylib_color(color))
}
DrawCylinderEx :: proc(start, end: Vector3, start_radius, end_radius: f32, sides: i32, color: Color) {
	rl.DrawCylinderEx(start, end, start_radius, end_radius, sides, to_raylib_color(color))
}
GetScreenToWorldRay :: proc(position: Vector2, camera: Camera3D) -> Ray {
	r := rl.GetScreenToWorldRay(position, to_raylib_camera(camera))
	return {position = r.position, direction = r.direction}
}
