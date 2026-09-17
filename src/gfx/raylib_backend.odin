package gfx

// The application-facing graphics seam. Keeping backend names here confines
// the SDL3 migration to this package.

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Mesh          :: rl.Mesh
Material      :: rl.Material
Sound         :: rl.Sound

SetConfigFlags             :: rl.SetConfigFlags
InitWindow                 :: rl.InitWindow
CloseWindow                :: rl.CloseWindow
WindowShouldClose          :: rl.WindowShouldClose
SetTargetFPS               :: rl.SetTargetFPS
GetScreenWidth             :: rl.GetScreenWidth
GetScreenHeight            :: rl.GetScreenHeight
GetFrameTime               :: rl.GetFrameTime
GetTime                    :: rl.GetTime
GetMousePosition           :: rl.GetMousePosition
GetMouseDelta              :: rl.GetMouseDelta
GetMouseWheelMove          :: rl.GetMouseWheelMove
IsMouseButtonPressed       :: rl.IsMouseButtonPressed
IsMouseButtonDown          :: rl.IsMouseButtonDown
IsKeyPressed               :: rl.IsKeyPressed
IsKeyDown                  :: rl.IsKeyDown
GetRandomValue             :: rl.GetRandomValue

BeginDrawing               :: rl.BeginDrawing
EndDrawing                 :: rl.EndDrawing
EndMode3D                  :: rl.EndMode3D
DrawGrid                   :: rl.DrawGrid
MeasureText                :: rl.MeasureText
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

BeginMode3D :: proc(camera: Camera3D) { rl.BeginMode3D(to_raylib_camera(camera)) }

to_raylib_color :: proc(color: Color) -> rl.Color { return transmute(rl.Color)color }

ClearBackground :: proc(color: Color) { rl.ClearBackground(to_raylib_color(color)) }
DrawLine3D :: proc(start, end: Vector3, color: Color) { rl.DrawLine3D(start, end, to_raylib_color(color)) }
DrawSphere :: proc(center: Vector3, radius: f32, color: Color) { rl.DrawSphere(center, radius, to_raylib_color(color)) }
DrawSphereEx :: proc(center: Vector3, radius: f32, rings, slices: i32, color: Color) {
	rl.DrawSphereEx(center, radius, rings, slices, to_raylib_color(color))
}
DrawCylinderEx :: proc(start, end: Vector3, start_radius, end_radius: f32, sides: i32, color: Color) {
	rl.DrawCylinderEx(start, end, start_radius, end_radius, sides, to_raylib_color(color))
}
DrawText :: proc(text: cstring, x, y, size: i32, color: Color) {
	rl.DrawText(text, x, y, size, to_raylib_color(color))
}

GetScreenToWorldRay :: proc(position: Vector2, camera: Camera3D) -> Ray {
	r := rl.GetScreenToWorldRay(position, to_raylib_camera(camera))
	return {position = r.position, direction = r.direction}
}
