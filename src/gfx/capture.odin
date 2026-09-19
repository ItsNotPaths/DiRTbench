package gfx

// A frame rendered into a texture instead of into a window.
//
// Two reasons it cannot simply read the window back. A swapchain texture is
// write-only, so nothing can copy out of it; and a thumbnail's size must not
// depend on how big the user happens to have dragged the window.
//
// A capture is a whole frame of its own, taken between window frames. The scene
// batch in render.odin is process-wide, so a capture started part way through a
// window's frame would draw that window's geometry into the thumbnail and lose
// its own.

import sdl "vendor:sdl3"

// One reusable capture surface. Its colour texture carries the same format the
// pipelines were built against, so the scene pass needs no second pipeline set.
Capture :: struct {
	color: ^sdl.GPUTexture,
	depth: ^sdl.GPUTexture,
	xfer:  ^sdl.GPUTransferBuffer,
	w, h:  i32,
	cmd:   ^sdl.GPUCommandBuffer,
	clear: sdl.FColor,
}

// The capture the scene pass is drawing into, or nil for the active window.
active_capture: ^Capture

CaptureOpen :: proc(cap: ^Capture, w, h: i32) -> bool {
	if gpu_device == nil || pipelines[.Tri_Fill] == nil || w <= 0 || h <= 0 {
		return false
	}
	CaptureClose(cap)
	cap^ = {w = w, h = h}
	cap.color = sdl.CreateGPUTexture(
		gpu_device,
		{type = .D2, format = gpu_format, usage = {.COLOR_TARGET}, width = u32(w), height = u32(h), layer_count_or_depth = 1, num_levels = 1, sample_count = ._1},
	)
	cap.depth = sdl.CreateGPUTexture(
		gpu_device,
		{type = .D2, format = .D32_FLOAT, usage = {.DEPTH_STENCIL_TARGET}, width = u32(w), height = u32(h), layer_count_or_depth = 1, num_levels = 1, sample_count = ._1},
	)
	cap.xfer = sdl.CreateGPUTransferBuffer(gpu_device, {usage = .DOWNLOAD, size = u32(w * h * 4)})
	if cap.color == nil || cap.depth == nil || cap.xfer == nil {
		CaptureClose(cap)
		return false
	}
	return true
}

CaptureClose :: proc(cap: ^Capture) {
	if gpu_device != nil {
		if cap.color != nil {
			sdl.ReleaseGPUTexture(gpu_device, cap.color)
		}
		if cap.depth != nil {
			sdl.ReleaseGPUTexture(gpu_device, cap.depth)
		}
		if cap.xfer != nil {
			sdl.ReleaseGPUTransferBuffer(gpu_device, cap.xfer)
		}
	}
	cap^ = {}
}

// Point the scene pass at `cap`. Between this and CaptureEnd, ClearBackground,
// BeginMode3D and EndMode3D all address the capture and the window is untouched.
CaptureBegin :: proc(cap: ^Capture) -> bool {
	if gpu_device == nil || cap.color == nil || active_capture != nil {
		return false
	}
	cap.cmd = sdl.AcquireGPUCommandBuffer(gpu_device)
	if cap.cmd == nil {
		return false
	}
	active_capture = cap
	return true
}

// Submit the capture's work, wait for it, and copy the pixels out. `pixels`
// takes w*h*4 bytes in the swapchain's own channel order; CaptureToRGB is what
// turns that into something an encoder wants.
CaptureEnd :: proc(cap: ^Capture, pixels: []u8) -> bool {
	if active_capture != cap {
		return false
	}
	defer active_capture = nil
	defer cap.cmd = nil
	if cap.cmd == nil || len(pixels) < int(cap.w * cap.h * 4) {
		return false
	}
	pass := sdl.BeginGPUCopyPass(cap.cmd)
	sdl.DownloadFromGPUTexture(
		pass,
		{texture = cap.color, w = u32(cap.w), h = u32(cap.h), d = 1},
		{transfer_buffer = cap.xfer, offset = 0, pixels_per_row = u32(cap.w), rows_per_layer = u32(cap.h)},
	)
	sdl.EndGPUCopyPass(pass)

	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cap.cmd)
	if fence == nil {
		return false
	}
	ok := sdl.WaitForGPUFences(gpu_device, true, &fence, 1)
	sdl.ReleaseGPUFence(gpu_device, fence)
	if !ok {
		return false
	}
	src := sdl.MapGPUTransferBuffer(gpu_device, cap.xfer, false)
	if src == nil {
		return false
	}
	copy(pixels, ([^]u8)(src)[:cap.w * cap.h * 4])
	sdl.UnmapGPUTransferBuffer(gpu_device, cap.xfer)
	return true
}

// The downloaded pixels as three bytes per pixel in R,G,B order, which is what
// every encoder here wants and what the swapchain, being B,G,R,A on every
// backend we run on, is not.
CaptureToRGB :: proc(cap: ^Capture, src: []u8, dst: []u8) {
	n := int(cap.w * cap.h)
	if len(src) < n * 4 || len(dst) < n * 3 {
		return
	}
	swap := gpu_format == .B8G8R8A8_UNORM || gpu_format == .B8G8R8A8_UNORM_SRGB
	for i in 0 ..< n {
		r, g, b := src[i * 4 + 0], src[i * 4 + 1], src[i * 4 + 2]
		if swap {
			r, b = b, r
		}
		dst[i * 3 + 0] = r
		dst[i * 3 + 1] = g
		dst[i * 3 + 2] = b
	}
}
