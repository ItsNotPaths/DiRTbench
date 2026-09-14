package geo

// A small deterministic PRNG, shared by anything that has to produce the same
// result from the same seed every run.
//
// xorshift64, written out here rather than taken from core:math/rand, so that a
// given seed pins a given stage for good and cannot drift when the standard
// library changes its generator. Two things depend on that: a generated stage
// (generate.odin) and a vegetation scatter (vegetation.odin) are both part of a
// saved document, reproduced from a seed rather than stored.
//
// Not thread-safe and not meant to be: each caller holds its own.

import "core:c"

Rng :: struct {
	s: u64,
}

rng_init :: proc(seed: c.int) -> Rng {
	s := u64(u32(seed)) * 2685821657736338717 + 1
	if s == 0 {
		s = 0x9E3779B97F4A7C15
	}
	return Rng{s = s}
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return r.s
}

// uniform in [0,1)
rng_unit :: proc(r: ^Rng) -> f32 {
	return f32(rng_next(r) >> 40) / f32(1 << 24)
}

rng_range :: proc(r: ^Rng, lo, hi: f32) -> f32 {
	return lo + (hi - lo) * rng_unit(r)
}
