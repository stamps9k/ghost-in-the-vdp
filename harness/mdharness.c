/*
 * mdharness — headless Mega Drive test runner
 *
 * Loads a libretro core (Genesis Plus GX), boots a ROM with no display, and
 * plays a small test script against it: advance frames, hold buttons, and
 * capture frames as PNG. Each capture can carry an expected CRC32 of the
 * frame's RGB pixels; a mismatch fails the run.
 *
 * Usage: mdharness <core.so> <rom.bin> <script.test> <out-dir>
 *
 * Script commands (one per line, '#' starts a comment):
 *   run N                 advance N frames with the current buttons held
 *   hold [BUTTON ...]     set the held buttons; bare "hold" releases all
 *   press BUTTON ... [N]  hold the buttons for N frames (default 2), then
 *                         release them
 *   shot NAME [CRC32]     write <out-dir>/NAME.png; if CRC32 (8 hex digits)
 *                         is given, the frame must match it
 *
 * Buttons: up down left right a b c start
 *
 * Exit status: 0 all expectations met, 1 a shot mismatched, 2 usage/setup
 * error. Every shot prints its CRC so new expectations can be filled in.
 */

#include <ctype.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "libretro.h"

/* --------------------------------------------------------------------------
 * Core entry points
 * -------------------------------------------------------------------------- */
static struct {
	void (*set_environment)(retro_environment_t);
	void (*set_video_refresh)(retro_video_refresh_t);
	void (*set_audio_sample)(retro_audio_sample_t);
	void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
	void (*set_input_poll)(retro_input_poll_t);
	void (*set_input_state)(retro_input_state_t);
	void (*init)(void);
	void (*deinit)(void);
	void (*get_system_info)(struct retro_system_info *);
	void (*set_controller_port_device)(unsigned, unsigned);
	bool (*load_game)(const struct retro_game_info *);
	void (*unload_game)(void);
	void (*run)(void);
} core;

/* --------------------------------------------------------------------------
 * Emulator-facing state
 * -------------------------------------------------------------------------- */
static enum retro_pixel_format pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
static uint8_t *frame_rgb;        /* last frame, packed RGB888 */
static unsigned frame_w, frame_h;
static uint16_t held_buttons;     /* bitmask of RETRO_DEVICE_ID_JOYPAD_* */
static const char *system_dir = "/tmp";

static void die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("mdharness: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(2);
}

static void core_log(enum retro_log_level level, const char *fmt, ...)
{
	va_list ap;
	if (level < RETRO_LOG_WARN)
		return;
	va_start(ap, fmt);
	fputs("core: ", stderr);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static bool environment(unsigned cmd, void *data)
{
	switch (cmd) {
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
		pixel_format = *(const enum retro_pixel_format *)data;
		return pixel_format == RETRO_PIXEL_FORMAT_RGB565
		    || pixel_format == RETRO_PIXEL_FORMAT_XRGB8888
		    || pixel_format == RETRO_PIXEL_FORMAT_0RGB1555;
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
		*(const char **)data = system_dir;
		return true;
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
		((struct retro_log_callback *)data)->log = core_log;
		return true;
	case RETRO_ENVIRONMENT_GET_CAN_DUPE:
		*(bool *)data = true;
		return true;
	case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
		return true;
	default:
		/* Unhandled requests (core options included) fall back to the
		 * core's defaults, which keeps runs reproducible. */
		return false;
	}
}

static void video_refresh(const void *data, unsigned w, unsigned h, size_t pitch)
{
	unsigned x, y;

	if (!data)
		return; /* duplicate frame: keep the previous one */

	if (w != frame_w || h != frame_h) {
		free(frame_rgb);
		frame_rgb = malloc((size_t)w * h * 3);
		if (!frame_rgb)
			die("out of memory");
		frame_w = w;
		frame_h = h;
	}

	for (y = 0; y < h; y++) {
		const uint8_t *row = (const uint8_t *)data + y * pitch;
		uint8_t *out = frame_rgb + (size_t)y * w * 3;
		for (x = 0; x < w; x++, out += 3) {
			if (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
				uint32_t p = ((const uint32_t *)row)[x];
				out[0] = p >> 16;
				out[1] = p >> 8;
				out[2] = p;
			} else if (pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
				uint16_t p = ((const uint16_t *)row)[x];
				uint8_t r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F;
				out[0] = (r << 3) | (r >> 2);
				out[1] = (g << 2) | (g >> 4);
				out[2] = (b << 3) | (b >> 2);
			} else {
				uint16_t p = ((const uint16_t *)row)[x];
				uint8_t r = (p >> 10) & 0x1F, g = (p >> 5) & 0x1F, b = p & 0x1F;
				out[0] = (r << 3) | (r >> 2);
				out[1] = (g << 3) | (g >> 2);
				out[2] = (b << 3) | (b >> 2);
			}
		}
	}
}

static void audio_sample(int16_t l, int16_t r) { (void)l; (void)r; }
static size_t audio_sample_batch(const int16_t *d, size_t n) { (void)d; return n; }
static void input_poll(void) {}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
	(void)index;
	if (port != 0 || device != RETRO_DEVICE_JOYPAD)
		return 0;
	if (id == RETRO_DEVICE_ID_JOYPAD_MASK)
		return (int16_t)held_buttons;
	return (held_buttons >> id) & 1;
}

/* --------------------------------------------------------------------------
 * PNG output (RGB888, no filtering, zlib-compressed)
 * -------------------------------------------------------------------------- */
static void put_be32(uint8_t *p, uint32_t v)
{
	p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static void write_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len)
{
	uint8_t hdr[8];
	uLong crc;

	put_be32(hdr, len);
	memcpy(hdr + 4, type, 4);
	fwrite(hdr, 1, 8, f);
	if (len)
		fwrite(data, 1, len, f);
	crc = crc32(0, (const Bytef *)type, 4);
	if (len)
		crc = crc32(crc, data, len);
	put_be32(hdr, (uint32_t)crc);
	fwrite(hdr, 1, 4, f);
}

static void write_png(const char *path)
{
	static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
	size_t stride = (size_t)frame_w * 3, raw_len = (frame_w * 3 + 1) * (size_t)frame_h;
	uint8_t ihdr[13], *raw, *z;
	uLongf z_len = compressBound(raw_len);
	unsigned y;
	FILE *f;

	raw = malloc(raw_len);
	z = malloc(z_len);
	if (!raw || !z)
		die("out of memory");
	for (y = 0; y < frame_h; y++) {
		raw[y * (stride + 1)] = 0; /* filter: none */
		memcpy(raw + y * (stride + 1) + 1, frame_rgb + y * stride, stride);
	}
	if (compress2(z, &z_len, raw, raw_len, 9) != Z_OK)
		die("PNG compression failed");

	put_be32(ihdr, frame_w);
	put_be32(ihdr + 4, frame_h);
	ihdr[8] = 8;  /* bit depth */
	ihdr[9] = 2;  /* colour type: RGB */
	ihdr[10] = ihdr[11] = ihdr[12] = 0;

	f = fopen(path, "wb");
	if (!f)
		die("cannot write %s", path);
	fwrite(sig, 1, 8, f);
	write_chunk(f, "IHDR", ihdr, 13);
	write_chunk(f, "IDAT", z, (uint32_t)z_len);
	write_chunk(f, "IEND", NULL, 0);
	fclose(f);
	free(raw);
	free(z);
}

/* --------------------------------------------------------------------------
 * Script
 * -------------------------------------------------------------------------- */
static int button_id(const char *name)
{
	static const struct { const char *name; int id; } map[] = {
		/* Genesis Plus GX maps A/B/C to the libretro Y/B/A buttons */
		{ "up", RETRO_DEVICE_ID_JOYPAD_UP },
		{ "down", RETRO_DEVICE_ID_JOYPAD_DOWN },
		{ "left", RETRO_DEVICE_ID_JOYPAD_LEFT },
		{ "right", RETRO_DEVICE_ID_JOYPAD_RIGHT },
		{ "a", RETRO_DEVICE_ID_JOYPAD_Y },
		{ "b", RETRO_DEVICE_ID_JOYPAD_B },
		{ "c", RETRO_DEVICE_ID_JOYPAD_A },
		{ "start", RETRO_DEVICE_ID_JOYPAD_START },
	};
	size_t i;
	for (i = 0; i < sizeof map / sizeof map[0]; i++)
		if (!strcmp(name, map[i].name))
			return map[i].id;
	return -1;
}

static void run_frames(long n, unsigned *frame)
{
	while (n-- > 0) {
		core.run();
		(*frame)++;
	}
}

static int is_number(const char *s)
{
	if (!*s)
		return 0;
	for (; *s; s++)
		if (!isdigit((unsigned char)*s))
			return 0;
	return 1;
}

static int run_script(const char *script_path, const char *out_dir)
{
	char line[512], *tok, *args[32];
	unsigned lineno = 0, frame = 0;
	int failures = 0, nargs, i;
	FILE *f = fopen(script_path, "r");

	if (!f)
		die("cannot open script %s", script_path);

	while (fgets(line, sizeof line, f)) {
		char *hash = strchr(line, '#');
		lineno++;
		if (hash)
			*hash = '\0';
		nargs = 0;
		for (tok = strtok(line, " \t\r\n"); tok && nargs < 32; tok = strtok(NULL, " \t\r\n"))
			args[nargs++] = tok;
		if (!nargs)
			continue;

		if (!strcmp(args[0], "run")) {
			if (nargs != 2 || !is_number(args[1]))
				die("%s:%u: usage: run N", script_path, lineno);
			run_frames(atol(args[1]), &frame);
		} else if (!strcmp(args[0], "hold") || !strcmp(args[0], "press")) {
			int is_press = args[0][0] == 'p';
			long hold_for = 2;
			uint16_t mask = 0;
			int last = nargs;

			if (is_press && nargs > 2 && is_number(args[nargs - 1]))
				hold_for = atol(args[--last]);
			for (i = 1; i < last; i++) {
				int id = button_id(args[i]);
				if (id < 0)
					die("%s:%u: unknown button '%s'", script_path, lineno, args[i]);
				mask |= 1u << id;
			}
			if (is_press && !mask)
				die("%s:%u: usage: press BUTTON ... [N]", script_path, lineno);
			held_buttons = mask;
			if (is_press) {
				run_frames(hold_for, &frame);
				held_buttons = 0;
			}
		} else if (!strcmp(args[0], "shot")) {
			char path[1024];
			uint32_t crc;
			if (nargs < 2 || nargs > 3)
				die("%s:%u: usage: shot NAME [CRC32]", script_path, lineno);
			if (!frame_rgb)
				die("%s:%u: no frame rendered yet", script_path, lineno);
			snprintf(path, sizeof path, "%s/%s.png", out_dir, args[1]);
			write_png(path);
			crc = (uint32_t)crc32(0, frame_rgb, frame_w * frame_h * 3);
			if (nargs == 3) {
				uint32_t want = (uint32_t)strtoul(args[2], NULL, 16);
				int ok = crc == want;
				printf("shot %-24s frame %-6u %ux%u crc=%08x %s (expected %08x)\n",
				       args[1], frame, frame_w, frame_h, crc, ok ? "ok" : "MISMATCH", want);
				failures += !ok;
			} else {
				printf("shot %-24s frame %-6u %ux%u crc=%08x (no expectation)\n",
				       args[1], frame, frame_w, frame_h, crc);
			}
		} else {
			die("%s:%u: unknown command '%s'", script_path, lineno, args[0]);
		}
	}
	fclose(f);
	return failures;
}

/* --------------------------------------------------------------------------
 * Main
 * -------------------------------------------------------------------------- */
#define LOAD(field, sym) \
	do { \
		*(void **)&core.field = dlsym(lib, sym); \
		if (!core.field) \
			die("core is missing %s", sym); \
	} while (0)

static void *read_file(const char *path, size_t *size)
{
	FILE *f = fopen(path, "rb");
	void *buf;
	long len;

	if (!f)
		die("cannot open %s", path);
	fseek(f, 0, SEEK_END);
	len = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = malloc(len > 0 ? (size_t)len : 1);
	if (!buf || fread(buf, 1, (size_t)len, f) != (size_t)len)
		die("cannot read %s", path);
	fclose(f);
	*size = (size_t)len;
	return buf;
}

int main(int argc, char **argv)
{
	struct retro_game_info game = { 0 };
	void *lib, *rom;
	size_t rom_size;
	int failures;

	if (argc != 5) {
		fprintf(stderr, "usage: %s <core.so> <rom.bin> <script.test> <out-dir>\n", argv[0]);
		return 2;
	}

	lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!lib)
		die("cannot load core: %s", dlerror());
	LOAD(set_environment, "retro_set_environment");
	LOAD(set_video_refresh, "retro_set_video_refresh");
	LOAD(set_audio_sample, "retro_set_audio_sample");
	LOAD(set_audio_sample_batch, "retro_set_audio_sample_batch");
	LOAD(set_input_poll, "retro_set_input_poll");
	LOAD(set_input_state, "retro_set_input_state");
	LOAD(init, "retro_init");
	LOAD(deinit, "retro_deinit");
	LOAD(get_system_info, "retro_get_system_info");
	LOAD(set_controller_port_device, "retro_set_controller_port_device");
	LOAD(load_game, "retro_load_game");
	LOAD(unload_game, "retro_unload_game");
	LOAD(run, "retro_run");

	system_dir = argv[4];
	core.set_environment(environment);
	core.set_video_refresh(video_refresh);
	core.set_audio_sample(audio_sample);
	core.set_audio_sample_batch(audio_sample_batch);
	core.set_input_poll(input_poll);
	core.set_input_state(input_state);
	core.init();

	rom = read_file(argv[2], &rom_size);
	game.path = argv[2];
	game.data = rom;
	game.size = rom_size;
	if (!core.load_game(&game))
		die("core refused to load %s", argv[2]);
	core.set_controller_port_device(0, RETRO_DEVICE_JOYPAD);

	failures = run_script(argv[3], argv[4]);

	core.unload_game();
	core.deinit();
	free(rom);
	free(frame_rgb);
	return failures ? 1 : 0;
}
