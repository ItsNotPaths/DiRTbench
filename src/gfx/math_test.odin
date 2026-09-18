package gfx

import "core:math"
import "core:testing"

@(test)
ray_sphere_uses_nearest_forward_hit :: proc(t: ^testing.T) {
	hit := GetRayCollisionSphere({position = {0, 0, -5}, direction = {0, 0, 1}}, {0, 0, 0}, 1)
	testing.expect(t, hit.hit)
	testing.expect_value(t, hit.distance, f32(4))
	testing.expect_value(t, hit.point, Vector3{0, 0, -1})

	inside := GetRayCollisionSphere({position = {0, 0, 0}, direction = {0, 0, 1}}, {0, 0, 0}, 1)
	testing.expect(t, inside.hit)
	testing.expect_value(t, inside.distance, f32(1))

	non_unit := GetRayCollisionSphere({position = {0, 0, -5}, direction = {0, 0, 2}}, {0, 0, 0}, 1)
	testing.expect_value(t, non_unit.distance, f32(4))

	behind := GetRayCollisionSphere({position = {0, 0, 5}, direction = {0, 0, 1}}, {0, 0, 0}, 1)
	testing.expect(t, !behind.hit)
	testing.expect(t, !GetRayCollisionSphere({}, {0, 0, 0}, 1).hit)
}

@(test)
ray_quad_covers_both_triangles :: proc(t: ^testing.T) {
	a, b, c, d := Vector3{-1, -1, 0}, Vector3{1, -1, 0}, Vector3{1, 1, 0}, Vector3{-1, 1, 0}
	first := GetRayCollisionQuad({position = {0.75, -0.75, 1}, direction = {0, 0, -2}}, a, b, c, d)
	second := GetRayCollisionQuad({position = {-0.75, 0.75, 1}, direction = {0, 0, -1}}, a, b, c, d)
	testing.expect(t, first.hit)
	testing.expect(t, second.hit)
	testing.expect_value(t, first.distance, f32(1))
	testing.expect_value(t, second.distance, f32(1))

	miss := GetRayCollisionQuad({position = {2, 0, 1}, direction = {0, 0, -1}}, a, b, c, d)
	testing.expect(t, !miss.hit)
	testing.expect(t, !GetRayCollisionQuad({}, a, b, c, d).hit)
}

@(test)
perspective_maps_vulkan_ndc :: proc(t: ^testing.T) {
	near, far := f32(0.1), f32(10000)
	m := MatrixPerspective(math.PI / 2, 1, near, far)
	project :: proc(m: Matrix, p: Vector3) -> [4]f32 {
		return m * [4]f32{p.x, p.y, p.z, 1}
	}
	ndc :: proc(c: [4]f32) -> Vector3 {
		return {c[0] / c[3], c[1] / c[3], c[2] / c[3]}
	}

	// w is -z: positive in front of the camera, negative behind it. A constant
	// w here would mean no perspective and a collapsed frustum.
	testing.expect_value(t, project(m, {0, 0, -50})[3], f32(50))
	testing.expect_value(t, project(m, {0, 0, 50})[3], f32(-50))

	// Depth runs from 0 at the near plane to 1 at the far plane.
	testing.expect(t, abs(ndc(project(m, {0, 0, -near})).z) < 1e-6)
	testing.expect(t, abs(ndc(project(m, {0, 0, -far})).z - 1) < 1e-4)
	mid := ndc(project(m, {0, 0, -50}))
	testing.expect(t, mid.z > 0 && mid.z < 1)

	// Centred stays centred; right is +x and up is +y (SDL_GPU presents
	// NDC +1 at the top, like OpenGL).
	centre := ndc(project(m, {0, 0, -10}))
	testing.expect(t, abs(centre.x) < 1e-6 && abs(centre.y) < 1e-6)
	testing.expect(t, abs(ndc(project(m, {1, 0, -1})).x - 1) < 1e-5)
	testing.expect(t, abs(ndc(project(m, {0, 1, -1})).y - 1) < 1e-5)
}

@(test)
ray_box_reports_the_face_it_enters :: proc(t: ^testing.T) {
	lo, hi := Vector3{-1, 0, -1}, Vector3{1, 4, 1}

	hit := GetRayCollisionBox({position = {0, 2, -10}, direction = {0, 0, 1}}, lo, hi)
	testing.expect(t, hit.hit)
	testing.expect_value(t, hit.distance, f32(9))
	testing.expect_value(t, hit.normal, Vector3{0, 0, -1})

	// Distance is in metres whatever the direction is scaled to, like the sphere.
	non_unit := GetRayCollisionBox({position = {0, 2, -10}, direction = {0, 0, 3}}, lo, hi)
	testing.expect_value(t, non_unit.distance, f32(9))

	over := GetRayCollisionBox({position = {0, 9, -10}, direction = {0, 0, 1}}, lo, hi)
	testing.expect(t, !over.hit)

	behind := GetRayCollisionBox({position = {0, 2, -10}, direction = {0, 0, -1}}, lo, hi)
	testing.expect(t, !behind.hit)

	// Started inside: the near hit is where the ray already is.
	inside := GetRayCollisionBox({position = {0, 2, 0}, direction = {1, 0, 0}}, lo, hi)
	testing.expect(t, inside.hit)
	testing.expect_value(t, inside.distance, f32(0))

	testing.expect(t, !GetRayCollisionBox({}, lo, hi).hit)
}
