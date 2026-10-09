/*
 * POSIX functions missing from the PS5 payload SDK's libc that Ruby
 * references unconditionally.
 */

#include <stdarg.h>
#include <stddef.h>
#include <unistd.h>

#define MAX_EXEC_ARGS 64

extern char **environ;

/* Collect the NULL-terminated variadic argument list into argv.
 * Returns -1 if it does not fit. */
static int collect_args(const char *arg0, va_list ap, char **argv)
{
	int i = 0;

	argv[i++] = (char *) arg0;

	while (argv[i - 1] != NULL)
	{
		if (i == MAX_EXEC_ARGS)
			return -1;

		argv[i++] = va_arg(ap, char *);
	}

	return 0;
}

int execl(const char *path, const char *arg0, ...)
{
	char *argv[MAX_EXEC_ARGS];
	va_list ap;
	int r;

	va_start(ap, arg0);
	r = collect_args(arg0, ap, argv);
	va_end(ap);

	if (r < 0)
		return -1;

	return execve(path, argv, environ);
}

int execle(const char *path, const char *arg0, ...)
{
	char *argv[MAX_EXEC_ARGS];
	char **envp;
	va_list ap;
	int r;

	va_start(ap, arg0);
	r = collect_args(arg0, ap, argv);
	envp = (r < 0) ? NULL : va_arg(ap, char **);
	va_end(ap);

	if (r < 0)
		return -1;

	return execve(path, argv, envp);
}

/* There is no passwd database to close */
void endpwent(void)
{
}
