#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "erl_nif.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef ERTS_DIRTY_SCHEDULERS
#define USE_DIRTY_IO ERL_NIF_DIRTY_JOB_IO_BOUND
#else
#define USE_DIRTY_IO 0
#endif

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

#define GET_CTX(env, arg, ctx)                                                 \
  do {                                                                         \
    ExilePriv *data = enif_priv_data(env);                                     \
    if (enif_get_resource(env, arg, data->rt, (void **)&ctx) == false) {       \
      return make_error(env, ATOM_INVALID_CTX);                                \
    }                                                                          \
  } while (0);

static const int PIPE_READ = 0;
static const int PIPE_WRITE = 1;
static const int PIPE_CLOSED = -1;
static const int CMD_EXIT = -1;
static const int MAX_ARGUMENTS = 20;
static const int MAX_ARGUMENT_LEN = 1024;

/* We are choosing an exit code which is not reserved see:
 * https://www.tldp.org/LDP/abs/html/exitcodes.html. */
static const int FORK_EXEC_FAILURE = 125;

static ERL_NIF_TERM ATOM_TRUE;
static ERL_NIF_TERM ATOM_FALSE;
static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_UNDEFINED;
static ERL_NIF_TERM ATOM_INVALID_CTX;
static ERL_NIF_TERM ATOM_PIPE_CLOSED;
static ERL_NIF_TERM ATOM_EAGAIN;

/* command exit types */
static ERL_NIF_TERM ATOM_EXIT;
static ERL_NIF_TERM ATOM_SIGNALED;
static ERL_NIF_TERM ATOM_STOPPED;

enum exec_status {
  SUCCESS,
  PIPE_CREATE_ERROR,
  PIPE_FLAG_ERROR,
  FORK_ERROR,
  PIPE_DUP_ERROR,
  NULL_DEV_OPEN_ERROR,
};

enum exit_type { NORMAL_EXIT, SIGNALED, STOPPED };

typedef struct ExilePriv {
  ErlNifResourceType *rt;
} ExilePriv;

typedef struct ExecContext {
  int cmd_input_fd;
  int cmd_output_fd;
  int exit_status; // can be exit status or signal number depending on exit_type
  enum exit_type exit_type;
  pid_t pid;
} ExecContext;

typedef struct StartProcessResult {
  bool success;
  int err;
  ExecContext context;
} StartProcessResult;

/* TODO: assert if the external process is exit (?) */
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

static inline ERL_NIF_TERM make_ok(ErlNifEnv *env, ERL_NIF_TERM term) {
  return enif_make_tuple2(env, ATOM_OK, term);
}

static inline ERL_NIF_TERM make_error(ErlNifEnv *env, ERL_NIF_TERM term) {
  return enif_make_tuple2(env, ATOM_ERROR, term);
}

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

/* time is assumed to be in microseconds */
static void notify_consumed_timeslice(ErlNifEnv *env, ErlNifTime start, ErlNifTime stop) {
  ErlNifTime pct;

  pct = (ErlNifTime)((stop - start) / 10);
  if (pct > 100)
    pct = 100;
  else if (pct == 0)
    pct = 1;
  enif_consume_timeslice(env, pct);
}

/* This is not ideal, but as of now there is no portable way to do this */
static void close_all_fds() {
  int fd_limit = (int)sysconf(_SC_OPEN_MAX);
  for (int i = STDERR_FILENO + 1; i < fd_limit; i++)
    close(i);
}

static StartProcessResult start_proccess(char *args[], bool stderr_to_console) {
  StartProcessResult result = {.success = false};
  pid_t pid;
  int pipes[2][2] = {{0, 0}, {0, 0}};

  if (pipe(pipes[STDIN_FILENO]) == -1 || pipe(pipes[STDOUT_FILENO]) == -1) {
    result.err = errno;
    perror("[exile] failed to create pipes");
    close_all(pipes);
    return result;
  }

  const int r_cmdin = pipes[STDIN_FILENO][PIPE_READ];
  const int w_cmdin = pipes[STDIN_FILENO][PIPE_WRITE];

  const int r_cmdout = pipes[STDOUT_FILENO][PIPE_READ];
  const int w_cmdout = pipes[STDOUT_FILENO][PIPE_WRITE];

  if (set_flag(r_cmdin, O_CLOEXEC) < 0 || set_flag(w_cmdout, O_CLOEXEC) < 0 ||
      set_flag(w_cmdin, O_CLOEXEC | O_NONBLOCK) < 0 ||
      set_flag(r_cmdout, O_CLOEXEC | O_NONBLOCK) < 0) {
    result.err = errno;
    perror("[exile] failed to set flags for pipes");
    close_all(pipes);
    return result;
  }

  switch (pid = fork()) {

  case -1:
    result.err = errno;
    perror("[exile] failed to fork");
    close_all(pipes);
    return result;

  case 0: // child

    close(STDIN_FILENO);
    close(STDOUT_FILENO);

    if (dup2(r_cmdin, STDIN_FILENO) < 0) {
      perror("[exile] failed to dup to stdin");

      /* We are assuming FORK_EXEC_FAILURE exit code wont be used by the command
       * we are running. Technically we can not assume any exit code here. The
       * parent can not differentiate between exit before `exec` and the normal
       * command exit.
       * One correct way to solve this might be to have a separate
       * pipe shared between child and parent and signaling the parent by
       * closing it or writing to it. */
      _exit(FORK_EXEC_FAILURE);
    }
    if (dup2(w_cmdout, STDOUT_FILENO) < 0) {
      perror("[exile] failed to dup to stdout");
      _exit(FORK_EXEC_FAILURE);
    }

    if (stderr_to_console != true) {
      close(STDERR_FILENO);
      int dev_null = open("/dev/null", O_WRONLY);

      if (dev_null == -1) {
        perror("[exile] failed to open /dev/null");
        _exit(FORK_EXEC_FAILURE);
      }

      if (dup2(dev_null, STDERR_FILENO) < 0) {
        perror("[exile] failed to dup stderr");
        _exit(FORK_EXEC_FAILURE);
      }

      close(dev_null);
    }

    close_all_fds();

    execvp(args[0], args);
    perror("[exile] execvp(): failed");

    _exit(FORK_EXEC_FAILURE);

  default: // parent
    /* close file descriptors used by child */
    close(r_cmdin);
    close(w_cmdout);

    result.success = true;
    result.context.pid = pid;
    result.context.cmd_input_fd = w_cmdin;
    result.context.cmd_output_fd = r_cmdout;

    return result;
  }
}

/* TODO: return appropriate error instead returning generic "badarg" error */
static ERL_NIF_TERM exec_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  char tmp[MAX_ARGUMENTS][MAX_ARGUMENT_LEN + 1];
  char *exec_args[MAX_ARGUMENTS + 1];
  ErlNifTime start;
  unsigned int args_len;

  start = enif_monotonic_time(ERL_NIF_USEC);

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
  StartProcessResult result = start_proccess(exec_args, stderr_to_console);
  ExecContext *ctx = NULL;
  ERL_NIF_TERM term;

  if (result.success) {
    ctx = enif_alloc_resource(data->rt, sizeof(ExecContext));
    ctx->cmd_input_fd = result.context.cmd_input_fd;
    ctx->cmd_output_fd = result.context.cmd_output_fd;
    ctx->pid = result.context.pid;

    debug("pid: %d  cmd_in_fd: %d  cmd_out_fd: %d", ctx->pid, ctx->cmd_input_fd,
          ctx->cmd_output_fd);

    term = enif_make_resource(env, ctx);

    /* resource should be collected beam GC when there are no more references */
    enif_release_resource(ctx);

    notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));

    return make_ok(env, term);
  } else {
    return make_error(env, enif_make_int(env, result.err));
  }
}

static int select_write(ErlNifEnv *env, ExecContext *ctx) {
  int retval = enif_select(env, ctx->cmd_input_fd, ERL_NIF_SELECT_WRITE, ctx,
                           NULL, ATOM_UNDEFINED);
  if (retval != 0)
    perror("select_write()");

  return retval;
}

static ERL_NIF_TERM write_proc(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  if (argc != 2)
    enif_make_badarg(env);

  ErlNifTime start;
  start = enif_monotonic_time(ERL_NIF_USEC);

  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->cmd_input_fd == PIPE_CLOSED)
    return make_error(env, ATOM_PIPE_CLOSED);

  ErlNifBinary bin;
  /* TODO: should not use enif_inspect_binary */
  if (enif_inspect_binary(env, argv[1], &bin) != true)
    return enif_make_badarg(env);

  unsigned int result = write(ctx->cmd_input_fd, bin.data, bin.size);

  notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));

  /* TODO: branching is ugly, cleanup required */
  if (result >= bin.size) { // request completely satisfied
    return make_ok(env, enif_make_int(env, result));
  } else if (result >= 0) { // request partially satisfied
    int retval = select_write(env, ctx);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_ok(env, enif_make_int(env, result));
  } else if (errno == EAGAIN) { // busy
    int retval = select_write(env, ctx);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_error(env, ATOM_EAGAIN);
  } else { // Error
    perror("write()");
    return make_error(env, enif_make_int(env, errno));
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
        return make_error(env, enif_make_int(env, errno));
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
        return make_error(env, enif_make_int(env, errno));
      }
    }
  default:
    debug("invalid file descriptor type");
    return enif_make_badarg(env);
  }
}

static int select_read(ErlNifEnv *env, ExecContext *ctx) {
  int retval = enif_select(env, ctx->cmd_output_fd, ERL_NIF_SELECT_READ, ctx,
                           NULL, ATOM_UNDEFINED);
  if (retval != 0)
    perror("select_read()");
  return retval;
}

static ERL_NIF_TERM read_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  if (argc != 2)
    enif_make_badarg(env);

  ErlNifTime start;
  start = enif_monotonic_time(ERL_NIF_USEC);

  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->cmd_output_fd == PIPE_CLOSED)
    return make_error(env, ATOM_PIPE_CLOSED);

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

  ERL_NIF_TERM bin_term = 0;
  if (result >= 0) {
    ErlNifBinary bin;
    enif_alloc_binary(result, &bin);
    /* TODO: we should use the erl binary for `read` itself instead of
     * allocating again */
    memcpy(bin.data, buf, result);
    bin_term = enif_make_binary(env, &bin);
  }

  notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));

  /* TODO: branching is ugly, cleanup required */
  if (result >= size ||
      (is_buffered == false && result >= 0)) { // request completely satisfied
    return make_ok(env, bin_term);
  } else if (result > 0) { // request partially satisfied
    int retval = select_read(env, ctx);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_ok(env, bin_term);
  } else if (result == 0) { // EOF
    return make_ok(env, bin_term);
  } else if (errno == EAGAIN) { // busy
    int retval = select_read(env, ctx);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_error(env, ATOM_EAGAIN);
  } else { // Error
    perror("read()");
    return make_error(env, enif_make_int(env, errno));
  }
}

static ERL_NIF_TERM is_alive(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->pid == CMD_EXIT)
    return make_ok(env, ATOM_TRUE);

  int result = kill(ctx->pid, 0);

  if (result == 0) {
    return make_ok(env, ATOM_TRUE);
  } else {
    return make_ok(env, ATOM_FALSE);
  }
}

static ERL_NIF_TERM terminate_proc(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);
  if (ctx->pid == CMD_EXIT)
    return make_ok(env, enif_make_int(env, 0));

  return make_ok(env, enif_make_int(env, kill(ctx->pid, SIGTERM)));
}

static ERL_NIF_TERM kill_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);
  if (ctx->pid == CMD_EXIT)
    return make_ok(env, enif_make_int(env, 0));

  return make_ok(env, enif_make_int(env, kill(ctx->pid, SIGKILL)));
}

static ERL_NIF_TERM make_exit_term(ErlNifEnv *env, ExecContext *ctx) {
  switch (ctx->exit_type) {
  case NORMAL_EXIT:
    return make_ok(env, enif_make_tuple2(env, ATOM_EXIT,
                                         enif_make_int(env, ctx->exit_status)));
  case SIGNALED:
    /* exit_status here points to signal number */
    return make_ok(env, enif_make_tuple2(env, ATOM_SIGNALED,
                                         enif_make_int(env, ctx->exit_status)));
  case STOPPED:
    return make_ok(env, enif_make_tuple2(env, ATOM_STOPPED,
                                         enif_make_int(env, ctx->exit_status)));
  default:
    error("Invalid wait status");
    return make_error(env, ATOM_UNDEFINED);
  }
}

static ERL_NIF_TERM wait_proc(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);

  if (ctx->pid == CMD_EXIT)
    return make_exit_term(env, ctx);

  int status;
  int wpid = waitpid(ctx->pid, &status, WNOHANG);

  if (wpid == ctx->pid) {
    ctx->pid = CMD_EXIT;

    if (WIFEXITED(status)) {
      ctx->exit_type = NORMAL_EXIT;
      ctx->exit_status = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
      ctx->exit_type = SIGNALED;
      ctx->exit_status = WTERMSIG(status);
    } else if (WIFSTOPPED(status)) {
      ctx->exit_type = STOPPED;
      ctx->exit_status = 0;
    }

    return make_exit_term(env, ctx);
  } else if (wpid != 0) {
    perror("waitpid()");
  }
  ERL_NIF_TERM term = enif_make_tuple2(env, enif_make_int(env, wpid),
                                       enif_make_int(env, status));
  return make_error(env, term);
}

static ERL_NIF_TERM os_pid(ErlNifEnv *env, int argc,
                           const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);
  if (ctx->pid == CMD_EXIT)
    return make_ok(env, enif_make_int(env, 0));

  return make_ok(env, enif_make_int(env, ctx->pid));
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM load_info) {
  struct ExilePriv *data = enif_alloc(sizeof(struct ExilePriv));
  if (!data)
    return 1;

  data->rt =
      enif_open_resource_type_x(env, "exile_resource", &rt_init,
                                ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

  ATOM_TRUE = enif_make_atom(env, "true");
  ATOM_FALSE = enif_make_atom(env, "false");
  ATOM_OK = enif_make_atom(env, "ok");
  ATOM_ERROR = enif_make_atom(env, "error");
  ATOM_UNDEFINED = enif_make_atom(env, "undefined");
  ATOM_INVALID_CTX = enif_make_atom(env, "invalid_exile_exec_ctx");
  ATOM_PIPE_CLOSED = enif_make_atom(env, "closed_pipe");
  ATOM_EXIT = enif_make_atom(env, "exit");
  ATOM_SIGNALED = enif_make_atom(env, "signaled");
  ATOM_STOPPED = enif_make_atom(env, "stopped");
  ATOM_EAGAIN = enif_make_atom(env, "eagain");

  *priv = (void *)data;

  return 0;
}

static void on_unload(ErlNifEnv *env, void *priv) {
  debug("exile unload");
  enif_free(priv);
}

static ErlNifFunc nif_funcs[] = {
    {"exec_proc", 2, exec_proc, USE_DIRTY_IO},
    {"write_proc", 2, write_proc, USE_DIRTY_IO},
    {"read_proc", 2, read_proc, USE_DIRTY_IO},
    {"close_pipe", 2, close_pipe, USE_DIRTY_IO},
    {"terminate_proc", 1, terminate_proc, USE_DIRTY_IO},
    {"wait_proc", 1, wait_proc, USE_DIRTY_IO},
    {"kill_proc", 1, kill_proc, USE_DIRTY_IO},
    {"is_alive", 1, is_alive, USE_DIRTY_IO},
    {"os_pid", 1, os_pid, USE_DIRTY_IO},
};

ERL_NIF_INIT(Elixir.Exile.ProcessNif, nif_funcs, &on_load, NULL, NULL,
             &on_unload)
