#include "erl_nif.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define ERL_TRUE enif_make_atom(env, "true")
#define ERL_FALSE enif_make_atom(env, "false")
#define ERL_OK(term) enif_make_tuple2(env, enif_make_atom(env, "ok"), term)
#define ERL_ERROR(term)                                                        \
  enif_make_tuple2(env, enif_make_atom(env, "error"), term)

static const int PIPE_READ = 0;
static const int PIPE_WRITE = 1;
static const int MAX_ARGUMENTS = 20;
static const int MAX_ARGUMENT_LEN = 1024;

enum exec_status {
  SUCCESS,
  PIPE_CREATE_ERROR,
  PIPE_FLAG_ERROR,
  FORK_ERROR,
  PIPE_DUP_ERROR,
  NULL_DEV_OPEN_ERROR,
};

typedef struct ExecResults {
  enum exec_status status;
  int err;
  pid_t pid;
  int pipe_in;
  int pipe_out;
} ExecResult;

static int set_flag(int fd, int flags) {
  return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | flags);
}

static void close_all(int pipes[2][2]) {
  for (int i = 0; i < 2; i++) {
    if (pipes[i][PIPE_READ] > 0)
      close(pipes[i][PIPE_READ]);
    if (pipes[i][PIPE_WRITE] > 0)
      close(pipes[i][PIPE_WRITE]);
  }
}

#define RETURN_ERROR(error)                                                    \
  do {                                                                         \
    fprintf(stderr, "error in start_proccess(), %s:%d %s\n", __FILE__,         \
            __LINE__, strerror(errno));                                        \
    result.status = error;                                                     \
    result.err = errno;                                                        \
    close_all(pipes);                                                          \
    return result;                                                             \
  } while (0);

static ExecResult start_proccess(char *args[], bool stderr_to_console) {
  ExecResult result;
  pid_t pid;
  int pipes[2][2] = {{0, 0}, {0, 0}};

  if (pipe(pipes[STDIN_FILENO]) == -1 || pipe(pipes[STDOUT_FILENO]) == -1) {
    RETURN_ERROR(PIPE_CREATE_ERROR)
  }

  if (set_flag(pipes[STDIN_FILENO][PIPE_READ], O_CLOEXEC) < 0 ||
      set_flag(pipes[STDOUT_FILENO][PIPE_WRITE], O_CLOEXEC) < 0 ||
      set_flag(pipes[STDIN_FILENO][PIPE_WRITE], O_CLOEXEC | O_NONBLOCK) < 0 ||
      set_flag(pipes[STDOUT_FILENO][PIPE_READ], O_CLOEXEC | O_NONBLOCK) < 0) {
    RETURN_ERROR(PIPE_FLAG_ERROR)
  }

  switch (pid = fork()) {
  case -1:
    RETURN_ERROR(FORK_ERROR)

  case 0:
    close(STDIN_FILENO);
    close(STDOUT_FILENO);

    if (dup2(pipes[STDIN_FILENO][PIPE_READ], STDIN_FILENO) < 0)
      RETURN_ERROR(PIPE_DUP_ERROR)
    if (dup2(pipes[STDOUT_FILENO][PIPE_WRITE], STDOUT_FILENO) < 0)
      RETURN_ERROR(PIPE_DUP_ERROR)

    if (stderr_to_console != true) {
      close(STDERR_FILENO);
      int dev_null = open("/dev/null", O_WRONLY);

      if (dev_null == -1)
        RETURN_ERROR(NULL_DEV_OPEN_ERROR);

      if (dup2(dev_null, STDERR_FILENO) < 0) {
        close(dev_null);
        RETURN_ERROR(PIPE_DUP_ERROR)
      }

      close(dev_null);
    }

    close_all(pipes);

    execvp(args[0], args);
    perror("execvp(): failed");

  default:
    close(pipes[STDIN_FILENO][PIPE_READ]);
    close(pipes[STDOUT_FILENO][PIPE_WRITE]);
    result.pid = pid;
    result.pipe_in = pipes[STDIN_FILENO][PIPE_WRITE];
    result.pipe_out = pipes[STDOUT_FILENO][PIPE_READ];
    result.status = SUCCESS;
    return result;
  }
}

/* TODO: return appropriate error instead returning generic "badarg" error */
static ERL_NIF_TERM exec_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  char tmp[MAX_ARGUMENTS][MAX_ARGUMENT_LEN + 1];
  char *exec_args[MAX_ARGUMENTS + 1];

  unsigned int args_len;
  if (enif_get_list_length(env, argv[0], &args_len) != true)
    return enif_make_badarg(env);

  if (args_len > MAX_ARGUMENTS)
    return enif_make_badarg(env);

  ERL_NIF_TERM head, tail, list = argv[0];
  for (unsigned int i = 0; i < args_len; i++) {
    if (enif_get_list_cell(env, list, &head, &tail) != true)
      return enif_make_badarg(env);

    if (enif_get_string(env, head, tmp[i], MAX_ARGUMENT_LEN,
                        ERL_NIF_LATIN1) < 1)
      return enif_make_badarg(env);
    exec_args[i] = tmp[i];
    list = tail;
  }
  exec_args[args_len] = NULL;

  bool stderr_to_console = true;
  int tmp_int;
  if (enif_get_int(env, argv[1], &tmp_int) != true)
    return enif_make_badarg(env);
  stderr_to_console = tmp_int == 1 ? true : false;

  ExecResult result = start_proccess(exec_args, stderr_to_console);
  ERL_NIF_TERM ret;

  switch (result.status) {
  case SUCCESS:
    ret = enif_make_tuple3(env, enif_make_int(env, result.pid),
                           enif_make_int(env, result.pipe_in),
                           enif_make_int(env, result.pipe_out));

    return ERL_OK(ret);
  default:
    ret = enif_make_int(env, result.err);
    return ERL_ERROR(ret);
  }
}

static ERL_NIF_TERM write_proc(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  int pipe_in;
  enif_get_int(env, argv[0], &pipe_in);

  if (argc != 2)
    enif_make_badarg(env);

  ErlNifBinary bin;
  if (enif_inspect_binary(env, argv[1], &bin) != true)
    return enif_make_badarg(env);

  int result = write(pipe_in, bin.data, bin.size);

  if (result >= 0) {
    return ERL_OK(enif_make_int(env, result));
  } else if (errno == EAGAIN) {
    return ERL_ERROR(enif_make_int(env, errno));
  } else {
    perror("write()");
    return ERL_ERROR(enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM close_pipe(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  int pipe;
  enif_get_int(env, argv[0], &pipe);

  int result = close(pipe);

  if (result == 0) {
    return enif_make_atom(env, "ok");
  } else {
    perror("close()");
    return ERL_ERROR(enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM read_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  int pipe_out, bytes;
  enif_get_int(env, argv[0], &pipe_out);
  enif_get_int(env, argv[1], &bytes);

  if (bytes > 65535 || bytes < 1)
    enif_make_badarg(env);

  char buf[bytes];
  int result = read(pipe_out, buf, sizeof(buf));

  if (result >= 0) {
    ErlNifBinary bin;
    enif_alloc_binary(result, &bin);
    memcpy(bin.data, buf, result);
    return ERL_OK(enif_make_binary(env, &bin));
  } else if (errno == EAGAIN) {
    return ERL_ERROR(enif_make_int(env, errno));
  } else {
    perror("read()");
    return ERL_ERROR(enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM is_alive(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  int pid;
  enif_get_int(env, argv[0], &pid);

  int result = kill(pid, 0);

  if (result == 0) {
    return ERL_TRUE;
  } else {
    return ERL_FALSE;
  }
}

static ERL_NIF_TERM terminate_proc(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  int pid;
  enif_get_int(env, argv[0], &pid);
  return enif_make_int(env, kill(pid, SIGTERM));
}

static ERL_NIF_TERM kill_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  int pid;
  enif_get_int(env, argv[0], &pid);
  return enif_make_int(env, kill(pid, SIGKILL));
}

static ERL_NIF_TERM wait_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  int pid, status;
  enif_get_int(env, argv[0], &pid);

  int wpid = waitpid(pid, &status, WNOHANG);
  if (wpid != pid) {
    perror("waitpid()");
  }

  return enif_make_tuple2(env, enif_make_int(env, wpid),
                          enif_make_int(env, status));
}

static ErlNifFunc nif_funcs[] = {
    {"exec_proc", 2, exec_proc, 0},           {"write_proc", 2, write_proc, 0},
    {"read_proc", 2, read_proc, 0},           {"close_pipe", 1, close_pipe, 0},
    {"terminate_proc", 1, terminate_proc, 0}, {"wait_proc", 1, wait_proc, 0},
    {"kill_proc", 1, kill_proc, 0},           {"is_alive", 1, is_alive, 0},
};

ERL_NIF_INIT(Elixir.Exile.ProcessHelper, nif_funcs, NULL, NULL, NULL, NULL)
