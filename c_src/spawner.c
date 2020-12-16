#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static const int PIPE_READ = 0;
static const int PIPE_WRITE = 1;

/* We are choosing an exit code which is not reserved see:
 * https://www.tldp.org/LDP/abs/html/exitcodes.html. */
static const int FORK_EXEC_FAILURE = 125;

static int set_flag(int fd, int flags) {
  return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | flags);
}

static int send_io_fds(int socket, int read_fd, int write_fd) {
  struct msghdr msg = {0};
  struct cmsghdr *cmsg;
  int fds[2];
  char buf[CMSG_SPACE(2 * sizeof(int))], dup[256];
  memset(buf, '\0', sizeof(buf));
  struct iovec io = {.iov_base = &dup, .iov_len = sizeof(dup)};

  msg.msg_iov = &io;
  msg.msg_iovlen = 1;
  msg.msg_control = buf;
  msg.msg_controllen = sizeof(buf);

  cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(2 * sizeof(int));

  fds[0] = read_fd;
  fds[1] = write_fd;
  memcpy((int *)CMSG_DATA(cmsg), fds, 2 * sizeof(int));

  if (sendmsg(socket, &msg, 0) < 0) {
    printf("Failed to send message");
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

/* This is not ideal, but as of now there is no portable way to do this */

/*
static void close_all_fds() {
  int fd_limit = (int)sysconf(_SC_OPEN_MAX);
  for (int i = STDERR_FILENO + 1; i < fd_limit; i++)
    close(i);
}
*/

static void close_all(int pipes[2][2]) {
  for (int i = 0; i < 2; i++) {
    if (pipes[i][PIPE_READ] > 0)
      close(pipes[i][PIPE_READ]);
    if (pipes[i][PIPE_WRITE] > 0)
      close(pipes[i][PIPE_WRITE]);
  }
}

static int exec_process(char const *bin, char *const *args, int socket) {
  int pipes[2][2] = {{0, 0}, {0, 0}};

  if (pipe(pipes[STDIN_FILENO]) == -1 || pipe(pipes[STDOUT_FILENO]) == -1) {
    perror("[spawner] failed to create pipes");
    close_all(pipes);
    return 1;
  }

  printf("[spawner] pipe: done\r\n");

  const int r_cmdin = pipes[STDIN_FILENO][PIPE_READ];
  const int w_cmdin = pipes[STDIN_FILENO][PIPE_WRITE];

  const int r_cmdout = pipes[STDOUT_FILENO][PIPE_READ];
  const int w_cmdout = pipes[STDOUT_FILENO][PIPE_WRITE];

  if (set_flag(r_cmdin, O_CLOEXEC) < 0 || set_flag(w_cmdout, O_CLOEXEC) < 0 ||
      set_flag(w_cmdin, O_CLOEXEC | O_NONBLOCK) < 0 ||
      set_flag(r_cmdout, O_CLOEXEC | O_NONBLOCK) < 0) {
    perror("[spawner] failed to set flags for pipes");
    close_all(pipes);
    return 1;
  }

  printf("[spawner] set_flag done\r\n");

  if (send_io_fds(socket, w_cmdin, r_cmdout) != EXIT_SUCCESS) {
    perror("[spawner] failed to send fd via socket");
    close_all(pipes);
    return 1;
  }

  printf("[spawner] send_io_fds: done\r\n");

  // TODO: close all fds including socket
  // close_all_fds();

  printf("[spawner] w_cmdin: %d r_cmdout: %d\r\n", w_cmdin, w_cmdout);
  printf("[spawner] argv: %s\r\n", args[1]);

  close(w_cmdin);
  close(r_cmdout);

  close(STDIN_FILENO);
  if (dup2(r_cmdin, STDIN_FILENO) < 0) {
    perror("[spawner] failed to dup to stdin");
    _exit(FORK_EXEC_FAILURE);
  }

  close(STDOUT_FILENO);
  if (dup2(w_cmdout, STDOUT_FILENO) < 0) {
    perror("[spawner] failed to dup to stdout");
    _exit(FORK_EXEC_FAILURE);
  }

  execvp(bin, args);
  perror("[spawner] execvp(): failed");

  _exit(FORK_EXEC_FAILURE);
}

static int handle(const char *sock_path, const char *bin, char *const *args) {
  int sfd;
  struct sockaddr_un addr;

  printf("[spawner] hadle\r\n");

  sfd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (sfd == -1) {
    printf("Failed to create socket");
    return EXIT_FAILURE;
  }

  memset(&addr, 0, sizeof(struct sockaddr_un));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

  printf("[spawner] connect\r\n");

  if (connect(sfd, (struct sockaddr *)&addr, sizeof(struct sockaddr_un)) ==
      -1) {
    printf("Failed to connect to socket");
    return EXIT_FAILURE;
  }

  printf("[spawner] exec_process\r\n");

  if (exec_process(bin, args, sfd) != 0)
    return -1;

  // we never reach here
  return 0;
}

int main(int argc, const char *argv[]) {
  int status = EXIT_SUCCESS;
  const char **proc_argv;

  printf("[spawner] argc: %d\r\n", argc);

  if (argc < 3) {
    printf("[spawner] exit\r\n");
    status = EXIT_FAILURE;
  } else {
    proc_argv = malloc((argc - 2 + 1) * sizeof(char *));

    int i;
    for (i = 2; i < argc; i++)
      proc_argv[i - 2] = argv[i];

    proc_argv[i - 2] = NULL;

    printf("[spawner] exec: %s\r\n", argv[2]);
    status = handle(argv[1], argv[2], (char *const *)proc_argv);
  }

  exit(status);
}
