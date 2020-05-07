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
#define ERL_UNDEFINED enif_make_atom(env, "undefined")
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

struct ExilePriv {
  /* ERL_NIF_TERM atom_ok; */
  /* ERL_NIF_TERM atom_undefined; */

  ErlNifResourceType *rt;
  /* void *read_resource; */
  /* void *write_resource; */
};

static void rt_dtor(ErlNifEnv *env, void *obj) {
  printf("----- rt_dtor called\n");
}

static void rt_stop(ErlNifEnv *env, void *obj, int fd, int is_direct_call) {
  printf("----- rt_stop called\n");
}

static void rt_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                    ErlNifMonitor *monitor) {
  printf("----- rt_down called\n");
}

static ErlNifResourceTypeInit rt_init = {rt_dtor, rt_stop, rt_down};

typedef struct ExecContext {
  int cmd_input_fd;
  int cmd_output_fd;
  pid_t pid;
} ExecContext;

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

    if (enif_get_string(env, head, tmp[i], MAX_ARGUMENT_LEN, ERL_NIF_LATIN1) <
        1)
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

  struct ExilePriv *data = enif_priv_data(env);
  ExecResult result = start_proccess(exec_args, stderr_to_console);
  ERL_NIF_TERM ret;
  ExecContext *ctx = NULL;

  switch (result.status) {
  case SUCCESS:
    ctx = enif_alloc_resource(data->rt, sizeof(ExecContext));
    ctx->cmd_input_fd = result.pipe_in;
    ctx->cmd_output_fd = result.pipe_out;
    ctx->pid = result.pid;

    printf("cmd_in: %d cmd_out: %d pid: %d\n", result.pipe_in, result.pipe_out,
           result.pid);

    // TODO: exit the command gracefully when resource is released by GC
    /* enif_release_resource(ctx); */

    return ERL_OK(enif_make_resource(env, ctx));
  default:
    ret = enif_make_int(env, result.err);
    return ERL_ERROR(ret);
  }
}

static int select_write(ErlNifEnv *env, ExecContext *ctx) {
  int retval = enif_select(env, ctx->cmd_input_fd, ERL_NIF_SELECT_WRITE, ctx,
                           NULL, ERL_UNDEFINED);
  if (retval != 0)
    perror("select_write()");
  return retval;
}

static ERL_NIF_TERM write_proc(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  if (argc != 2)
    enif_make_badarg(env);

  struct ExilePriv *data = enif_priv_data(env);
  ExecContext *ctx = NULL;
  if (enif_get_resource(env, argv[0], data->rt, (void **)&ctx) == false) {
    return enif_make_badarg(env);
  }

  ErlNifBinary bin;
  if (enif_inspect_binary(env, argv[1], &bin) != true)
    return enif_make_badarg(env);

  unsigned int result = write(ctx->cmd_input_fd, bin.data, bin.size);

  // TODO: cleanup
  if (result >= bin.size) { // request completely satisfied
    return ERL_OK(enif_make_int(env, result));
  } else if (result >= 0) { // request partially satisfied
    int retval = select_write(env, ctx);
    if (retval != 0)
      return ERL_ERROR(enif_make_int(env, retval));
    return ERL_OK(enif_make_int(env, result));
  } else if (errno == EAGAIN) { // busy
    int retval = select_write(env, ctx);
    if (retval != 0)
      return ERL_ERROR(enif_make_int(env, retval));
    return ERL_ERROR(enif_make_int(env, EAGAIN));
  } else { // Error
    perror("write()");
    return ERL_ERROR(enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM close_pipe(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  struct ExilePriv *data = enif_priv_data(env);
  ExecContext *ctx = NULL;
  if (enif_get_resource(env, argv[0], data->rt, (void **)&ctx) == false) {
    return enif_make_badarg(env);
  }

  int kind;
  enif_get_int(env, argv[1], &kind);

  int result;
  switch (kind) {
  case 0:
    result = close(ctx->cmd_input_fd);
    break;
  case 1:
    result = close(ctx->cmd_output_fd);
    break;
  default:
    return enif_make_badarg(env);
  }

  if (result == 0) {
    return enif_make_atom(env, "ok");
  } else {
    perror("close()");
    return ERL_ERROR(enif_make_int(env, errno));
  }
}

static int select_read(ErlNifEnv *env, ExecContext *ctx) {
  int retval = enif_select(env, ctx->cmd_output_fd, ERL_NIF_SELECT_READ, ctx,
                           NULL, ERL_UNDEFINED);
  if (retval != 0)
    perror("select_read()");
  return retval;
}

static ERL_NIF_TERM read_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  if (argc != 2)
    enif_make_badarg(env);

  struct ExilePriv *data = enif_priv_data(env);
  ExecContext *ctx = NULL;
  if (enif_get_resource(env, argv[0], data->rt, (void **)&ctx) == false) {
    return enif_make_badarg(env);
  }

  bool is_buffered = true;
  int size;
  enif_get_int(env, argv[1], &size);

  if (size == -1) {
    size = 65535;
    is_buffered = false;
  } else if (size > 65535 || size < 1) {
    enif_make_badarg(env);
  }

  unsigned char buf[size];
  int result = read(ctx->cmd_output_fd, buf, sizeof(buf));

  ERL_NIF_TERM bin_term;
  if (result >= 0) {
    ErlNifBinary bin;
    enif_alloc_binary(result, &bin);
    // TODO: we should use binary when reading itself instead of allocating
    // again
    memcpy(bin.data, buf, result);
    bin_term = enif_make_binary(env, &bin);
  }

  // TODO: cleanup
  if (result >= size ||
      (is_buffered == false && result >= 0)) { // request completely satisfied
    return ERL_OK(bin_term);
  } else if (result > 0) { // request partially satisfied
    int retval = select_read(env, ctx);
    if (retval != 0)
      return ERL_ERROR(enif_make_int(env, retval));
    return ERL_OK(bin_term);
  } else if (result == 0) { // EOF
    return ERL_OK(bin_term);
  } else if (errno == EAGAIN) { // busy
    int retval = select_read(env, ctx);
    if (retval != 0)
      return ERL_ERROR(enif_make_int(env, retval));
    return ERL_ERROR(enif_make_int(env, EAGAIN));
  } else { // Error
    perror("read()");
    return ERL_ERROR(enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM is_alive(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  struct ExilePriv *data = enif_priv_data(env);
  ExecContext *ctx = NULL;
  if (enif_get_resource(env, argv[0], data->rt, (void **)&ctx) == false) {
    return enif_make_badarg(env);
  }

  int result = kill(ctx->pid, 0);

  if (result == 0) {
    return ERL_TRUE;
  } else {
    return ERL_FALSE;
  }
}

static ERL_NIF_TERM terminate_proc(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  struct ExilePriv *data = enif_priv_data(env);
  ExecContext *ctx = NULL;
  if (enif_get_resource(env, argv[0], data->rt, (void **)&ctx) == false) {
    return enif_make_badarg(env);
  }
  return enif_make_int(env, kill(ctx->pid, SIGTERM));
}

static ERL_NIF_TERM kill_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  struct ExilePriv *data = enif_priv_data(env);
  ExecContext *ctx = NULL;
  if (enif_get_resource(env, argv[0], data->rt, (void **)&ctx) == false) {
    return enif_make_badarg(env);
  }
  return enif_make_int(env, kill(ctx->pid, SIGKILL));
}

static ERL_NIF_TERM wait_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  struct ExilePriv *data = enif_priv_data(env);
  ExecContext *ctx = NULL;
  if (enif_get_resource(env, argv[0], data->rt, (void **)&ctx) == false) {
    return enif_make_badarg(env);
  }

  int status;
  int wpid = waitpid(ctx->pid, &status, WNOHANG);

  if (wpid == ctx->pid) {
    return ERL_OK(enif_make_int(env, status));
  } else {
    perror("waitpid()");
    ERL_NIF_TERM term = enif_make_tuple2(env, enif_make_int(env, wpid),
                                         enif_make_int(env, status));
    return ERL_ERROR(term);
  }
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM load_info) {
  struct ExilePriv *data = enif_alloc(sizeof(struct ExilePriv));
  if (!data)
    return 1;

  /* data->atom_ok = enif_make_atom(env, "ok"); */
  /* data->atom_undefined = enif_make_atom(env, "undefined"); */

  data->rt = enif_open_resource_type_x(env, "exile_resource", &rt_init,
                                       ERL_NIF_RT_CREATE, NULL);

  *priv = (void *)data;

  return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"exec_proc", 2, exec_proc, 0},           {"write_proc", 2, write_proc, 0},
    {"read_proc", 2, read_proc, 0},           {"close_pipe", 2, close_pipe, 0},
    {"terminate_proc", 1, terminate_proc, 0}, {"wait_proc", 1, wait_proc, 0},
    {"kill_proc", 1, kill_proc, 0},           {"is_alive", 1, is_alive, 0},
};

ERL_NIF_INIT(Elixir.Exile.ProcessHelper, nif_funcs, &load, NULL, NULL, NULL)
