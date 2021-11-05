#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

// these definitions are Linux only at the moment
#ifndef CMSG_LEN
socklen_t CMSG_LEN(size_t len) {
  return (CMSG_DATA((struct cmsghdr *)NULL) - (unsigned char *)NULL) + len;
}
#endif

#ifndef CMSG_SPACE
socklen_t CMSG_SPACE(size_t len) {
  struct msghdr msg;
  struct cmsghdr cmsg;
  msg.msg_control = &cmsg;
  msg.msg_controllen =
      ~0; /* To maximize the chance that CMSG_NXTHDR won't return NULL */
  cmsg.cmsg_len = CMSG_LEN(len);
  return (unsigned char *)CMSG_NXTHDR(&msg, &cmsg) - (unsigned char *)&cmsg;
}
#endif

// #define DEBUG

#ifdef DEBUG
#define debug(...)                                                             \
  do {                                                                         \
    fprintf(stderr, "%s:%d\t(fn \"%s\")  - ", __FILE__, __LINE__, __func__);   \
    fprintf(stderr, __VA_ARGS__);                                              \
    fprintf(stderr, "\n");                                                     \
  } while (0)
#else
#define debug(...)
#endif

#define error(...)                                                             \
  do {                                                                         \
    fprintf(stderr, "%s:%d\t(fn: \"%s\")  - ", __FILE__, __LINE__, __func__);  \
    fprintf(stderr, __VA_ARGS__);                                              \
    fprintf(stderr, "\n");                                                     \
  } while (0)

static const int PIPE_READ = 0;
static const int PIPE_WRITE = 1;

/* We are choosing an exit code which is not reserved see:
 * https://www.tldp.org/LDP/abs/html/exitcodes.html. */
static const int FORK_EXEC_FAILURE = 125;

static int set_flag(int fd, int flags) {
  return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | flags);
}

static int send_io_fds(int socket, int stdin_fd, int stdout_fd, int stderr_fd) {
  struct msghdr msg = {0};
  struct cmsghdr *cmsg;
  int fds[3];
  char buf[CMSG_SPACE(3 * sizeof(int))];
  char dup[256];
  struct iovec io;

  memset(buf, '\0', sizeof(buf));

  io.iov_base = &dup;
  io.iov_len = sizeof(dup);

  msg.msg_iov = &io;
  msg.msg_iovlen = 1;
  msg.msg_control = buf;
  msg.msg_controllen = sizeof(buf);

  cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(3 * sizeof(int));

  fds[0] = stdin_fd;
  fds[1] = stdout_fd;
  fds[2] = stderr_fd;

  debug("stdout: %d, stderr: %d", stdout_fd, stderr_fd);

  memcpy((int *)CMSG_DATA(cmsg), fds, 3 * sizeof(int));

  if (sendmsg(socket, &msg, 0) < 0) {
    debug("Failed to send message");
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

static void close_pipes(int pipes[3][2]) {
  for (int i = 0; i < 3; i++) {
    if (pipes[i][PIPE_READ] > 0)
      close(pipes[i][PIPE_READ]);
    if (pipes[i][PIPE_WRITE] > 0)
      close(pipes[i][PIPE_WRITE]);
  }
}

static int exec_process(char const *bin, char *const *args, int socket,
                        bool use_stderr) {
  int pipes[3][2] = {{0, 0}, {0, 0}, {0, 0}};
  int r_cmdin, w_cmdin, r_cmdout, w_cmdout, r_cmderr, w_cmderr;
  int i;

  if (pipe(pipes[STDIN_FILENO]) == -1 || pipe(pipes[STDOUT_FILENO]) == -1 ||
      pipe(pipes[STDERR_FILENO]) == -1) {
    perror("[spawner] failed to create pipes");
    close_pipes(pipes);
    return 1;
  }

  debug("created pipes");

  r_cmdin = pipes[STDIN_FILENO][PIPE_READ];
  w_cmdin = pipes[STDIN_FILENO][PIPE_WRITE];

  r_cmdout = pipes[STDOUT_FILENO][PIPE_READ];
  w_cmdout = pipes[STDOUT_FILENO][PIPE_WRITE];

  r_cmderr = pipes[STDERR_FILENO][PIPE_READ];
  w_cmderr = pipes[STDERR_FILENO][PIPE_WRITE];

  if (set_flag(r_cmdin, O_CLOEXEC) < 0 || set_flag(w_cmdout, O_CLOEXEC) < 0 ||
      set_flag(w_cmderr, O_CLOEXEC) < 0 ||
      set_flag(w_cmdin, O_CLOEXEC | O_NONBLOCK) < 0 ||
      set_flag(r_cmdout, O_CLOEXEC | O_NONBLOCK) < 0 ||
      set_flag(r_cmderr, O_CLOEXEC | O_NONBLOCK) < 0) {
    perror("[spawner] failed to set flags for pipes");
    close_pipes(pipes);
    return 1;
  }

  debug("set fd flags to pipes");

  if (send_io_fds(socket, w_cmdin, r_cmdout, r_cmderr) != EXIT_SUCCESS) {
    perror("[spawner] failed to send fd via socket");
    close_pipes(pipes);
    return 1;
  }

  debug("sent fds over UDS");

  close(STDIN_FILENO);
  close(w_cmdin);
  if (dup2(r_cmdin, STDIN_FILENO) < 0) {
    perror("[spawner] failed to dup to stdin");
    _exit(FORK_EXEC_FAILURE);
  }

  close(STDOUT_FILENO);
  close(r_cmdout);
  if (dup2(w_cmdout, STDOUT_FILENO) < 0) {
    perror("[spawner] failed to dup to stdout");
    _exit(FORK_EXEC_FAILURE);
  }

  if (use_stderr) {
    close(STDERR_FILENO);
    close(r_cmderr);
    if (dup2(w_cmderr, STDERR_FILENO) < 0) {
      perror("[spawner] failed to dup to stderr");
      _exit(FORK_EXEC_FAILURE);
    }
  } else {
    close(r_cmderr);
    close(w_cmderr);
  }

  /* Close all non-standard io fds. Not closing STDERR */
  for (i = STDERR_FILENO + 1; i < sysconf(_SC_OPEN_MAX); i++)
    close(i);

  debug("exec %s", bin);

  execvp(bin, args);
  perror("[spawner] execvp(): failed");

  _exit(FORK_EXEC_FAILURE);
}

static int spawn(const char *socket_path, const char *use_stderr_str,
                 const char *bin, char *const *args) {
  int socket_fd;
  struct sockaddr_un socket_addr;
  bool use_stderr;

  if (strcmp(use_stderr_str, "true") == 0) {
    use_stderr = true;
  } else {
    use_stderr = false;
  }

  socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);

  if (socket_fd == -1) {
    debug("Failed to create socket");
    return EXIT_FAILURE;
  }

  debug("created domain socket");

  memset(&socket_addr, 0, sizeof(struct sockaddr_un));
  socket_addr.sun_family = AF_UNIX;
  strncpy(socket_addr.sun_path, socket_path, sizeof(socket_addr.sun_path) - 1);

  if (connect(socket_fd, (struct sockaddr *)&socket_addr,
              sizeof(struct sockaddr_un)) == -1) {
    debug("Failed to connect to socket");
    return EXIT_FAILURE;
  }

  debug("connected to exile");

  if (exec_process(bin, args, socket_fd, use_stderr) != 0)
    return EXIT_FAILURE;

  // we should never reach here
  return EXIT_SUCCESS;
}

int main(int argc, const char *argv[]) {
  int status, i;
  const char **exec_argv;

  if (argc < 4) {
    debug("expected at least 3 arguments, passed %d", argc);
    status = EXIT_FAILURE;
  } else {
    exec_argv = malloc((argc - 3 + 1) * sizeof(char *));

    for (i = 3; i < argc; i++)
      exec_argv[i - 3] = argv[i];

    exec_argv[i - 3] = NULL;

    debug("socket path: %s use_stderr: %s bin: %s", argv[1], argv[2], argv[3]);
    status = spawn(argv[1], argv[2], argv[3], (char *const *)exec_argv);
  }

  exit(status);
}
