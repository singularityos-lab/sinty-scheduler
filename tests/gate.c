#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define WRITE_BYTES (5ULL << 30)
#define MAX_SAMPLES 200000

static double samples[MAX_SAMPLES];

static double now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static void die(const char *what)
{
	printf("GATE_ERROR %s: %s\n", what, strerror(errno));
	fflush(stdout);
	reboot(RB_POWER_OFF);
	_exit(1);
}

static void put(const char *path, const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	int fd, len;

	va_start(ap, fmt);
	len = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	fd = open(path, O_WRONLY);
	if (fd < 0 || write(fd, buf, len) != len)
		die(path);
	close(fd);
}

static void cat(const char *path)
{
	char buf[4096];
	int fd = open(path, O_RDONLY);
	ssize_t got;

	if (fd < 0)
		return;
	while ((got = read(fd, buf, sizeof(buf))) > 0)
		fwrite(buf, 1, got, stdout);
	close(fd);
}

static void run(char *const argv[])
{
	pid_t pid = fork();
	int status;

	if (pid == 0) {
		execv(argv[0], argv);
		_exit(127);
	}
	waitpid(pid, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status))
		die(argv[0]);
}

static int cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return (x > y) - (x < y);
}

static void writer(void)
{
	static char block[1 << 20];
	uint64_t done = 0;
	int fd;

	put("/sys/fs/cgroup/bg/cgroup.procs", "%d", getpid());
	fd = open("/mnt/big", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		die("big");
	memset(block, 0x5a, sizeof(block));
	while (done < WRITE_BYTES) {
		if (write(fd, block, sizeof(block)) != sizeof(block))
			die("write");
		done += sizeof(block);
	}
	fsync(fd);
	close(fd);
	_exit(0);
}

static void report(const char *name, const char *what, int n)
{
	if (!n) {
		printf("GATE %s %s none\n", name, what);
		return;
	}
	qsort(samples, n, sizeof(double), cmp);
	printf("GATE %s %s n=%d p50=%.2fms p99=%.2fms max=%.2fms\n", name, what, n,
	       samples[n / 2], samples[(n * 99) / 100], samples[n - 1]);
}

static pid_t stall_watch(pid_t target)
{
	char path[64];
	pid_t pid = fork();

	if (pid)
		return pid;
	snprintf(path, sizeof(path), "/proc/%d/stack", target);
	for (;;) {
		char stack[2048];
		int fd = open(path, O_RDONLY);
		ssize_t got;

		usleep(1000000);
		if (fd < 0)
			_exit(0);
		got = read(fd, stack, sizeof(stack) - 1);
		close(fd);
		if (got > 0 && !strstr(stack, "hrtimer_nanosleep")) {
			stack[got] = 0;
			printf("GATE_STACK\n%s", stack);
		}
	}
}

static void scenario(const char *name, const char *scheduler, const char *dirty_bytes,
		     const char *background_bytes)
{
	static char page[4096];
	int status, fsyncs = 0, reads = 0, fd;
	double start, wrote;
	static double read_samples[MAX_SAMPLES];
	pid_t pid, watch;

	char *mkfs[] = { "/mkfs.f2fs", "-f", "-q", "/dev/vda", NULL };

	run(mkfs);
	if (mount("/dev/vda", "/mnt", "f2fs", 0, NULL))
		die("mount");
	if (dirty_bytes) {
		put("/proc/sys/vm/dirty_background_bytes", "%s", background_bytes);
		put("/proc/sys/vm/dirty_bytes", "%s", dirty_bytes);
	} else {
		put("/proc/sys/vm/dirty_background_ratio", "10");
		put("/proc/sys/vm/dirty_ratio", "20");
	}
	put("/sys/block/vda/queue/scheduler", "%s", scheduler);
	if (!strcmp(scheduler, "sinty")) {
		put("/sys/block/vda/queue/max_sectors_kb", "512");
		put("/sys/kernel/sinty_scheduler/classes", "interactive /fg");
		put("/sys/kernel/sinty_scheduler/classes", "background /bg");
	}
	fd = open("/mnt/probe", O_RDWR | O_CREAT, 0644);
	if (fd < 0 || write(fd, page, sizeof(page)) != sizeof(page))
		die("probe");
	fsync(fd);
	for (fsyncs = 0; fsyncs < 200; fsyncs++) {
		double t = now_ms();

		if (pwrite(fd, page, sizeof(page), 0) != sizeof(page) || fsync(fd))
			die("fsync");
		samples[fsyncs] = now_ms() - t;
		usleep(5000);
	}
	report(name, "idle_fsync", fsyncs);
	fsyncs = 0;
	start = now_ms();
	pid = fork();
	if (pid == 0)
		writer();
	watch = stall_watch(getpid());
	wrote = 0;
	for (;;) {
		double t = now_ms();

		if (pwrite(fd, page, sizeof(page), 0) != sizeof(page) || fsync(fd))
			die("fsync");
		if (fsyncs < MAX_SAMPLES)
			samples[fsyncs++] = now_ms() - t;
		posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
		t = now_ms();
		if (pread(fd, page, sizeof(page), 0) != sizeof(page))
			die("read");
		if (reads < MAX_SAMPLES)
			read_samples[reads++] = now_ms() - t;
		usleep(20000);
		if (waitpid(pid, &status, WNOHANG) == pid) {
			wrote = now_ms() - start;
			break;
		}
	}
	kill(watch, SIGKILL);
	waitpid(watch, &status, 0);
	report(name, "fsync", fsyncs);
	memcpy(samples, read_samples, reads * sizeof(double));
	report(name, "read", reads);
	printf("GATE %s writer_ms=%.0f writer_mb_s=%.0f\n", name, wrote, (WRITE_BYTES >> 20) / (wrote / 1000));
	if (!strcmp(scheduler, "sinty")) {
		cat("/sys/block/vda/queue/iosched/stats");
		put("/sys/kernel/sinty_scheduler/classes", "clear");
	}
	fflush(stdout);
	close(fd);
	put("/sys/block/vda/queue/scheduler", "none");
	if (umount("/mnt"))
		die("umount");
}

static long long stat_value(const char *key)
{
	char buf[4096], *at;
	int fd = open("/sys/block/vda/queue/iosched/stats", O_RDONLY);
	ssize_t got;
	size_t len = strlen(key);

	if (fd < 0)
		die("stats");
	got = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (got <= 0)
		die("stats");
	buf[got] = '\0';
	for (at = buf; (at = strstr(at, key)); at += len) {
		if ((at == buf || at[-1] == '\n') && at[len] == ' ')
			return atoll(at + len + 1);
	}
	return -1;
}

static long long synced_by(const char *group, const char *file)
{
	static char page[4096];
	long long before = stat_value("background_ios");
	int status, fd, i;
	pid_t pid = fork();

	if (pid == 0) {
		char path[64];

		snprintf(path, sizeof(path), "/sys/fs/cgroup/%s/cgroup.procs", group);
		put(path, "%d", getpid());
		fd = open(file, O_RDWR | O_CREAT, 0644);
		if (fd < 0)
			die(file);
		for (i = 0; i < 64; i++) {
			memset(page, i, sizeof(page));
			if (pwrite(fd, page, sizeof(page), (off_t)i * 1048576) != sizeof(page) || fsync(fd))
				die("fsync");
		}
		close(fd);
		_exit(0);
	}
	waitpid(pid, &status, 0);
	return stat_value("background_ios") - before;
}

static void classes(void)
{
	char *mkfs[] = { "/mkfs.f2fs", "-f", "-q", "/dev/vda", NULL };
	long long fg, nf, hv;
	int fd;

	run(mkfs);
	if (mount("/dev/vda", "/mnt", "f2fs", 0, NULL))
		die("mount");
	mkdir("/sys/fs/cgroup/nf", 0755);
	mkdir("/sys/fs/cgroup/hv", 0755);
	put("/sys/block/vda/queue/scheduler", "sinty");
	put("/sys/kernel/sinty_scheduler/classes", "interactive /fg");
	put("/sys/kernel/sinty_scheduler/classes", "normal /nf");
	put("/sys/kernel/sinty_scheduler/classes", "interactive,fsync /hv");
	fd = open("/sys/kernel/sinty_scheduler/classes", O_WRONLY);
	printf("GATE_CLASS bogus_flag_refused=%d\n", fd >= 0 && write(fd, "normal,bogus /nf", 16) < 0);
	close(fd);
	sync();
	fg = synced_by("fg", "/mnt/fg");
	nf = synced_by("nf", "/mnt/nf");
	hv = synced_by("hv", "/mnt/hv");
	printf("GATE_CLASS focused=%lld unfocused=%lld fsync_heavy=%lld\n", fg, nf, hv);
	printf("GATE_CLASS verdict=%s\n", fg < 16 && nf >= 64 && hv >= 64 ? "pass" : "fail");
	put("/sys/kernel/sinty_scheduler/classes", "clear");
	put("/sys/block/vda/queue/scheduler", "none");
	umount("/mnt");
}

int main(void)
{
	int fd;

	setvbuf(stdout, NULL, _IOLBF, 0);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, NULL);
	fd = open("/sinty_scheduler.ko", O_RDONLY);
	if (fd < 0 || syscall(SYS_finit_module, fd, "", 0))
		die("module");
	close(fd);
	put("/sys/fs/cgroup/cgroup.subtree_control", "+io +memory");
	mkdir("/sys/fs/cgroup/fg", 0755);
	mkdir("/sys/fs/cgroup/bg", 0755);
	put("/sys/fs/cgroup/fg/cgroup.procs", "%d", getpid());
	if (getenv("GATE_CLASSES")) {
		classes();
		printf("GATE_DONE\n");
		fflush(stdout);
		sync();
		reboot(RB_POWER_OFF);
		return 0;
	}
	if (!getenv("GATE_ONLY")) {
		scenario("before", "none", NULL, NULL);
		scenario("writeback", "none", "268435456", "67108864");
	}
	scenario("sinty", "sinty", "268435456", "67108864");
	printf("GATE_DONE\n");
	fflush(stdout);
	sync();
	reboot(RB_POWER_OFF);
	return 0;
}
