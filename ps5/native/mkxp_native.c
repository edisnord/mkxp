/*
 * Runtime glue for mkxp as a native PS5 title using ps5-opengl.
 * Based on ps5-opengl's native-app/runtime_shims.c.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

/* Debug() (src/debugwriter.h) sends its lines here instead of through
 * stdio: a file written by this title and read back over FTP has no
 * reliable offset sharing with the driver's own stdout trace (see
 * mkxp_open_log() below), so it can silently disappear. UDP to the dev
 * workstation sidesteps that - one send() per line, no shared file, no
 * flush-timing games. This is a development aid, not shipped behavior;
 * the target/port are only reached while that workstation runs a
 * listener on the same LAN. */
#define MKXP_LOG_HOST "192.168.100.19"
#define MKXP_LOG_PORT 5151

void mkxp_udp_log(const char *msg)
{
	static int fd = -2;
	static struct sockaddr_in addr;

	if (fd == -2)
	{
		fd = socket(AF_INET, SOCK_DGRAM, 0);

		if (fd >= 0)
		{
			memset(&addr, 0, sizeof(addr));
			addr.sin_family = AF_INET;
			addr.sin_port = htons(MKXP_LOG_PORT);
			addr.sin_addr.s_addr = inet_addr(MKXP_LOG_HOST);
		}
	}

	if (fd < 0)
		return;

	sendto(fd, msg, strlen(msg), 0, (struct sockaddr *) &addr, sizeof(addr));
}

/* The title has no console: send stdout/stderr (mkxp's debug output and
 * Ruby errors) to a log in /data/mkxp, which can be read over FTP (the
 * title's own download data directory can't).
 *
 * stdout and stderr are dup2()'d onto one fd opened once, rather than each
 * freopen()'d to the path separately: two independent opens of the same
 * path get independent file offsets, and stdout's continuous driver trace
 * silently clobbers stderr's (mkxp's Debug()) sparser writes at whatever
 * low offset they landed at. Sharing the fd makes both share one offset,
 * like a real combined stream. */
__attribute__((constructor)) static void mkxp_open_log(void)
{
	int fd;

	/* The launcher makes these too, but this runs before main() */
	mkdir("/data/mkxp", 0777);
	chmod("/data/mkxp", 0777);

	fd = open("/data/mkxp/mkxp.log", O_WRONLY | O_CREAT | O_TRUNC, 0666);

	if (fd < 0)
		return;

	dup2(fd, 1);
	dup2(fd, 2);

	if (fd > 2)
		close(fd);

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
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

/* The payload SDK's libc.a, linked for what the native libc lacks, wraps
 * these calls as raw "syscall" instructions, which a title may not execute
 * (the console kills it with SYSTEM_ILLEGAL_FUNCTION_CALL). native-link.sh
 * routes them here with --wrap so everything that calls them (Ruby, SDL,
 * PhysFS, libc++, the OpenGL runtime) gets a version that works. */

int sceKernelMmap(void *addr, size_t len, int prot, int flags, int fd,
                  off_t offset, void **res);
int sceKernelMprotect(const void *addr, size_t len, int prot);
int __real_chdir(const char *path);

static int mkxp_sce_error(int ret)
{
	errno = ret & 0xffff;
	return -1;
}

void *__wrap_mmap(void *addr, size_t len, int prot, int flags, int fd,
                  off_t offset)
{
	void *res = MAP_FAILED;
	int ret = sceKernelMmap(addr, len, prot, flags, fd, offset, &res);

	if (ret < 0)
	{
		mkxp_sce_error(ret);
		return MAP_FAILED;
	}

	return res;
}

int __wrap_mprotect(void *addr, size_t len, int prot)
{
	int ret = sceKernelMprotect(addr, len, prot);

	return ret < 0 ? mkxp_sce_error(ret) : 0;
}

int __wrap_ppoll(struct pollfd *fds, nfds_t nfds, const struct timespec *ts,
                 const void *sigmask)
{
	(void) sigmask;

	int timeout = -1;

	if (ts != NULL)
	{
		long long ms = (long long) ts->tv_sec * 1000 + (ts->tv_nsec + 999999) / 1000000;
		timeout = ms > 0x7fffffff ? 0x7fffffff : (int) ms;
	}

	return poll(fds, nfds, timeout);
}

long __wrap_readlink(const char *path, char *buf, size_t size)
{
	(void) path;
	(void) buf;
	(void) size;

	errno = EINVAL;
	return -1;
}

static mode_t mkxp_umask = 022;

mode_t __wrap_umask(mode_t mask)
{
	mode_t old = mkxp_umask;
	mkxp_umask = mask & 0777;

	return old;
}

int __wrap_chown(const char *path, uid_t uid, gid_t gid)
{
	(void) path;
	(void) uid;
	(void) gid;

	errno = ENOSYS;
	return -1;
}

int __wrap_lchown(const char *path, uid_t uid, gid_t gid)
{
	return __wrap_chown(path, uid, gid);
}

int __wrap_lchmod(const char *path, mode_t mode)
{
	(void) path;
	(void) mode;

	errno = ENOSYS;
	return -1;
}

/* getcwd() in the native libc's import doesn't resolve on the console (the
 * call jumps to a garbage address), so the working directory is tracked
 * here, through chdir() as well. The title starts in /app0. */

#define MKXP_CWD_MAX 1024

static char mkxp_cwd[MKXP_CWD_MAX] = "/app0";

int __wrap_chdir(const char *dir)
{
	char full[2 * MKXP_CWD_MAX];
	char out[MKXP_CWD_MAX];
	size_t len = 0;
	char *part;
	char *save;

	if (dir == NULL)
	{
		errno = EFAULT;
		return -1;
	}

	if (__real_chdir(dir) != 0)
		return -1;

	if (dir[0] == '/')
		snprintf(full, sizeof(full), "%s", dir);
	else
		snprintf(full, sizeof(full), "%s/%s", mkxp_cwd, dir);

	/* Resolve "." and ".." so the tracked path stays absolute and plain */
	out[0] = '\0';

	for (part = strtok_r(full, "/", &save); part != NULL;
	     part = strtok_r(NULL, "/", &save))
	{
		if (strcmp(part, ".") == 0)
			continue;

		if (strcmp(part, "..") == 0)
		{
			char *slash = strrchr(out, '/');

			if (slash != NULL)
			{
				*slash = '\0';
				len = (size_t) (slash - out);
			}

			continue;
		}

		size_t plen = strlen(part);

		if (len + 1 + plen >= sizeof(out))
			continue;

		out[len++] = '/';
		memcpy(out + len, part, plen + 1);
		len += plen;
	}

	snprintf(mkxp_cwd, sizeof(mkxp_cwd), "%s", len == 0 ? "/" : out);

	return 0;
}

char *__wrap_getcwd(char *buf, size_t size)
{
	size_t need = strlen(mkxp_cwd) + 1;

	if (buf == NULL)
	{
		if (size < need)
			size = need;

		buf = malloc(size);

		if (buf == NULL)
			return NULL;
	}
	else if (size < need)
	{
		errno = ERANGE;
		return NULL;
	}

	memcpy(buf, mkxp_cwd, need);

	return buf;
}
