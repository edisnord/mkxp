/*
 * Runtime glue for mkxp as a native PS5 title using ps5-opengl.
 * Based on ps5-opengl's native-app/runtime_shims.c.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

/* The title has no console: send stdout/stderr (mkxp's debug output and
 * Ruby errors) to a log in the title's download data directory */
__attribute__((constructor)) static void mkxp_open_log(void)
{
	FILE *stream = freopen("/download0/mkxp.log", "w", stdout);

	if (stream != NULL)
		setvbuf(stream, NULL, _IONBF, 0);

	stream = freopen("/download0/mkxp.log", "a", stderr);

	if (stream != NULL)
		setvbuf(stream, NULL, _IONBF, 0);
}

/* app_heap.c (ps5-opengl's allocator for native titles) reserves this much
 * and falls back to smaller sizes if the mapping fails. Its default of
 * 128 MiB is too tight for Ruby plus a game's bitmaps. */
const size_t ps5_opengl_heap_size = 1024u * 1024u * 1024u;

/* The OpenGL runtime references this TLS init function; Mesa's glapi
 * context needs no dynamic initialization. (Other functions it needs that
 * the native libc lacks come from the payload SDK's libc.a.) */

void ps5_opengl_glapi_tls_context_init(void) __asm__(
	"_ZTH23_mesa_glapi_tls_Context");

void ps5_opengl_glapi_tls_context_init(void)
{
}
