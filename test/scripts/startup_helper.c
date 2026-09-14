#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 5)
    return 1;

  const char *mode = argv[4];
  if (strcmp(mode, "exit") == 0)
    return 23;

  if (strcmp(mode, "no_connect") != 0) {
    int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", argv[1]);
    if (connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) < 0)
      return 2;

    if (strcmp(mode, "no_fds") == 0 && send(socket_fd, "x", 1, 0) != 1)
      return 3;
  }

  /* Stay alive so a timeout cannot be mistaken for a helper exit. */
  for (;;)
    pause();
}
