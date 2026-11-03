package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:sys/windows"
import vk "vendor:vulkan"
import "vendor:stb/easy_font"

WIDTH :: 1280
HEIGHT :: 720
RENDER_SCALE :: 0.7
MAX_FRAMES :: 3

Vertex :: struct {
	pos:   [3]f32,
	color: [3]f32,
	uv:    [2]f32,
	layer: f32,
}

UBO :: struct #align(16) {
	view_proj: linalg.Matrix4f32,
	cam_pos:   [4]f32,
	screen:    [4]f32,
}

Buffer :: struct {
	handle: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
	mapped: rawptr,
}

Frame :: struct {
	cmd:        vk.CommandBuffer,
	ubo:        Buffer,
	hud:        Buffer,
	outline:    Buffer,
	fence:      vk.Fence,
	sem_image:  vk.Semaphore,
	sem_render: vk.Semaphore,
	hud_shadow:    u32,
	hud_text:      u32,
	crosshair_draw: u32,
	outline_draw:  u32,
}

App :: struct {
	hwnd:      windows.HWND,
	hinstance: windows.HINSTANCE,

	instance:     vk.Instance,
	surface:      vk.SurfaceKHR,
	physical:     vk.PhysicalDevice,
	device:       vk.Device,
	queue:        vk.Queue,
	queue_family: u32,
	mem_props:    vk.PhysicalDeviceMemoryProperties,
	gpu_name:     string,

	swapchain:     vk.SwapchainKHR,
	sw_format:     vk.Format,
	extent:        vk.Extent2D,
	rt_extent:     vk.Extent2D,
	images:        []vk.Image,
	views:         []vk.ImageView,
	fbo:           vk.Framebuffer,
	hud_fbos:      []vk.Framebuffer,
	rt_image:      vk.Image,
	rt_memory:     vk.DeviceMemory,
	rt_view:       vk.ImageView,
	block_image:   vk.Image,
	block_memory:  vk.DeviceMemory,
	block_view:    vk.ImageView,
	block_sampler: vk.Sampler,
	swapchain_ok:  bool,
	depth_image:   vk.Image,
	depth_memory:  vk.DeviceMemory,
	depth_view:    vk.ImageView,

	render_pass: vk.RenderPass,
	hud_pass:    vk.RenderPass,
	desc_layout: vk.DescriptorSetLayout,
	desc_pool:   vk.DescriptorPool,
	desc_sets:   []vk.DescriptorSet,
	pipe_layout:    vk.PipelineLayout,
	pipe_voxel:     vk.Pipeline,
	pipe_hud:       vk.Pipeline,
	pipe_composite: vk.Pipeline,
	pipe_outline:   vk.Pipeline,
	pipe_crosshair: vk.Pipeline,
	scene_sampler:  vk.Sampler,
	cmd_pool:       vk.CommandPool,

	frames:      []Frame,
	frame_index: int,

	vbuf:   Buffer,
	vcount: u32,

	hud_cap:     int,
}

Player :: struct {
	pos:       [3]f32,
	vel:       [3]f32,
	yaw:       f32,
	pitch:     f32,
	on_ground: bool,
}

CHUNK :: 16
WORLD_CHUNKS :: 5
WORLD_SIZE :: CHUNK * WORLD_CHUNKS
HUD_QUADS :: 4096

OUTLINE_MAX_VERTS :: 72
OUTLINE_REACH :: 4.5
OUTLINE_INFLATE :: 0.002
OUTLINE_PX :: 2.0
FOV_Y :: 72

TEX_SIZE :: 16
TEX_MIPS :: 5
TEX_LAYERS :: 4
TEX_GRASS_TOP :: 0
TEX_GRASS_SIDE :: 1
TEX_DIRT :: 2
TEX_STONE :: 3

bench_mode: bool
bench_seconds: f64 = 8
bench_elapsed: f64
bench_dts: [dynamic]f32
bench_acquire_ns: i64
bench_present_ns: i64
bench_fence_ns: i64
bench_submit_ns: i64
bench_calls: u64

EYE_HEIGHT :: 1.62
PLAYER_HALF :: 0.3
PLAYER_HEIGHT :: 1.8
GRAVITY :: 28.0
JUMP_SPEED :: 8.2
WALK_SPEED :: 4.7
SPRINT_SPEED :: 7.6

app: App
player: Player
spawn_point: [3]f32
should_quit: bool
cursor_locked: bool
lock_requested: bool
mouse_ready: bool
hud_quads: []easy_font.Quad

vk_check :: proc(res: vk.Result, what: string) {
	if res != .SUCCESS {
		fmt.eprintln("vulkan:", what, "failed:", res)
		os.exit(1)
	}
}

window_proc :: proc "system" (hwnd: windows.HWND, msg: windows.UINT, wparam: windows.WPARAM, lparam: windows.LPARAM) -> windows.LRESULT {
	switch msg {
	case windows.WM_CLOSE:
		should_quit = true
		return 0
	case windows.WM_DESTROY:
		should_quit = true
		windows.PostQuitMessage(0)
		return 0
	case windows.WM_LBUTTONDOWN:
		lock_requested = true
		return 0
	case windows.WM_SETCURSOR:
		if cursor_locked {
			return 1
		}
	}
	return windows.DefWindowProcW(hwnd, msg, wparam, lparam)
}

create_window :: proc() -> bool {
	app.hinstance = windows.HINSTANCE(windows.GetModuleHandleW(nil))
	class_name := cstring16(windows.L("VulkeWindow"))
	icon := windows.LoadIconW(app.hinstance, cast(windows.LPCWSTR)windows.MAKEINTRESOURCEW(1))
	wc := windows.WNDCLASSW{
		style         = windows.CS_HREDRAW | windows.CS_VREDRAW | windows.CS_OWNDC,
		lpfnWndProc   = window_proc,
		hInstance     = app.hinstance,
		hIcon         = icon,
		hCursor       = windows.LoadCursorA(nil, windows.IDC_ARROW),
		lpszClassName = class_name,
	}
	if windows.RegisterClassW(&wc) == 0 {
		fmt.eprintln("RegisterClassW failed")
		return false
	}
	rect := windows.RECT{0, 0, WIDTH, HEIGHT}
	windows.AdjustWindowRect(&rect, windows.WS_OVERLAPPEDWINDOW, false)
	app.hwnd = windows.CreateWindowExW(
		0,
		class_name,
		windows.L("Vulke"),
		windows.WS_OVERLAPPEDWINDOW | windows.WS_VISIBLE,
		120, 80,
		rect.right - rect.left,
		rect.bottom - rect.top,
		nil, nil, app.hinstance, nil,
	)
	if app.hwnd == nil {
		fmt.eprintln("CreateWindowExW failed")
		return false
	}
	windows.ShowWindow(app.hwnd, windows.SW_SHOWMAXIMIZED)
	return true
}

load_vulkan :: proc() -> bool {
	dll := windows.LoadLibraryW(windows.L("vulkan-1.dll"))
	if dll == nil {
		fmt.eprintln("could not load vulkan-1.dll")
		return false
	}
	gipa := windows.GetProcAddress(dll, "vkGetInstanceProcAddr")
	if gipa == nil {
		fmt.eprintln("vulkan-1.dll has no vkGetInstanceProcAddr")
		return false
	}
	vk.load_proc_addresses_global(gipa)
	return true
}

create_instance :: proc() {
	app_info := vk.ApplicationInfo{
		sType              = .APPLICATION_INFO,
		pApplicationName   = "Vulke",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "vulke",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_1,
	}
	exts := []cstring{"VK_KHR_surface", "VK_KHR_win32_surface"}
	ci := vk.InstanceCreateInfo{
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}
	vk_check(vk.CreateInstance(&ci, nil, &app.instance), "CreateInstance")
	vk.load_proc_addresses_instance(app.instance)

	sci := vk.Win32SurfaceCreateInfoKHR{
		sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
		hinstance = app.hinstance,
		hwnd      = app.hwnd,
	}
	vk_check(vk.CreateWin32SurfaceKHR(app.instance, &sci, nil, &app.surface), "CreateWin32SurfaceKHR")
}

pick_device :: proc() {
	count: u32
	vk_check(vk.EnumeratePhysicalDevices(app.instance, &count, nil), "EnumeratePhysicalDevices")

	count = 32
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk_check(vk.EnumeratePhysicalDevices(app.instance, &count, raw_data(devices)), "EnumeratePhysicalDevices")

	found := false
	for dev in devices[:count] {
		qcount: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(dev, &qcount, nil)
		if qcount == 0 {
			continue
		}
		families := make([]vk.QueueFamilyProperties, qcount, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(dev, &qcount, raw_data(families))

		for family, i in families {
			if !(.GRAPHICS in family.queueFlags) || family.queueCount == 0 {
				continue
			}
			present: b32
			vk_check(vk.GetPhysicalDeviceSurfaceSupportKHR(dev, u32(i), app.surface, &present), "GetPhysicalDeviceSurfaceSupportKHR")
			if present {
				app.physical = dev
				app.queue_family = u32(i)
				found = true
				break
			}
		}
		if found {
			break
		}
	}
	if !found {
		fmt.eprintln("no graphics device with presentation support")
		os.exit(1)
	}

	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(app.physical, &props)
	n := 0
	for b in props.deviceName {
		if b == 0 {
			break
		}
		n += 1
	}
	app.gpu_name = strings.clone(string(props.deviceName[:n]))

	vk.GetPhysicalDeviceMemoryProperties(app.physical, &app.mem_props)
}

create_device :: proc() {
	priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo{
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = app.queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	exts := []cstring{"VK_KHR_swapchain"}
	ci := vk.DeviceCreateInfo{
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}
	vk_check(vk.CreateDevice(app.physical, &ci, nil, &app.device), "CreateDevice")
	vk.load_proc_addresses_device(app.device)
	vk.GetDeviceQueue(app.device, app.queue_family, 0, &app.queue)
}

find_memory_type :: proc(bits: u32, want: vk.MemoryPropertyFlags) -> u32 {
	for i in 0 ..< app.mem_props.memoryTypeCount {
		t := app.mem_props.memoryTypes[i]
		if (bits & (u32(1) << i)) != 0 && (t.propertyFlags & want) == want {
			return i
		}
	}
	fmt.eprintln("no suitable memory type")
	os.exit(1)
}

create_buffer :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags, props: vk.MemoryPropertyFlags) -> Buffer {
	b := Buffer{size = size}
	ci := vk.BufferCreateInfo{
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	vk_check(vk.CreateBuffer(app.device, &ci, nil, &b.handle), "CreateBuffer")

	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(app.device, b.handle, &req)
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(req.memoryTypeBits, props),
	}
	vk_check(vk.AllocateMemory(app.device, &alloc, nil, &b.memory), "AllocateMemory")
	vk_check(vk.BindBufferMemory(app.device, b.handle, b.memory, 0), "BindBufferMemory")
	if .HOST_VISIBLE in props {
		vk_check(vk.MapMemory(app.device, b.memory, 0, size, {}, &b.mapped), "MapMemory")
	}
	return b
}

render_extent :: proc(client_w, client_h: u32) -> vk.Extent2D {
	return {
		max(u32(1), u32(f32(client_w) * RENDER_SCALE)),
		max(u32(1), u32(f32(client_h) * RENDER_SCALE)),
	}
}

create_swapchain :: proc() {
	caps: vk.SurfaceCapabilitiesKHR
	vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(app.physical, app.surface, &caps), "surface caps")

	fcount: u32
	vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(app.physical, app.surface, &fcount, nil), "surface formats")
	formats := make([]vk.SurfaceFormatKHR, fcount, context.temp_allocator)
	vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(app.physical, app.surface, &fcount, raw_data(formats)), "surface formats")

	chosen := formats[0]
	for f in formats {
		if f.format == .B8G8R8A8_UNORM && f.colorSpace == .SRGB_NONLINEAR {
			chosen = f
			break
		}
	}
	app.sw_format = chosen.format

	pcount: u32
	vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(app.physical, app.surface, &pcount, nil), "present modes")
	modes := make([]vk.PresentModeKHR, pcount, context.temp_allocator)
	vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(app.physical, app.surface, &pcount, raw_data(modes)), "present modes")

	mode := vk.PresentModeKHR.FIFO
	for m in modes {
		if m == .MAILBOX {
			mode = .MAILBOX
			break
		}
	}
	if mode != .MAILBOX {
		for m in modes {
			if m == .IMMEDIATE {
				mode = .IMMEDIATE
				break
			}
		}
	}

	base := caps.currentExtent
	if base.width == max(u32) {
		base = {u32(WIDTH), u32(HEIGHT)}
	}
	extent := base
	app.extent = extent
	app.rt_extent = render_extent(extent.width, extent.height)

	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 && image_count > caps.maxImageCount {
		image_count = caps.maxImageCount
	}

	ci := vk.SwapchainCreateInfoKHR{
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = app.surface,
		minImageCount    = image_count,
		imageFormat      = app.sw_format,
		imageColorSpace  = chosen.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = mode,
		clipped          = true,
	}
	vk_check(vk.CreateSwapchainKHR(app.device, &ci, nil, &app.swapchain), "CreateSwapchainKHR")

	n: u32
	vk_check(vk.GetSwapchainImagesKHR(app.device, app.swapchain, &n, nil), "GetSwapchainImagesKHR")
	app.images = make([]vk.Image, n)
	vk_check(vk.GetSwapchainImagesKHR(app.device, app.swapchain, &n, raw_data(app.images)), "GetSwapchainImagesKHR")

	app.views = make([]vk.ImageView, n)
	for image, i in app.images {
		app.views[i] = create_image_view(image, app.sw_format, {.COLOR})
	}

	create_depth(app.rt_extent)

	app.swapchain_ok = true
	fmt.println("swapchain:", extent.width, "x", extent.height, "-", app.gpu_name)
}

create_framebuffers :: proc() {
	if app.fbo != 0 {
		vk.DestroyFramebuffer(app.device, app.fbo, nil)
		app.fbo = 0
	}
	if app.rt_image != 0 {
		vk.DestroyImageView(app.device, app.rt_view, nil)
		vk.DestroyImage(app.device, app.rt_image, nil)
		vk.FreeMemory(app.device, app.rt_memory, nil)
		app.rt_image = 0
	}

	ci := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = app.sw_format,
		extent        = {app.rt_extent.width, app.rt_extent.height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.COLOR_ATTACHMENT, .SAMPLED},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(app.device, &ci, nil, &app.rt_image), "CreateImage(render target)")

	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(app.device, app.rt_image, &req)
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_check(vk.AllocateMemory(app.device, &alloc, nil, &app.rt_memory), "AllocateMemory(render target)")
	vk_check(vk.BindImageMemory(app.device, app.rt_image, app.rt_memory, 0), "BindImageMemory")
	app.rt_view = create_image_view(app.rt_image, app.sw_format, {.COLOR})
	if len(app.desc_sets) > 0 {
		update_scene_descriptors()
	}

	atts := [2]vk.ImageView{app.rt_view, app.depth_view}
	fb := vk.FramebufferCreateInfo{
		sType           = .FRAMEBUFFER_CREATE_INFO,
		renderPass      = app.render_pass,
		attachmentCount = 2,
		pAttachments    = &atts[0],
		width           = app.rt_extent.width,
		height          = app.rt_extent.height,
		layers          = 1,
	}
	vk_check(vk.CreateFramebuffer(app.device, &fb, nil, &app.fbo), "CreateFramebuffer")

	for old in app.hud_fbos {
		vk.DestroyFramebuffer(app.device, old, nil)
	}
	delete(app.hud_fbos)
	app.hud_fbos = make([]vk.Framebuffer, len(app.views))
	for i in 0 ..< len(app.views) {
		atts := [1]vk.ImageView{app.views[i]}
		hud_fb := vk.FramebufferCreateInfo{
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = app.hud_pass,
			attachmentCount = 1,
			pAttachments    = &atts[0],
			width           = app.extent.width,
			height          = app.extent.height,
			layers          = 1,
		}
		vk_check(vk.CreateFramebuffer(app.device, &hud_fb, nil, &app.hud_fbos[i]), "CreateFramebuffer(hud)")
	}
}

create_image_view :: proc(image: vk.Image, format: vk.Format, aspect: vk.ImageAspectFlags, levels: u32 = 1, layers: u32 = 1) -> vk.ImageView {
	view: vk.ImageView
	ci := vk.ImageViewCreateInfo{
		sType    = .IMAGE_VIEW_CREATE_INFO,
		image    = image,
		viewType = .D2,
		format   = format,
		subresourceRange = {
			aspectMask     = aspect,
			baseMipLevel   = 0,
			levelCount     = levels,
			baseArrayLayer = 0,
			layerCount     = layers,
		},
	}
	vk_check(vk.CreateImageView(app.device, &ci, nil, &view), "CreateImageView")
	return view
}

create_depth :: proc(extent: vk.Extent2D) {
	ci := vk.ImageCreateInfo{
		sType       = .IMAGE_CREATE_INFO,
		imageType   = .D2,
		format      = .D32_SFLOAT,
		extent      = {extent.width, extent.height, 1},
		mipLevels   = 1,
		arrayLayers = 1,
		samples     = {._1},
		tiling      = .OPTIMAL,
		usage       = {.DEPTH_STENCIL_ATTACHMENT},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(app.device, &ci, nil, &app.depth_image), "CreateImage(depth)")

	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(app.device, app.depth_image, &req)
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_check(vk.AllocateMemory(app.device, &alloc, nil, &app.depth_memory), "AllocateMemory(depth)")
	vk_check(vk.BindImageMemory(app.device, app.depth_image, app.depth_memory, 0), "BindImageMemory")
	app.depth_view = create_image_view(app.depth_image, .D32_SFLOAT, {.DEPTH})
}

destroy_swapchain :: proc() {
	vk.DeviceWaitIdle(app.device)
	if !app.swapchain_ok {
		return
	}
	if app.fbo != 0 {
		vk.DestroyFramebuffer(app.device, app.fbo, nil)
		app.fbo = 0
	}
	if app.rt_image != 0 {
		vk.DestroyImageView(app.device, app.rt_view, nil)
		vk.DestroyImage(app.device, app.rt_image, nil)
		vk.FreeMemory(app.device, app.rt_memory, nil)
		app.rt_image = 0
	}
	for fb in app.hud_fbos {
		vk.DestroyFramebuffer(app.device, fb, nil)
	}
	delete(app.hud_fbos)
	app.hud_fbos = nil
	for view in app.views {
		vk.DestroyImageView(app.device, view, nil)
	}
	vk.DestroyImageView(app.device, app.depth_view, nil)
	vk.DestroyImage(app.device, app.depth_image, nil)
	vk.FreeMemory(app.device, app.depth_memory, nil)
	vk.DestroySwapchainKHR(app.device, app.swapchain, nil)

	delete(app.views)
	delete(app.images)
	app.views = nil
	app.images = nil
	app.swapchain_ok = false
}

create_render_pass :: proc() {
	color := vk.AttachmentDescription{
		format         = app.sw_format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .SHADER_READ_ONLY_OPTIMAL,
	}
	depth := vk.AttachmentDescription{
		format         = .D32_SFLOAT,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .DONT_CARE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	}
	attachments := [2]vk.AttachmentDescription{color, depth}

	refs := [2]vk.AttachmentReference{
		{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL},
		{attachment = 1, layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL},
	}
	subpass := vk.SubpassDescription{
		pipelineBindPoint       = .GRAPHICS,
		colorAttachmentCount    = 1,
		pColorAttachments       = &refs[0],
		pDepthStencilAttachment = &refs[1],
	}
	dependency := vk.SubpassDependency{
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
	}
	ci := vk.RenderPassCreateInfo{
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 2,
		pAttachments    = &attachments[0],
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}
	vk_check(vk.CreateRenderPass(app.device, &ci, nil, &app.render_pass), "CreateRenderPass")

	hud_color := vk.AttachmentDescription{
		format         = app.sw_format,
		samples        = {._1},
		loadOp         = .DONT_CARE,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}
	ref := vk.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
	hud_subpass := vk.SubpassDescription{
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &ref,
	}
	hud_dependency := vk.SubpassDependency{
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	hud_ci := vk.RenderPassCreateInfo{
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &hud_color,
		subpassCount    = 1,
		pSubpasses      = &hud_subpass,
		dependencyCount = 1,
		pDependencies   = &hud_dependency,
	}
	vk_check(vk.CreateRenderPass(app.device, &hud_ci, nil, &app.hud_pass), "CreateRenderPass(hud)")
}

create_descriptors :: proc() {
	bindings := [5]vk.DescriptorSetLayoutBinding{
		{binding = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX, .FRAGMENT}},
		{binding = 1, descriptorType = .SAMPLED_IMAGE, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		{binding = 2, descriptorType = .SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		{binding = 3, descriptorType = .SAMPLED_IMAGE, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		{binding = 4, descriptorType = .SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}
	layout_ci := vk.DescriptorSetLayoutCreateInfo{
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 5,
		pBindings    = &bindings[0],
	}
	vk_check(vk.CreateDescriptorSetLayout(app.device, &layout_ci, nil, &app.desc_layout), "CreateDescriptorSetLayout")

	pool_sizes := [3]vk.DescriptorPoolSize{
		{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES},
		{type = .SAMPLED_IMAGE, descriptorCount = 2 * MAX_FRAMES},
		{type = .SAMPLER, descriptorCount = 2 * MAX_FRAMES},
	}
	pool_ci := vk.DescriptorPoolCreateInfo{
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = MAX_FRAMES,
		poolSizeCount = 3,
		pPoolSizes    = &pool_sizes[0],
	}
	vk_check(vk.CreateDescriptorPool(app.device, &pool_ci, nil, &app.desc_pool), "CreateDescriptorPool")
}

update_scene_descriptors :: proc() {
	for i in 0 ..< MAX_FRAMES {
		img := vk.DescriptorImageInfo{
			imageView   = app.rt_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		smp := vk.DescriptorImageInfo{sampler = app.scene_sampler}
		block_img := vk.DescriptorImageInfo{
			imageView   = app.block_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		block_smp := vk.DescriptorImageInfo{sampler = app.block_sampler}
		writes := [4]vk.WriteDescriptorSet{
			{
				sType           = .WRITE_DESCRIPTOR_SET,
				dstSet          = app.desc_sets[i],
				dstBinding      = 1,
				descriptorCount = 1,
				descriptorType  = .SAMPLED_IMAGE,
				pImageInfo      = &img,
			},
			{
				sType           = .WRITE_DESCRIPTOR_SET,
				dstSet          = app.desc_sets[i],
				dstBinding      = 2,
				descriptorCount = 1,
				descriptorType  = .SAMPLER,
				pImageInfo      = &smp,
			},
			{
				sType           = .WRITE_DESCRIPTOR_SET,
				dstSet          = app.desc_sets[i],
				dstBinding      = 3,
				descriptorCount = 1,
				descriptorType  = .SAMPLED_IMAGE,
				pImageInfo      = &block_img,
			},
			{
				sType           = .WRITE_DESCRIPTOR_SET,
				dstSet          = app.desc_sets[i],
				dstBinding      = 4,
				descriptorCount = 1,
				descriptorType  = .SAMPLER,
				pImageInfo      = &block_smp,
			},
		}
		vk.UpdateDescriptorSets(app.device, 4, &writes[0], 0, nil)
	}
}

create_sampler :: proc() {
	ci := vk.SamplerCreateInfo{
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = 0,
	}
	vk_check(vk.CreateSampler(app.device, &ci, nil, &app.scene_sampler), "CreateSampler")
}

tex_hash :: proc(x, y, layer: int) -> u32 {
	h := u32(x) * 0x8da6b343 ~ u32(y) * 0xd8163841 ~ u32(layer) * 0xcb1ab31f
	h = (h ~ (h >> 13)) * 0x5bd1e995
	return h ~ (h >> 15)
}

set_texel :: proc(px: []u8, layer, x, y: int, r, g, b: i32) {
	i := ((layer * TEX_SIZE + y) * TEX_SIZE + x) * 4
	px[i + 0] = u8(clamp(r, 0, 255))
	px[i + 1] = u8(clamp(g, 0, 255))
	px[i + 2] = u8(clamp(b, 0, 255))
	px[i + 3] = 255
}

tex_cluster :: proc(x, y, seed: int) -> u32 {
	return tex_hash(x >> 1, y >> 1, seed)
}

grass_pixel :: proc(x, y, seed: int) -> (i32, i32, i32) {
	h := tex_cluster(x, y, seed) % 64
	p := tex_hash(x, y, seed + 7) % 32
	r, g, b: i32
	switch {
	case h < 10: r, g, b = 117, 166, 70
	case h < 20: r, g, b = 150, 197, 95
	case:        r, g, b = 133, 183, 82
	}
	n := i32(p % 5) - 2
	r += n; g += n; b += n / 2
	if tex_hash(x, y, seed + 11) % 21 == 0 {
		r -= 12; g -= 16; b -= 8
	}
	return r, g, b
}

dirt_pixel :: proc(x, y: int) -> (i32, i32, i32) {
	h := tex_cluster(x, y, 53) % 64
	p := tex_hash(x, y, 61) % 64
	r, g, b: i32
	switch {
	case h < 10: r, g, b = 112, 79, 54
	case h < 18: r, g, b = 122, 87, 60
	case h < 28: r, g, b = 154, 114, 82
	case:        r, g, b = 134, 96, 67
	}
	n := i32(p % 5) - 2
	r += n; g += n; b += n
	if tex_hash(x, y, 67) % 31 == 0 {
		r -= 16; g -= 13; b -= 10
	}
	return r, g, b
}

stone_pixel :: proc(x, y: int) -> (i32, i32, i32) {
	patch := tex_hash(x >> 2, y >> 2, 83) % 64
	base: i32
	switch {
	case patch < 14: base = 117
	case patch < 30: base = 139
	case:            base = 128
	}
	n := i32(tex_hash(x, y, 73) % 5) - 2
	if tex_hash(x, y, 79) % 23 == 0 {
		base -= 12
	}
	return base + n, base + n, base + n + 1
}

gen_grass_top :: proc(px: []u8) {
	for y in 0 ..< TEX_SIZE {
		for x in 0 ..< TEX_SIZE {
			r, g, b := grass_pixel(x, y, 13)
			set_texel(px, TEX_GRASS_TOP, x, y, r, g, b)
		}
	}
}

GRASS_FRINGE := [TEX_SIZE]int{3, 4, 3, 5, 4, 3, 4, 6, 4, 3, 5, 4, 3, 4, 5, 3}

gen_grass_side :: proc(px: []u8) {
	for x in 0 ..< TEX_SIZE {
		edge := GRASS_FRINGE[x]
		sprig := tex_hash(x, 9, 47) % 5 == 0
		for y in 0 ..< TEX_SIZE {
			if y < edge {
				r, g, b := grass_pixel(x, y, 13)
				r -= 4; g -= 4; b -= 2
				if y == edge - 1 { r -= 10; g -= 14; b -= 7 }
				set_texel(px, TEX_GRASS_SIDE, x, y, r, g, b)
			} else {
				r, g, b := dirt_pixel(x, y)
				if sprig && y == edge { r, g, b = 84, 134, 48 }
				set_texel(px, TEX_GRASS_SIDE, x, y, r, g, b)
			}
		}
	}
}

gen_dirt :: proc(px: []u8) {
	for y in 0 ..< TEX_SIZE {
		for x in 0 ..< TEX_SIZE {
			r, g, b := dirt_pixel(x, y)
			set_texel(px, TEX_DIRT, x, y, r, g, b)
		}
	}
}

gen_stone :: proc(px: []u8) {
	for y in 0 ..< TEX_SIZE {
		for x in 0 ..< TEX_SIZE {
			r, g, b := stone_pixel(x, y)
			set_texel(px, TEX_STONE, x, y, r, g, b)
		}
	}
}

gen_block_mips :: proc(base: []u8) -> []u8 {
	per_layer := 0
	for l in 0 ..< TEX_MIPS {
		s := TEX_SIZE >> uint(l)
		per_layer += s * s * 4
	}
	out := make([]u8, TEX_LAYERS * per_layer)
	for layer in 0 ..< TEX_LAYERS {
		dst := layer * per_layer
		src := layer * TEX_SIZE * TEX_SIZE * 4
		mem.copy(raw_data(out[dst:]), raw_data(base[src:]), TEX_SIZE * TEX_SIZE * 4)

		prev, prev_size := dst, TEX_SIZE
		cur := dst + TEX_SIZE * TEX_SIZE * 4
		for l in 1 ..< TEX_MIPS {
			size := prev_size / 2
			for y in 0 ..< size {
				for x in 0 ..< size {
					r, g, b, a: int
					for dy in 0 ..< 2 {
						for dx in 0 ..< 2 {
							sx := (x * 2 + dx) % prev_size
							sy := (y * 2 + dy) % prev_size
							i := prev + (sy * prev_size + sx) * 4
							r += int(out[i + 0]); g += int(out[i + 1])
							b += int(out[i + 2]); a += int(out[i + 3])
						}
					}
					o := cur + (y * size + x) * 4
					out[o + 0] = u8(r / 4); out[o + 1] = u8(g / 4)
					out[o + 2] = u8(b / 4); out[o + 3] = u8(a / 4)
				}
			}
			prev, prev_size = cur, size
			cur += size * size * 4
		}
	}
	return out
}

create_block_textures :: proc() {
	base := make([]u8, TEX_LAYERS * TEX_SIZE * TEX_SIZE * 4)
	defer delete(base)
	gen_grass_top(base)
	gen_grass_side(base)
	gen_dirt(base)
	gen_stone(base)
	pixels := gen_block_mips(base)
	defer delete(pixels)

	ci := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = .R8G8B8A8_UNORM,
		extent        = {TEX_SIZE, TEX_SIZE, 1},
		mipLevels     = TEX_MIPS,
		arrayLayers   = TEX_LAYERS,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.TRANSFER_DST, .SAMPLED},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(app.device, &ci, nil, &app.block_image), "CreateImage(block textures)")

	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(app.device, app.block_image, &req)
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_check(vk.AllocateMemory(app.device, &alloc, nil, &app.block_memory), "AllocateMemory(block textures)")
	vk_check(vk.BindImageMemory(app.device, app.block_image, app.block_memory, 0), "BindImageMemory(block textures)")

	staging := create_buffer(vk.DeviceSize(len(pixels)), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	defer {
		vk.DestroyBuffer(app.device, staging.handle, nil)
		vk.FreeMemory(app.device, staging.memory, nil)
	}
	mem.copy(staging.mapped, raw_data(pixels), len(pixels))

	pool_ci := vk.CommandPoolCreateInfo{
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.TRANSIENT},
		queueFamilyIndex = app.queue_family,
	}
	pool: vk.CommandPool
	vk_check(vk.CreateCommandPool(app.device, &pool_ci, nil, &pool), "CreateCommandPool(texture)")
	defer vk.DestroyCommandPool(app.device, pool, nil)
	cmd_alloc := vk.CommandBufferAllocateInfo{
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(app.device, &cmd_alloc, &cmd), "AllocateCommandBuffers(texture)")
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	vk_check(vk.BeginCommandBuffer(cmd, &begin), "BeginCommandBuffer(texture)")

	full_range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = TEX_MIPS, layerCount = TEX_LAYERS}
	to_dst := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		dstAccessMask       = {.TRANSFER_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = app.block_image,
		subresourceRange    = full_range,
	}
	vk.CmdPipelineBarrier(cmd, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &to_dst)

	copies := make([dynamic]vk.BufferImageCopy, 0, TEX_LAYERS * TEX_MIPS)
	defer delete(copies)
	offset: vk.DeviceSize
	for layer in 0 ..< TEX_LAYERS {
		for l in 0 ..< TEX_MIPS {
			s := TEX_SIZE >> uint(l)
			append(&copies, vk.BufferImageCopy{
				bufferOffset = offset,
				imageSubresource = {
					aspectMask     = {.COLOR},
					mipLevel       = u32(l),
					baseArrayLayer = u32(layer),
					layerCount     = 1,
				},
				imageExtent = {u32(s), u32(s), 1},
			})
			offset += vk.DeviceSize(s * s * 4)
		}
	}
	vk.CmdCopyBufferToImage(cmd, staging.handle, app.block_image, .TRANSFER_DST_OPTIMAL, u32(len(copies)), raw_data(copies[:]))

	to_read := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {.TRANSFER_WRITE},
		dstAccessMask       = {.SHADER_READ},
		oldLayout           = .TRANSFER_DST_OPTIMAL,
		newLayout           = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = app.block_image,
		subresourceRange    = full_range,
	}
	vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &to_read)

	vk_check(vk.EndCommandBuffer(cmd), "EndCommandBuffer(texture)")
	submit := vk.SubmitInfo{
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}
	vk_check(vk.QueueSubmit(app.queue, 1, &submit, 0), "QueueSubmit(texture)")
	vk_check(vk.QueueWaitIdle(app.queue), "QueueWaitIdle(texture)")

	app.block_view = create_image_view(app.block_image, .R8G8B8A8_UNORM, {.COLOR}, TEX_MIPS, TEX_LAYERS)

	smp := vk.SamplerCreateInfo{
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .NEAREST,
		minFilter    = .LINEAR,
		mipmapMode   = .LINEAR,
		addressModeU = .REPEAT,
		addressModeV = .REPEAT,
		addressModeW = .REPEAT,
		maxLod       = f32(TEX_MIPS - 1),
	}
	vk_check(vk.CreateSampler(app.device, &smp, nil, &app.block_sampler), "CreateSampler(block textures)")
}

create_pipeline_layout :: proc() {
	ci := vk.PipelineLayoutCreateInfo{
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts    = &app.desc_layout,
	}
	vk_check(vk.CreatePipelineLayout(app.device, &ci, nil, &app.pipe_layout), "CreatePipelineLayout")
}

shader_module :: proc(code: []u8) -> vk.ShaderModule {
	words := make([]u32, len(code) / 4, context.temp_allocator)
	mem.copy(raw_data(words), raw_data(code), len(code))
	ci := vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(words),
	}
	module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(app.device, &ci, nil, &module), "CreateShaderModule")
	return module
}

create_pipelines :: proc() {
	voxel_code := #load("../shaders/voxel.spv")
	module := shader_module(voxel_code)
	defer vk.DestroyShaderModule(app.device, module, nil)

	binding := vk.VertexInputBindingDescription{
		binding   = 0,
		stride    = u32(size_of(Vertex)),
		inputRate = .VERTEX,
	}
	attributes := [4]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
		{location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = 12},
		{location = 2, binding = 0, format = .R32G32_SFLOAT, offset = 24},
		{location = 3, binding = 0, format = .R32_SFLOAT, offset = 32},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = 4,
		pVertexAttributeDescriptions    = &attributes[0],
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	static_viewport := vk.Viewport{0, 0, f32(app.extent.width), f32(app.extent.height), 0, 1}
	static_scissor := vk.Rect2D{{0, 0}, app.extent}
	viewport_state := vk.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &static_viewport,
		scissorCount  = 1,
		pScissors     = &static_scissor,
	}
	raster := vk.PipelineRasterizationStateCreateInfo{
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {.BACK},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1.0,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo{
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	depth_state := vk.PipelineDepthStencilStateCreateInfo{
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS_OR_EQUAL,
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState{
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blend := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn_state := vk.PipelineDynamicStateCreateInfo{
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = &dynamic_states[0],
	}

	voxel_stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = module, pName = "vs_voxel"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = module, pName = "fs_voxel"},
	}
	voxel_ci := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = &voxel_stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pDepthStencilState  = &depth_state,
		pColorBlendState    = &color_blend,
		pDynamicState       = &dyn_state,
		layout              = app.pipe_layout,
		renderPass          = app.render_pass,
	}
	vk_check(vk.CreateGraphicsPipelines(app.device, 0, 1, &voxel_ci, nil, &app.pipe_voxel), "CreateGraphicsPipelines(voxel)")

	hud_depth := vk.PipelineDepthStencilStateCreateInfo{
		sType          = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthCompareOp = .LESS_OR_EQUAL,
	}
	hud_stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = module, pName = "vs_hud"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = module, pName = "fs_hud"},
	}
	hud_raster := raster
	hud_raster.cullMode = {}
	hud_ci := voxel_ci
	hud_ci.pStages = &hud_stages[0]
	hud_ci.pRasterizationState = &hud_raster
	hud_ci.pDepthStencilState = &hud_depth
	hud_ci.renderPass = app.hud_pass
	vk_check(vk.CreateGraphicsPipelines(app.device, 0, 1, &hud_ci, nil, &app.pipe_hud), "CreateGraphicsPipelines(hud)")

	crosshair_blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable         = true,
		srcColorBlendFactor = .ONE_MINUS_DST_COLOR,
		dstColorBlendFactor = .ONE_MINUS_SRC_COLOR,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	crosshair_blend := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &crosshair_blend_attachment,
	}
	crosshair_ci := hud_ci
	crosshair_ci.pColorBlendState = &crosshair_blend
	vk_check(vk.CreateGraphicsPipelines(app.device, 0, 1, &crosshair_ci, nil, &app.pipe_crosshair), "CreateGraphicsPipelines(crosshair)")

	empty_input := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	composite_stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = module, pName = "vs_fullscreen"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = module, pName = "fs_composite"},
	}
	composite_ci := hud_ci
	composite_ci.pStages = &composite_stages[0]
	composite_ci.pVertexInputState = &empty_input
	vk_check(vk.CreateGraphicsPipelines(app.device, 0, 1, &composite_ci, nil, &app.pipe_composite), "CreateGraphicsPipelines(composite)")

	outline_blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	outline_blend := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &outline_blend_attachment,
	}
	outline_depth := vk.PipelineDepthStencilStateCreateInfo{
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = false,
		depthCompareOp   = .LESS_OR_EQUAL,
	}
	outline_stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = module, pName = "vs_voxel"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = module, pName = "fs_outline"},
	}
	outline_ci := voxel_ci
	outline_ci.pStages = &outline_stages[0]
	outline_ci.pRasterizationState = &hud_raster
	outline_ci.pDepthStencilState = &outline_depth
	outline_ci.pColorBlendState = &outline_blend
	vk_check(vk.CreateGraphicsPipelines(app.device, 0, 1, &outline_ci, nil, &app.pipe_outline), "CreateGraphicsPipelines(outline)")
}

create_frames :: proc() {
	app.frames = make([]Frame, MAX_FRAMES)
	app.desc_sets = make([]vk.DescriptorSet, MAX_FRAMES)

	pool := vk.CommandPoolCreateInfo{
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = app.queue_family,
	}
	vk_check(vk.CreateCommandPool(app.device, &pool, nil, &app.cmd_pool), "CreateCommandPool")

	app.hud_cap = HUD_QUADS * 6
	hud_bytes := vk.DeviceSize(app.hud_cap * size_of(Vertex))

	for i in 0 ..< MAX_FRAMES {
		f := &app.frames[i]
		f.ubo = create_buffer(vk.DeviceSize(size_of(UBO)), {.UNIFORM_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
		f.hud = create_buffer(hud_bytes, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
		f.outline = create_buffer(vk.DeviceSize(OUTLINE_MAX_VERTS * size_of(Vertex)), {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})

		alloc := vk.CommandBufferAllocateInfo{
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = app.cmd_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}
		vk_check(vk.AllocateCommandBuffers(app.device, &alloc, &f.cmd), "AllocateCommandBuffers")

		fence_ci := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
		vk_check(vk.CreateFence(app.device, &fence_ci, nil, &f.fence), "CreateFence")
		sem_ci := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		vk_check(vk.CreateSemaphore(app.device, &sem_ci, nil, &f.sem_image), "CreateSemaphore")
		vk_check(vk.CreateSemaphore(app.device, &sem_ci, nil, &f.sem_render), "CreateSemaphore")

		set_alloc := vk.DescriptorSetAllocateInfo{
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = app.desc_pool,
			descriptorSetCount = 1,
			pSetLayouts        = &app.desc_layout,
		}
		vk_check(vk.AllocateDescriptorSets(app.device, &set_alloc, &app.desc_sets[i]), "AllocateDescriptorSets")

		info := vk.DescriptorBufferInfo{
			buffer = f.ubo.handle,
			offset = 0,
			range  = vk.DeviceSize(size_of(UBO)),
		}
		write := vk.WriteDescriptorSet{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = app.desc_sets[i],
			dstBinding      = 0,
			descriptorCount = 1,
			descriptorType  = .UNIFORM_BUFFER,
			pBufferInfo     = &info,
		}
		vk.UpdateDescriptorSets(app.device, 1, &write, 0, nil)
	}
	update_scene_descriptors()
}

height_at :: proc(x, z: int) -> int {
	fx, fz := f32(x), f32(z)
	h := 7.0 + 1.2 * math.sin(fx * 0.17) + 0.9 * math.cos(fz * 0.21) + 0.6 * math.sin((fx + fz) * 0.09)
	return clamp(int(h), 4, CHUNK - 3)
}

block_at :: proc(x, y, z: int) -> u8 {
	if x < 0 || x >= WORLD_SIZE || z < 0 || z >= WORLD_SIZE || y < 0 || y >= CHUNK {
		return 0
	}
	h := height_at(x, z)
	if y > h { return 0 }
	if y == h { return 1 }
	if y >= h - 3 { return 2 }
	return 3
}

solid_at :: proc(x, y, z: int) -> bool {
	return block_at(x, y, z) != 0
}

raycast_block :: proc() -> (hit: [3]int, ok: bool) {
	o := eye_pos()
	d := forward_dir(player.yaw, player.pitch)
	p := [3]int{int(math.floor(o[0])), int(math.floor(o[1])), int(math.floor(o[2]))}
	step: [3]int
	tmax, tdelta: [3]f32
	for i in 0 ..< 3 {
		step[i] = d[i] < 0 ? -1 : 1
		tdelta[i] = 1.0 / math.abs(d[i])
		tmax[i] = (f32(p[i]) + f32(max(step[i], 0)) - o[i]) / d[i]
	}
	t: f32
	for t <= OUTLINE_REACH {
		if block_at(p[0], p[1], p[2]) != 0 {
			return p, true
		}
		axis := 0
		if tmax[1] < tmax[axis] { axis = 1 }
		if tmax[2] < tmax[axis] { axis = 2 }
		p[axis] += step[axis]
		t = tmax[axis]
		tmax[axis] += tdelta[axis]
	}
	return p, false
}

push_outline_quad :: proc(verts: [^]Vertex, at: ^int, a, b, c, d: [3]f32) {
	col := [3]f32{0.0, 0.0, 0.0}
	pts := [4][3]f32{a, b, c, d}
	for i in ([6]int{0, 1, 2, 0, 2, 3}) {
		verts[at^] = Vertex{pos = pts[i], color = col}
		at^ += 1
	}
}

build_outline :: proc(f: ^Frame, hit: [3]int, ok: bool, eye: [3]f32) {
	verts := cast([^]Vertex)f.outline.mapped
	at := 0
	if ok {
		lo := [3]f32{
			f32(hit[0]) - OUTLINE_INFLATE,
			f32(hit[1]) - OUTLINE_INFLATE,
			f32(hit[2]) - OUTLINE_INFLATE,
		}
		hi := [3]f32{
			f32(hit[0] + 1) + OUTLINE_INFLATE,
			f32(hit[1] + 1) + OUTLINE_INFLATE,
			f32(hit[2] + 1) + OUTLINE_INFLATE,
		}
		px_scale := 2.0 * math.tan(math.to_radians(f32(FOV_Y) * 0.5)) / f32(app.rt_extent.height)
		width_px := f32(OUTLINE_PX / RENDER_SCALE)
		for axis in 0 ..< 3 {
			b := (axis + 1) % 3
			c := (axis + 2) % 3
			for ib in 0 ..< 2 {
				for ic in 0 ..< 2 {
					e0, e1 := lo, hi
					e0[b] = ib == 1 ? hi[b] : lo[b]
					e1[b] = e0[b]
					e0[c] = ic == 1 ? hi[c] : lo[c]
					e1[c] = e0[c]

					mx := (e0[0] + e1[0]) * 0.5
					my := (e0[1] + e1[1]) * 0.5
					mz := (e0[2] + e1[2]) * 0.5
					cx := eye[0] - mx
					cy := eye[1] - my
					cz := eye[2] - mz
					dist := math.sqrt(cx * cx + cy * cy + cz * cz)
					dist = max(dist, 0.1)
					dx := e1[0] - e0[0]
					dy := e1[1] - e0[1]
					dz := e1[2] - e0[2]
					sx := dy * cz - dz * cy
					sy := dz * cx - dx * cz
					sz := dx * cy - dy * cx
					sl := math.sqrt(sx * sx + sy * sy + sz * sz)
					if sl < 1e-5 {
						continue
					}
					half := width_px * dist * px_scale * 0.5 / sl
					ax, ay, az := sx * half, sy * half, sz * half
					push_outline_quad(
						verts, &at,
						[3]f32{e0[0] - ax, e0[1] - ay, e0[2] - az},
						[3]f32{e1[0] - ax, e1[1] - ay, e1[2] - az},
						[3]f32{e1[0] + ax, e1[1] + ay, e1[2] + az},
						[3]f32{e0[0] + ax, e0[1] + ay, e0[2] + az},
					)
				}
			}
		}
	}
	f.outline_draw = u32(at)
}

Face :: struct {
	normal:  [3]int,
	corners: [4][3]f32,
	shade:   f32,
}

FACES := [6]Face{
	{{1, 0, 0}, {{1, 0, 0}, {1, 0, 1}, {1, 1, 1}, {1, 1, 0}}, 0.80},
	{{-1, 0, 0}, {{0, 0, 1}, {0, 0, 0}, {0, 1, 0}, {0, 1, 1}}, 0.68},
	{{0, 1, 0}, {{0, 1, 0}, {1, 1, 0}, {1, 1, 1}, {0, 1, 1}}, 1.00},
	{{0, -1, 0}, {{0, 0, 1}, {1, 0, 1}, {1, 0, 0}, {0, 0, 0}}, 0.52},
	{{0, 0, 1}, {{1, 0, 1}, {0, 0, 1}, {0, 1, 1}, {1, 1, 1}}, 0.88},
	{{0, 0, -1}, {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}, 0.74},
}

block_layer :: proc(kind: u8, face: int) -> u32 {
	switch kind {
	case 1:
		switch face {
		case 2: return TEX_GRASS_TOP
		case 3: return TEX_DIRT
		}
		return TEX_GRASS_SIDE
	case 2: return TEX_DIRT
	case 3: return TEX_STONE
	}
	return TEX_DIRT
}

axis_of :: proc(dir: [3]int) -> int {
	if dir[0] != 0 { return 0 }
	if dir[1] != 0 { return 1 }
	return 2
}

mesh_extent :: proc(axis: int) -> int {
	return axis == 1 ? CHUNK : WORLD_SIZE
}

build_chunk :: proc() -> []Vertex {
	verts := make([dynamic]Vertex, 0, 1 << 14)
	grid := make([]u8, WORLD_SIZE * WORLD_SIZE)
	used := make([]bool, WORLD_SIZE * WORLD_SIZE)
	defer {
		delete(grid)
		delete(used)
	}

	for f, fi in FACES {
		u_dir := [3]int{
			int(f.corners[1][0] - f.corners[0][0]),
			int(f.corners[1][1] - f.corners[0][1]),
			int(f.corners[1][2] - f.corners[0][2]),
		}
		v_dir := [3]int{
			int(f.corners[3][0] - f.corners[0][0]),
			int(f.corners[3][1] - f.corners[0][1]),
			int(f.corners[3][2] - f.corners[0][2]),
		}
		axis_u := axis_of(u_dir)
		axis_v := axis_of(v_dir)
		axis_n := axis_of(f.normal)
		u_size := mesh_extent(axis_u)
		v_size := mesh_extent(axis_v)
		slices := mesh_extent(axis_n)

		for s in 0 ..< slices {
			for v in 0 ..< v_size {
				for u in 0 ..< u_size {
					p := [3]int{0, 0, 0}
					p[axis_n] = s
					p[axis_u] = u_dir[axis_u] > 0 ? u : u_size - 1 - u
					p[axis_v] = v_dir[axis_v] > 0 ? v : v_size - 1 - v
					i := v * u_size + u
					kind := block_at(p[0], p[1], p[2])
					if kind != 0 && block_at(p[0] + f.normal[0], p[1] + f.normal[1], p[2] + f.normal[2]) == 0 {
						grid[i] = kind
					} else {
						grid[i] = 0
					}
					used[i] = false
				}
			}

			for v in 0 ..< v_size {
				for u in 0 ..< u_size {
					i := v * u_size + u
					kind := grid[i]
					if kind == 0 || used[i] {
						continue
					}

					w := 1
					for u + w < u_size && !used[i + w] && grid[i + w] == kind {
						w += 1
					}
					h := 1
					merge: for v + h < v_size {
						row := (v + h) * u_size + u
						for k in 0 ..< w {
							if used[row + k] || grid[row + k] != kind {
								break merge
							}
						}
						h += 1
					}
					for dv in 0 ..< h {
						for du in 0 ..< w {
							used[(v + dv) * u_size + u + du] = true
						}
					}

					ap := [3]int{0, 0, 0}
					ap[axis_n] = s
					ap[axis_u] = u_dir[axis_u] > 0 ? u : u_size - 1 - u
					ap[axis_v] = v_dir[axis_v] > 0 ? v : v_size - 1 - v

					jitter := 0.94 + 0.06 * f32((ap[0] * 3 + ap[2] * 7 + ap[1] * 5) % 5) / 4.0
					shade := f.shade * jitter
					col := [3]f32{shade, shade, shade}
					layer := f32(block_layer(kind, fi))

					c0 := [3]f32{
						f32(ap[0]) + f.corners[0][0],
						f32(ap[1]) + f.corners[0][1],
						f32(ap[2]) + f.corners[0][2],
					}
					eu := [3]f32{f32(u_dir[0] * w), f32(u_dir[1] * w), f32(u_dir[2] * w)}
					ev := [3]f32{f32(v_dir[0] * h), f32(v_dir[1] * h), f32(v_dir[2] * h)}
					corners := [4][3]f32{
						c0,
						{c0[0] + eu[0], c0[1] + eu[1], c0[2] + eu[2]},
						{c0[0] + eu[0] + ev[0], c0[1] + eu[1] + ev[1], c0[2] + eu[2] + ev[2]},
						{c0[0] + ev[0], c0[1] + ev[1], c0[2] + ev[2]},
					}
					uvs := [4][2]f32{
						{0, f32(h)},
						{f32(w), f32(h)},
						{f32(w), 0},
						{0, 0},
					}
					for tri in ([][3]int{{0, 1, 2}, {0, 2, 3}}) {
						for k in tri {
							append(&verts, Vertex{pos = corners[k], color = col, uv = uvs[k], layer = layer})
						}
					}
				}
			}
		}
	}
	return verts[:]
}

upload_chunk :: proc() {
	mesh := build_chunk()
	defer delete(mesh)
	app.vcount = u32(len(mesh))
	app.vbuf = create_buffer(vk.DeviceSize(len(mesh) * size_of(Vertex)), {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	mem.copy(app.vbuf.mapped, raw_data(mesh), len(mesh) * size_of(Vertex))
}

forward_dir :: proc(yaw, pitch: f32) -> [3]f32 {
	cp := math.cos(pitch)
	return {cp * math.sin(yaw), math.sin(pitch), -cp * math.cos(yaw)}
}

facing_name :: proc(yaw: f32) -> string {
	fx := math.sin(yaw)
	fz := -math.cos(yaw)
	if abs(fx) > abs(fz) {
		return "east" if fx > 0 else "west"
	}
	return "south" if fz > 0 else "north"
}

key_down :: proc(vk_code: i32) -> bool {
	return windows.GetAsyncKeyState(vk_code) < 0
}

eye_pos :: proc() -> [3]f32 {
	return {player.pos[0], player.pos[1] + EYE_HEIGHT, player.pos[2]}
}

player_box_hits :: proc(p: [3]f32) -> bool {
	x0 := int(math.floor(p[0] - PLAYER_HALF))
	x1 := int(math.floor(p[0] + PLAYER_HALF))
	y0 := int(math.floor(p[1]))
	y1 := int(math.floor(p[1] + PLAYER_HEIGHT - 0.001))
	z0 := int(math.floor(p[2] - PLAYER_HALF))
	z1 := int(math.floor(p[2] + PLAYER_HALF))
	for y in y0 ..= y1 {
		for z in z0 ..= z1 {
			for x in x0 ..= x1 {
				if solid_at(x, y, z) {
					return true
				}
			}
		}
	}
	return false
}

physics :: proc(dt: f32) {
	remaining := dt
	for remaining > 0 {
		h := min(remaining, f32(1.0 / 120.0))
		remaining -= h

		player.vel[1] = max(player.vel[1] - GRAVITY * h, f32(-55.0))

		next := player.pos
		next[0] += player.vel[0] * h
		if player_box_hits(next) {
			player.vel[0] = 0
		} else {
			player.pos[0] = next[0]
		}

		next = player.pos
		next[2] += player.vel[2] * h
		if player_box_hits(next) {
			player.vel[2] = 0
		} else {
			player.pos[2] = next[2]
		}

		next = player.pos
		next[1] += player.vel[1] * h
		if player_box_hits(next) {
			if player.vel[1] <= 0 {
				player.on_ground = true
			}
			player.vel[1] = 0
		} else {
			player.pos[1] = next[1]
			if player.vel[1] > 0 {
				player.on_ground = false
			}
		}
	}
}

set_cursor_locked :: proc(locked: bool) {
	if locked == cursor_locked {
		return
	}
	cursor_locked = locked
	windows.ShowCursor(windows.BOOL(!locked))
	mouse_ready = false
	if locked {
		rect: windows.RECT
		windows.GetClientRect(app.hwnd, &rect)
		center := windows.POINT{rect.right / 2, rect.bottom / 2}
		windows.ClientToScreen(app.hwnd, &center)
		windows.SetCursorPos(center.x, center.y)
	}
}

update_input :: proc(dt: f32) {
	focused := windows.GetForegroundWindow() == app.hwnd
	active := cursor_locked && focused

	if !focused {
		mouse_ready = false
	}

	if active {
		rect: windows.RECT
		windows.GetClientRect(app.hwnd, &rect)
		center := windows.POINT{rect.right / 2, rect.bottom / 2}
		windows.ClientToScreen(app.hwnd, &center)

		if !mouse_ready {
			windows.SetCursorPos(center.x, center.y)
			mouse_ready = true
		}

		pos: windows.POINT
		windows.GetCursorPos(&pos)
		dx := pos.x - center.x
		dy := pos.y - center.y
		if dx != 0 || dy != 0 {
			player.yaw += f32(dx) * 0.0025
			player.pitch = clamp(player.pitch - f32(dy) * 0.0025, -1.55, 1.55)
			windows.SetCursorPos(center.x, center.y)
		}
	}

	fwd := [3]f32{math.sin(player.yaw), 0, -math.cos(player.yaw)}
	right := [3]f32{math.cos(player.yaw), 0, math.sin(player.yaw)}
	move := [3]f32{0, 0, 0}

	if active {
		if key_down(i32('W')) { move += fwd }
		if key_down(i32('S')) { move -= fwd }
		if key_down(i32('D')) { move += right }
		if key_down(i32('A')) { move -= right }
	}

	move_len := math.sqrt(move[0] * move[0] + move[2] * move[2])
	speed: f32 = WALK_SPEED
	if key_down(windows.VK_SHIFT) {
		speed = SPRINT_SPEED
	}
	if move_len > 0.001 {
		player.vel[0] = move[0] / move_len * speed
		player.vel[2] = move[2] / move_len * speed
	} else {
		player.vel[0] = 0
		player.vel[2] = 0
	}

	if active && player.on_ground && key_down(windows.VK_SPACE) {
		player.vel[1] = JUMP_SPEED
		player.on_ground = false
	}

	physics(dt)

	if player.pos[1] < -24 {
		player.pos = spawn_point
		player.vel = {0, 0, 0}
	}
}


append_quad :: proc(verts: [^]Vertex, at: ^int, q: easy_font.Quad) {
	col := [3]f32{f32(q.tl.c[0]) / 255, f32(q.tl.c[1]) / 255, f32(q.tl.c[2]) / 255}
	corners := [4][3]f32{q.tl.v, q.tr.v, q.br.v, q.bl.v}
	index: [6]int = {0, 1, 2, 0, 2, 3}
	for i in index {
		verts[at^] = Vertex{pos = corners[i], color = col}
		at^ += 1
	}
}

push_rect :: proc(verts: [^]Vertex, at: ^int, x0, y0, x1, y1: f32, col: [3]f32) {
	corners := [4][2]f32{{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}}
	for i in ([6]int{0, 1, 2, 0, 2, 3}) {
		verts[at^] = Vertex{pos = {corners[i][0], corners[i][1], 0}, color = col}
		at^ += 1
	}
}

build_hud :: proc(f: ^Frame, lines: []string) {
	quads := hud_quads
	n := 0
	shadow := easy_font.Color{0, 0, 0, 255}
	white := easy_font.Color{244, 247, 255, 255}

	for line, i in lines {
		y := f32(14 + i * 24)
		n += easy_font.print(f32(16), y + 2, line, shadow, quads[n:], 2.0)
	}
	shadow_quads := n
	for line, i in lines {
		y := f32(14 + i * 24)
		n += easy_font.print(f32(14), y, line, white, quads[n:], 2.0)
	}

	verts := cast([^]Vertex)f.hud.mapped
	at := 0
	for q in quads[:n] {
		append_quad(verts, &at, q)
	}
	text_end := at

	gui := f32(2)
	cx := f32(app.extent.width) * 0.5
	cy := f32(app.extent.height) * 0.5
	arm := 9 * gui * 0.5
	thick := gui * 0.5
	mark := [3]f32{1, 1, 1}
	push_rect(verts, &at, cx - arm, cy - thick, cx + arm, cy + thick, mark)
	push_rect(verts, &at, cx - thick, cy - arm, cx + thick, cy - thick, mark)
	push_rect(verts, &at, cx - thick, cy + thick, cx + thick, cy + arm, mark)

	f.hud_shadow = u32(shadow_quads * 6)
	f.hud_text = u32(text_end - shadow_quads * 6)
	f.crosshair_draw = u32(at - text_end)
}

record_frame :: proc(f: ^Frame, image_index: u32, vp: linalg.Matrix4f32) {
	eye := eye_pos()
	ubo := UBO{
		view_proj = vp,
		cam_pos   = {eye[0], eye[1], eye[2], 0},
		screen    = {f32(app.extent.width), f32(app.extent.height), 0, 0},
	}
	mem.copy(f.ubo.mapped, &ubo, size_of(UBO))

	vk.ResetCommandBuffer(f.cmd, {})
	begin := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(f.cmd, &begin), "BeginCommandBuffer")

	clears := [2]vk.ClearValue{
		{color = {float32 = {0.58, 0.73, 0.93, 1.0}}},
		{depthStencil = {depth = 1.0, stencil = 0}},
	}
	rp := vk.RenderPassBeginInfo{
		sType           = .RENDER_PASS_BEGIN_INFO,
		renderPass      = app.render_pass,
		framebuffer     = app.fbo,
		renderArea      = {{0, 0}, app.rt_extent},
		clearValueCount = 2,
		pClearValues    = &clears[0],
	}
	vk.CmdBeginRenderPass(f.cmd, &rp, .INLINE)

	viewport := vk.Viewport{
		x        = 0,
		y        = 0,
		width    = f32(app.rt_extent.width),
		height   = f32(app.rt_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	scissor := vk.Rect2D{offset = {0, 0}, extent = app.rt_extent}
	vk.CmdSetViewport(f.cmd, 0, 1, &viewport)
	vk.CmdSetScissor(f.cmd, 0, 1, &scissor)

	if app.vcount > 0 {
		vk.CmdBindPipeline(f.cmd, .GRAPHICS, app.pipe_voxel)
		set := app.desc_sets[app.frame_index]
		vk.CmdBindDescriptorSets(f.cmd, .GRAPHICS, app.pipe_layout, 0, 1, &set, 0, nil)
		offset: vk.DeviceSize = 0
		vk.CmdBindVertexBuffers(f.cmd, 0, 1, &app.vbuf.handle, &offset)
		vk.CmdDraw(f.cmd, app.vcount, 1, 0, 0)
	}

	if f.outline_draw > 0 {
		vk.CmdBindPipeline(f.cmd, .GRAPHICS, app.pipe_outline)
		set := app.desc_sets[app.frame_index]
		vk.CmdBindDescriptorSets(f.cmd, .GRAPHICS, app.pipe_layout, 0, 1, &set, 0, nil)
		offset: vk.DeviceSize = 0
		vk.CmdBindVertexBuffers(f.cmd, 0, 1, &f.outline.handle, &offset)
		vk.CmdDraw(f.cmd, f.outline_draw, 1, 0, 0)
	}

	vk.CmdEndRenderPass(f.cmd)

	src_range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	rt_barrier := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {.COLOR_ATTACHMENT_WRITE},
		dstAccessMask       = {.SHADER_READ},
		oldLayout           = .SHADER_READ_ONLY_OPTIMAL,
		newLayout           = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = app.rt_image,
		subresourceRange    = src_range,
	}
	vk.CmdPipelineBarrier(f.cmd, {.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &rt_barrier)

	hud_rp := vk.RenderPassBeginInfo{
		sType       = .RENDER_PASS_BEGIN_INFO,
		renderPass  = app.hud_pass,
		framebuffer = app.hud_fbos[image_index],
		renderArea  = {{0, 0}, app.extent},
	}
	vk.CmdBeginRenderPass(f.cmd, &hud_rp, .INLINE)

	hud_viewport := vk.Viewport{
		x        = 0,
		y        = 0,
		width    = f32(app.extent.width),
		height   = f32(app.extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	hud_scissor := vk.Rect2D{offset = {0, 0}, extent = app.extent}
	vk.CmdSetViewport(f.cmd, 0, 1, &hud_viewport)
	vk.CmdSetScissor(f.cmd, 0, 1, &hud_scissor)

	vk.CmdBindPipeline(f.cmd, .GRAPHICS, app.pipe_composite)
	set := app.desc_sets[app.frame_index]
	vk.CmdBindDescriptorSets(f.cmd, .GRAPHICS, app.pipe_layout, 0, 1, &set, 0, nil)
	vk.CmdDraw(f.cmd, 3, 1, 0, 0)

	if f.hud_text + f.crosshair_draw > 0 {
		set := app.desc_sets[app.frame_index]
		offset: vk.DeviceSize = 0
		vk.CmdBindVertexBuffers(f.cmd, 0, 1, &f.hud.handle, &offset)
		vk.CmdBindPipeline(f.cmd, .GRAPHICS, app.pipe_hud)
		vk.CmdBindDescriptorSets(f.cmd, .GRAPHICS, app.pipe_layout, 0, 1, &set, 0, nil)
		if f.hud_text > 0 {
			vk.CmdDraw(f.cmd, f.hud_shadow, 1, 0, 0)
			vk.CmdDraw(f.cmd, f.hud_text, 1, f.hud_shadow, 0)
		}
		if f.crosshair_draw > 0 {
			vk.CmdBindPipeline(f.cmd, .GRAPHICS, app.pipe_crosshair)
			vk.CmdDraw(f.cmd, f.crosshair_draw, 1, f.hud_shadow + f.hud_text, 0)
		}
	}

	vk.CmdEndRenderPass(f.cmd)

	vk_check(vk.EndCommandBuffer(f.cmd), "EndCommandBuffer")
}

draw_frame :: proc() -> bool {
	f := &app.frames[app.frame_index]

	image_index: u32
	t0 := time.now()
	res := vk.AcquireNextImageKHR(app.device, app.swapchain, max(u64), f.sem_image, 0, &image_index)
	if bench_mode {
		bench_acquire_ns += i64(time.duration_nanoseconds(time.since(t0)))
	}
	if res == .ERROR_OUT_OF_DATE_KHR {
		return false
	}
	if res != .SUCCESS && res != .SUBOPTIMAL_KHR {
		fmt.eprintln("AcquireNextImageKHR:", res)
		should_quit = true
		return true
	}

	tf := time.now()
	vk_check(vk.WaitForFences(app.device, 1, &f.fence, true, max(u64)), "WaitForFences")
	vk_check(vk.ResetFences(app.device, 1, &f.fence), "ResetFences")
	if bench_mode {
		bench_fence_ns += i64(time.duration_nanoseconds(time.since(tf)))
	}

	aspect := f32(app.rt_extent.width) / f32(app.rt_extent.height)
	proj := linalg.matrix4_perspective(math.to_radians(f32(FOV_Y)), aspect, f32(0.05), f32(400))
	eye := eye_pos()
	view := linalg.matrix4_look_at(
		eye,
		eye + forward_dir(player.yaw, player.pitch),
		[3]f32{0, 1, 0},
	)
	hit, has_hit := raycast_block()
	build_outline(f, hit, has_hit, eye)
	record_frame(f, image_index, proj * view)

	wait_stage := vk.PipelineStageFlags{.TRANSFER, .COLOR_ATTACHMENT_OUTPUT}
	submit := vk.SubmitInfo{
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &f.sem_image,
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &f.cmd,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &f.sem_render,
	}
	ts := time.now()
	vk_check(vk.QueueSubmit(app.queue, 1, &submit, f.fence), "QueueSubmit")
	if bench_mode {
		bench_submit_ns += i64(time.duration_nanoseconds(time.since(ts)))
	}

	present := vk.PresentInfoKHR{
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &f.sem_render,
		swapchainCount     = 1,
		pSwapchains        = &app.swapchain,
		pImageIndices      = &image_index,
	}
	tp := time.now()
	pres := vk.QueuePresentKHR(app.queue, &present)
	if bench_mode {
		bench_present_ns += i64(time.duration_nanoseconds(time.since(tp)))
		bench_calls += 1
	}
	if pres == .ERROR_OUT_OF_DATE_KHR || pres == .SUBOPTIMAL_KHR {
		return false
	}

	app.frame_index = (app.frame_index + 1) % MAX_FRAMES
	return true
}

set_title :: proc(fps: int) {
	title := fmt.tprintf("Vulke 1.0.0 (Windows / Vulkan) - %d FPS - XYZ %.1f %.1f %.1f", fps, player.pos[0], player.pos[1], player.pos[2])
	buf: [512]u16
	w := windows.utf8_to_utf16_buf(buf[:], title)
	if len(w) > 0 {
		windows.SetWindowTextW(app.hwnd, cstring16(&buf[0]))
	}
}

parse_args :: proc() {
	args := os.args
	i := 1
	for i < len(args) {
		switch args[i] {
		case "--bench":
			bench_mode = true
			if i + 1 < len(args) {
				if secs, ok := strconv.parse_f64(args[i + 1]); ok {
					bench_seconds = secs
					i += 1
				}
			}
		}
		i += 1
	}
}

bench_finish :: proc() {
	slice.sort(bench_dts[:])
	n := len(bench_dts)
	median := bench_dts[n / 2]
	slow := bench_dts[min(n - 1, (n * 99) / 100)]
	mean: f64
	for d in bench_dts {
		mean += f64(d)
	}
	mean /= f64(n)
	fmt.printfln(
		"BENCH frames=%d median_fps=%.1f mean_fps=%.1f p1_low_fps=%.1f",
		n,
		1.0 / f64(median),
		1.0 / mean,
		1.0 / f64(slow),
	)
	if bench_calls > 0 {
		fmt.printfln(
			"BENCH acquire_avg_us=%.1f present_avg_us=%.1f fence_avg_us=%.1f submit_avg_us=%.1f",
			f64(bench_acquire_ns) / f64(bench_calls) / 1000.0,
			f64(bench_present_ns) / f64(bench_calls) / 1000.0,
			f64(bench_fence_ns) / f64(bench_calls) / 1000.0,
			f64(bench_submit_ns) / f64(bench_calls) / 1000.0,
		)
	}
}

main :: proc() {
	parse_args()
	if !load_vulkan() {
		os.exit(1)
	}
	if !create_window() {
		os.exit(1)
	}

	create_instance()
	pick_device()
	create_device()

	create_swapchain()
	create_render_pass()
	create_framebuffers()
	create_sampler()
	create_block_textures()
	create_descriptors()
	create_pipeline_layout()
	create_pipelines()
	create_frames()
	upload_chunk()

	hud_quads = make([]easy_font.Quad, HUD_QUADS)

	spawn_x := WORLD_SIZE / 2
	spawn_z := WORLD_SIZE / 2
	spawn_point = {f32(spawn_x) + 0.5, f32(height_at(spawn_x, spawn_z)) + 1.0, f32(spawn_z) + 0.5}
	player = Player{pos = spawn_point, yaw = 0, pitch = -0.15}
	if !bench_mode {
		set_cursor_locked(true)
	}

	last := time.now()
	fps_time: f64 = 0
	fps_frames := 0
	fps := 0
	title_time: f64 = 0

	for !should_quit {
		msg: windows.MSG
		for windows.PeekMessageW(&msg, nil, 0, 0, windows.PM_REMOVE) != false {
			if msg.message == windows.WM_QUIT {
				should_quit = true
				break
			}
			windows.TranslateMessage(&msg)
			windows.DispatchMessageW(&msg)
		}
		if should_quit {
			break
		}

		if lock_requested {
			lock_requested = false
			set_cursor_locked(true)
		}
		if cursor_locked && (windows.GetForegroundWindow() != app.hwnd || key_down(windows.VK_ESCAPE)) {
			set_cursor_locked(false)
		}

		now := time.now()
		dt := f32(time.duration_seconds(time.since(last)))
		last = now
		raw_dt := dt
		if dt > 0.1 {
			dt = 0.1
		}

		if bench_mode {
			bench_elapsed += f64(raw_dt)
			if bench_elapsed >= 1.0 {
				append(&bench_dts, raw_dt)
			}
		}

		rect: windows.RECT
		windows.GetClientRect(app.hwnd, &rect)
		cw := u32(max(rect.right - rect.left, 0))
		ch := u32(max(rect.bottom - rect.top, 0))
		if cw == 0 || ch == 0 {
			time.sleep(8 * time.Millisecond)
			continue
		}
		want := render_extent(cw, ch)
		if want.width != app.rt_extent.width || want.height != app.rt_extent.height {
			destroy_swapchain()
			create_swapchain()
			create_framebuffers()
		}

		update_input(dt)

		fps_time += f64(dt)
		fps_frames += 1
		if fps_time >= 0.25 {
			fps = int(f64(fps_frames) / fps_time)
			fps_time = 0
			fps_frames = 0
		}
		title_time += f64(dt)

		block_x := int(math.floor(player.pos[0]))
		block_y := int(math.floor(player.pos[1])) - 1
		block_z := int(math.floor(player.pos[2]))
		kind := block_at(block_x, block_y, block_z)
		block_name := "air"
		switch kind {
		case 1: block_name = "grass_block"
		case 2: block_name = "dirt"
		case 3: block_name = "stone"
		}

		yaw_deg := math.to_degrees(player.yaw)
		yaw_deg = yaw_deg - math.floor(yaw_deg / 360) * 360

		lines := []string{
			fmt.tprintf("Vulke 1.0.0 (Windows / Vulkan)        %d FPS", fps),
			fmt.tprintf("XYZ: %.1f / %.1f / %.1f", player.pos[0], player.pos[1], player.pos[2]),
			fmt.tprintf("Block: %s    Chunk: %d, %d", block_name, int(math.floor(f32(block_x) / CHUNK)), int(math.floor(f32(block_z) / CHUNK))),
			fmt.tprintf("Health: 20/20    Seeds: 1"),
			fmt.tprintf("Facing %s  (yaw %.1f / pitch %.1f)", facing_name(player.yaw), yaw_deg, math.to_degrees(player.pitch)),
			fmt.tprintf("GPU: %s", app.gpu_name),
		}
		build_hud(&app.frames[app.frame_index], lines)

		if !draw_frame() {
			vk.DeviceWaitIdle(app.device)
			destroy_swapchain()
			create_swapchain()
			create_framebuffers()
		}

		if title_time >= 0.5 {
			set_title(fps)
			title_time = 0
		}
		free_all(context.temp_allocator)

		if bench_mode && bench_elapsed >= bench_seconds + 1.0 && len(bench_dts) > 64 {
			break
		}
	}

	if bench_mode && len(bench_dts) > 0 {
		bench_finish()
	}
	vk.DeviceWaitIdle(app.device)
	destroy_swapchain()
	fmt.println("bye")
}
