#include "erl_nif.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

//#define DEBUG

#ifdef DEBUG
#define debug(...)                                                             \
  do {                                                                         \
    enif_fprintf(stderr, __VA_ARGS__);                                         \
    enif_fprintf(stderr, "\n");                                                \
  } while (0)
#define start_timing() ErlNifTime __start = enif_monotonic_time(ERL_NIF_USEC)
#define elapsed_microseconds() (enif_monotonic_time(ERL_NIF_USEC) - __start)
#else
#define debug(...)
#define start_timing()
#define elapsed_microseconds() 0
#endif

#define error(...)                                                             \
  do {                                                                         \
    enif_fprintf(stderr, __VA_ARGS__);                                         \
    enif_fprintf(stderr, "\n");                                                \
  } while (0)

#define ERL_TRUE enif_make_atom(env, "true")
#define ERL_FALSE enif_make_atom(env, "false")
#define ERL_UNDEFINED enif_make_atom(env, "undefined")

#define MAKE_OK(term) enif_make_tuple2(env, ATOM_OK, term)
#define MAKE_ERROR(term) enif_make_tuple2(env, ATOM_ERROR, term)

#define GET_CTX(env, arg, ctx)                                                 \
  do {                                                                         \
    ExilePriv *data = enif_priv_data(env);                                     \
    if (enif_get_resource(env, arg, data->rt, (void **)&ctx) == false) {       \
      return MAKE_ERROR(ATOM_INVALID_CTX);                                     \
    }                                                                          \
  } while (0);

static const int PIPE_READ   = 0;
static const int PIPE_WRITE  = 1;
static const int PIPE_CLOSED = -1;
static const int CMD_EXIT    = -1;
static const int MAX_ARGUMENTS    = 20;
static const int MAX_ARGUMENT_LEN = 1024;

static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_UNDEFINED;
static ERL_NIF_TERM ATOM_INVALID_CTX;
static ERL_NIF_TERM ATOM_PIPE_CLOSED;

enum exec_status {
  SUCCESS,
  PIPE_CREATE_ERROR,
  PIPE_FLAG_ERROR,
  FORK_ERROR,
  PIPE_DUP_ERROR,
  NULL_DEV_OPEN_ERROR,
};

typedef struct ExilePriv {
  ErlNifResourceType *rt;
} ExilePriv;

typedef struct ExecContext {
  int cmd_input_fd;
  int cmd_output_fd;
  int cmd_exit_status;
  pid_t pid;
} ExecContext;

typedef struct ExecResult {
  enum exec_status status;
  int err;
  ExecContext context;
} ExecResult;

static void rt_dtor(ErlNifEnv *env, void *obj) {
  debug("Exile rt_dtor called\n");
}

static void rt_stop(ErlNifEnv *env, void *obj, int fd, int is_direct_call) {
  debug("Exile rt_stop called\n");
}

static void rt_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                    ErlNifMonitor *monitor) {
  debug("Exile rt_down called\n");
}

static ErlNifResourceTypeInit rt_init = {rt_dtor, rt_stop, rt_down};

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

#define RETURN_ERROR(__err)                                                    \
  do {                                                                         \
    result.err = errno;                                                        \
    result.status = __err;                                                     \
    close_all(pipes);                                                          \
    error("error in start_proccess(), %s:%d %s", __FILE__, __LINE__,           \
          strerror(errno));                                                    \
    return result;                                                             \
  } while (0);

static ExecResult start_proccess(char *args[], bool stderr_to_console) {
  ExecResult result;
  pid_t pid;
  int pipes[2][2] = {{0, 0}, {0, 0}};

  if (pipe(pipes[STDIN_FILENO]) == -1 || pipe(pipes[STDOUT_FILENO]) == -1) {
    debug("failed create pipes");
    RETURN_ERROR(PIPE_CREATE_ERROR)
  }

  const int r_cmdin = pipes[STDIN_FILENO][PIPE_READ];
  const int w_cmdin = pipes[STDIN_FILENO][PIPE_WRITE];

  const int r_cmdout = pipes[STDOUT_FILENO][PIPE_READ];
  const int w_cmdout = pipes[STDOUT_FILENO][PIPE_WRITE];

  if (set_flag(r_cmdin, O_CLOEXEC) < 0 || set_flag(w_cmdout, O_CLOEXEC) < 0 ||
      set_flag(w_cmdin, O_CLOEXEC | O_NONBLOCK) < 0 ||
      set_flag(r_cmdout, O_CLOEXEC | O_NONBLOCK) < 0) {
    debug("failed to set flag for pipes");
    RETURN_ERROR(PIPE_FLAG_ERROR)
  }

  switch (pid = fork()) {

  case -1:
    debug("failed to fork");
    RETURN_ERROR(FORK_ERROR)

  case 0: // child

    // close default stdio fd
    close(STDIN_FILENO);
    close(STDOUT_FILENO);

    if (dup2(r_cmdin, STDIN_FILENO) < 0) {
      debug("failed dup command input pipe to stdin");
      RETURN_ERROR(PIPE_DUP_ERROR)
    }
    if (dup2(w_cmdout, STDOUT_FILENO) < 0) {
      debug("failed dup command output pipe to stdout");
      RETURN_ERROR(PIPE_DUP_ERROR)
    }

    if (stderr_to_console != true) {
      close(STDERR_FILENO);
      int dev_null = open("/dev/null", O_WRONLY);

      if (dev_null == -1) {
        RETURN_ERROR(NULL_DEV_OPEN_ERROR);
      }

      if (dup2(dev_null, STDERR_FILENO) < 0) {
        debug("failed dup command error pipe to stderr");
        close(dev_null);
        RETURN_ERROR(PIPE_DUP_ERROR)
      }

      close(dev_null);
    }

    close_all(pipes);

    execvp(args[0], args);
    perror("execvp(): failed");

  default: // parent
    // close file descriptors used by child
    close(r_cmdin);
    close(w_cmdout);

    result.context.pid = pid;
    result.context.cmd_input_fd = w_cmdin;
    result.context.cmd_output_fd = r_cmdout;
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
  ExecContext *ctx = NULL;
  ERL_NIF_TERM term;

  switch (result.status) {
  case SUCCESS:
    ctx = enif_alloc_resource(data->rt, sizeof(ExecContext));
    ctx->cmd_input_fd = result.context.cmd_input_fd;
    ctx->cmd_output_fd = result.context.cmd_output_fd;
    ctx->pid = result.context.pid;

    debug("pid: %d  cmd_in_fd: %d  cmd_out_fd: %d", ctx->pid, ctx->cmd_input_fd,
          ctx->cmd_output_fd);

    term = enif_make_resource(env, ctx);

    // resource should be collected beam GC when there are no more references
    enif_release_resource(ctx);

    return MAKE_OK(term);
  default:
    return MAKE_ERROR(enif_make_int(env, result.err));
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

  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->cmd_input_fd == PIPE_CLOSED)
    return MAKE_ERROR(ATOM_PIPE_CLOSED);

  ErlNifBinary bin;
  if (enif_inspect_binary(env, argv[1], &bin) != true)
    return enif_make_badarg(env);

  unsigned int result = write(ctx->cmd_input_fd, bin.data, bin.size);

  // TODO: cleanup
  if (result >= bin.size) { // request completely satisfied
    return MAKE_OK(enif_make_int(env, result));
  } else if (result >= 0) { // request partially satisfied
    int retval = select_write(env, ctx);
    if (retval != 0)
      return MAKE_ERROR(enif_make_int(env, retval));
    return MAKE_OK(enif_make_int(env, result));
  } else if (errno == EAGAIN) { // busy
    int retval = select_write(env, ctx);
    if (retval != 0)
      return MAKE_ERROR(enif_make_int(env, retval));
    return MAKE_ERROR(enif_make_int(env, EAGAIN));
  } else { // Error
    perror("write()");
    return MAKE_ERROR(enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM close_pipe(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  int kind;
  enif_get_int(env, argv[1], &kind);

  int result;
  switch (kind) {
  case 0:
    if (ctx->cmd_input_fd == PIPE_CLOSED) {
      return ATOM_OK;
    } else {
      result = close(ctx->cmd_input_fd);
      if (result == 0) {
        ctx->cmd_input_fd = PIPE_CLOSED;
        return ATOM_OK;
      } else {
        perror("cmd_input_fd close()");
        return MAKE_ERROR(enif_make_int(env, errno));
      }
    }
  case 1:
    if (ctx->cmd_output_fd == PIPE_CLOSED) {
      return ATOM_OK;
    } else {
      result = close(ctx->cmd_output_fd);
      if (result == 0) {
        ctx->cmd_output_fd = PIPE_CLOSED;
        return ATOM_OK;
      } else {
        perror("cmd_output_fd close()");
        return MAKE_ERROR(enif_make_int(env, errno));
      }
    }
  default:
    debug("invalid file descriptor type");
    return enif_make_badarg(env);
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

  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->cmd_output_fd == PIPE_CLOSED)
    return MAKE_ERROR(ATOM_PIPE_CLOSED);

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
    return MAKE_OK(bin_term);
  } else if (result > 0) { // request partially satisfied
    int retval = select_read(env, ctx);
    if (retval != 0)
      return MAKE_ERROR(enif_make_int(env, retval));
    return MAKE_OK(bin_term);
  } else if (result == 0) { // EOF
    return MAKE_OK(bin_term);
  } else if (errno == EAGAIN) { // busy
    int retval = select_read(env, ctx);
    if (retval != 0)
      return MAKE_ERROR(enif_make_int(env, retval));
    return MAKE_ERROR(enif_make_int(env, EAGAIN));
  } else { // Error
    perror("read()");
    return MAKE_ERROR(enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM is_alive(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->pid == CMD_EXIT)
    return ERL_FALSE;

  int result = kill(ctx->pid, 0);

  if (result == 0) {
    return ERL_TRUE;
  } else {
    return ERL_FALSE;
  }
}

static ERL_NIF_TERM terminate_proc(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);
  if (ctx->pid == CMD_EXIT)
    return MAKE_OK(enif_make_int(env, 0));

  return enif_make_int(env, kill(ctx->pid, SIGTERM));
}

static ERL_NIF_TERM kill_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);
  if (ctx->pid == CMD_EXIT)
    return MAKE_OK(enif_make_int(env, 0));

  return enif_make_int(env, kill(ctx->pid, SIGKILL));
}

static ERL_NIF_TERM wait_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->pid == CMD_EXIT)
    return MAKE_OK(enif_make_int(env, ctx->cmd_exit_status));

  int status;
  int wpid = waitpid(ctx->pid, &status, WNOHANG);

  if (wpid == ctx->pid) {
    ctx->pid = CMD_EXIT;
    ctx->cmd_exit_status = status;
    return MAKE_OK(enif_make_int(env, status));
  } else if (wpid != 0) {
    perror("waitpid()");
  }
  ERL_NIF_TERM term = enif_make_tuple2(env, enif_make_int(env, wpid),
                                       enif_make_int(env, status));
  return MAKE_ERROR(term);

}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM load_info) {
  struct ExilePriv *data = enif_alloc(sizeof(struct ExilePriv));
  if (!data)
    return 1;

  data->rt =
      enif_open_resource_type_x(env, "exile_resource", &rt_init,
                                ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

  ATOM_OK = enif_make_atom(env, "ok");
  ATOM_ERROR = enif_make_atom(env, "error");
  ATOM_UNDEFINED = enif_make_atom(env, "undefined");
  ATOM_INVALID_CTX = enif_make_atom(env, "invalid_exile_exec_ctx");
  ATOM_INVALID_CTX = enif_make_atom(env, "closed_pipe");

  *priv = (void *)data;

  return 0;
}

static void on_unload(ErlNifEnv *env, void *priv) {
  debug("exile unload");
  enif_free(priv);
}

static ErlNifFunc nif_funcs[] = {
    {"exec_proc", 2, exec_proc, 0},           {"write_proc", 2, write_proc, 0},
    {"read_proc", 2, read_proc, 0},           {"close_pipe", 2, close_pipe, 0},
    {"terminate_proc", 1, terminate_proc, 0}, {"wait_proc", 1, wait_proc, 0},
    {"kill_proc", 1, kill_proc, 0},           {"is_alive", 1, is_alive, 0},
};

ERL_NIF_INIT(Elixir.Exile.ProcessHelper, nif_funcs, &on_load, NULL, NULL,
             &on_unload)
