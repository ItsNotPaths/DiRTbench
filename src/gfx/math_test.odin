package gfx

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
