package gfx

import "core:math"
import "core:math/linalg"

Vector2    :: [2]f32
Vector3    :: [3]f32
Quaternion :: quaternion128
Matrix     :: #row_major matrix[4, 4]f32
Color      :: distinct [4]u8

Transform :: struct {
	translation: Vector3,
	rotation:    Quaternion,
	scale:       Vector3,
}

CameraProjection :: enum i32 {
	PERSPECTIVE,
	ORTHOGRAPHIC,
}

Camera3D :: struct {
	position:   Vector3,
	target:     Vector3,
	up:         Vector3,
	fovy:       f32,
	projection: CameraProjection,
}

Ray :: struct {
	position:  Vector3,
	direction: Vector3,
}

RayCollision :: struct {
	hit:      bool,
	distance: f32,
	point:    Vector3,
	normal:   Vector3,
}

DEG2RAD :: math.PI / 180.0

Vector3Normalize :: proc(v: Vector3) -> Vector3 { return linalg.normalize0(v) }
Vector3Length :: proc(v: Vector3) -> f32 { return linalg.length(v) }
Vector3CrossProduct :: proc(a, b: Vector3) -> Vector3 { return linalg.cross(a, b) }
Vector3Distance :: proc(a, b: Vector3) -> f32 { return linalg.distance(a, b) }
Vector3DotProduct :: proc(a, b: Vector3) -> f32 { return linalg.dot(a, b) }
Vector3RotateByQuaternion :: proc(v: Vector3, q: Quaternion) -> Vector3 { return linalg.mul(q, v) }

Vector3RotateByAxisAngle :: proc(v, axis: Vector3, angle: f32) -> Vector3 {
	normalized_axis := linalg.normalize0(axis)
	half := angle * 0.5
	w := normalized_axis * math.sin(half)
	return v + 2 * math.cos(half) * linalg.cross(w, v) + 2 * linalg.cross(w, linalg.cross(w, v))
}

QuaternionSlerp :: proc(a, b: Quaternion, amount: f32) -> Quaternion {
	return linalg.quaternion_slerp(a, b, amount)
}
QuaternionNormalize :: proc(q: Quaternion) -> Quaternion { return linalg.normalize0(q) }
QuaternionFromMatrix :: proc(m: Matrix) -> Quaternion { return linalg.quaternion_from_matrix4(linalg.Matrix4f32(m)) }
QuaternionToMatrix :: proc(q: Quaternion) -> Matrix { return auto_cast linalg.matrix4_from_quaternion(q) }
QuaternionFromAxisAngle :: proc(axis: Vector3, angle: f32) -> Quaternion {
	return linalg.quaternion_angle_axis(angle, axis)
}

MatrixTranslate :: proc(x, y, z: f32) -> Matrix { return auto_cast linalg.matrix4_translate(Vector3{x, y, z}) }
MatrixTranspose :: proc(m: Matrix) -> Matrix { return linalg.transpose(m) }
MatrixPerspective :: proc(fovy, aspect, near, far: f32) -> Matrix {
	return auto_cast linalg.matrix4_perspective(fovy, aspect, near, far)
}
MatrixToFloatV :: proc(m: Matrix) -> [16]f32 { return transmute([16]f32)linalg.transpose(m) }
GetCameraMatrix :: proc(camera: Camera3D) -> Matrix {
	return auto_cast linalg.matrix4_look_at(camera.position, camera.target, camera.up)
}

normalized_ray :: proc(ray: Ray) -> (Ray, bool) {
	length := linalg.length(ray.direction)
	if length <= 1e-7 { return {}, false }
	return {position = ray.position, direction = ray.direction / length}, true
}

GetRayCollisionSphere :: proc(ray: Ray, center: Vector3, radius: f32) -> RayCollision {
	ray, valid := normalized_ray(ray)
	if !valid { return {} }
	to_center := center - ray.position
	projection := linalg.dot(to_center, ray.direction)
	center_distance_sq := linalg.dot(to_center, to_center) - projection * projection
	radius_sq := radius * radius
	if center_distance_sq > radius_sq { return {} }

	half_chord := math.sqrt(max(0, radius_sq - center_distance_sq))
	distance := projection - half_chord
	if distance < 0 { distance = projection + half_chord }
	if distance < 0 { return {} }
	point := ray.position + ray.direction * distance
	return {hit = true, distance = distance, point = point, normal = linalg.normalize0(point - center)}
}

ray_triangle :: proc(ray: Ray, a, b, c: Vector3) -> RayCollision {
	edge1 := b - a
	edge2 := c - a
	p := linalg.cross(ray.direction, edge2)
	det := linalg.dot(edge1, p)
	if abs(det) < 1e-7 { return {} }
	inv_det := 1 / det
	t := ray.position - a
	u := linalg.dot(t, p) * inv_det
	if u < 0 || u > 1 { return {} }
	q := linalg.cross(t, edge1)
	v := linalg.dot(ray.direction, q) * inv_det
	if v < 0 || u + v > 1 { return {} }
	distance := linalg.dot(edge2, q) * inv_det
	if distance < 0 { return {} }
	return {
		hit = true,
		distance = distance,
		point = ray.position + ray.direction * distance,
		normal = linalg.normalize0(linalg.cross(edge1, edge2)),
	}
}

GetRayCollisionQuad :: proc(ray: Ray, a, b, c, d: Vector3) -> RayCollision {
	ray, valid := normalized_ray(ray)
	if !valid { return {} }
	first := ray_triangle(ray, a, b, c)
	second := ray_triangle(ray, a, c, d)
	if !first.hit { return second }
	if !second.hit || first.distance <= second.distance { return first }
	return second
}
