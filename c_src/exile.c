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
    if (enif_get_resource(env, arg, data->exec_ctx_rt, (void **)&ctx) ==       \
        false) {                                                               \
      return make_error(env, ATOM_INVALID_CTX);                                \
    }                                                                          \
  } while (0);

static const int CMD_EXIT = -1;
static const int UNBUFFERED_READ = -1;
static const int PIPE_BUF_SIZE = 65535;

static ERL_NIF_TERM ATOM_TRUE;
static ERL_NIF_TERM ATOM_FALSE;
static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_UNDEFINED;
static ERL_NIF_TERM ATOM_INVALID_CTX;
static ERL_NIF_TERM ATOM_PIPE_CLOSED;
static ERL_NIF_TERM ATOM_EAGAIN;
static ERL_NIF_TERM ATOM_ALLOC_FAILED;

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
  ErlNifResourceType *exec_ctx_rt;
  ErlNifResourceType *io_rt;
} ExilePriv;

typedef struct ExecContext {
  int cmd_input_fd;
  int cmd_output_fd;
  int exit_status; // can be exit status or signal number depending on exit_type
  enum exit_type exit_type;
  pid_t pid;
  // these are to hold enif_select resource objects
  int *read_resource;
  int *write_resource;
} ExecContext;

typedef struct StartProcessResult {
  bool success;
  int err;
  ExecContext context;
} StartProcessResult;

/* TODO: assert if the external process is exit (?) */
static void exec_ctx_dtor(ErlNifEnv *env, void *obj) {
  ExecContext *ctx = obj;
  enif_release_resource(ctx->read_resource);
  enif_release_resource(ctx->write_resource);
  debug("Exile exec_ctx_dtor called");
}

static void exec_ctx_stop(ErlNifEnv *env, void *obj, int fd,
                          int is_direct_call) {
  debug("Exile exec_ctx_stop called");
}

static void exec_ctx_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                          ErlNifMonitor *monitor) {
  debug("Exile exec_ctx_down called");
}

static ErlNifResourceTypeInit exec_ctx_rt_init = {exec_ctx_dtor, exec_ctx_stop,
                                                  exec_ctx_down};

static void io_resource_dtor(ErlNifEnv *env, void *obj) {
  debug("Exile io_resource_dtor called");
}

static void io_resource_stop(ErlNifEnv *env, void *obj, int fd,
                             int is_direct_call) {
  debug("Exile io_resource_stop called %d", fd);
}

static void io_resource_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                             ErlNifMonitor *monitor) {
  debug("Exile io_resource_down called");
}

static ErlNifResourceTypeInit io_rt_init = {io_resource_dtor, io_resource_stop,
                                            io_resource_down};

static ErlNifResourceType *FD_RT;

static inline ERL_NIF_TERM make_ok(ErlNifEnv *env, ERL_NIF_TERM term) {
  return enif_make_tuple2(env, ATOM_OK, term);
}

static inline ERL_NIF_TERM make_error(ErlNifEnv *env, ERL_NIF_TERM term) {
  return enif_make_tuple2(env, ATOM_ERROR, term);
}

/* time is assumed to be in microseconds */
static void notify_consumed_timeslice(ErlNifEnv *env, ErlNifTime start,
                                      ErlNifTime stop) {
  ErlNifTime pct;

  pct = (ErlNifTime)((stop - start) / 10);
  if (pct > 100)
    pct = 100;
  else if (pct == 0)
    pct = 1;
  enif_consume_timeslice(env, pct);
}

static int select_write_async(ErlNifEnv *env, int *fd) {
  int ret =
      enif_select(env, *fd, ERL_NIF_SELECT_WRITE, fd, NULL, ATOM_UNDEFINED);

  if (ret != 0)
    perror("select_write()");
  return ret;
}

static ERL_NIF_TERM nif_write(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  if (argc != 2)
    enif_make_badarg(env);

  ErlNifTime start;
  ssize_t size;
  ErlNifBinary bin;
  int write_errno;
  int *fd;

  start = enif_monotonic_time(ERL_NIF_USEC);

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&fd))
    return make_error(env, ATOM_INVALID_CTX);

  if (enif_inspect_binary(env, argv[1], &bin) != true)
    return enif_make_badarg(env);

  if (bin.size == 0)
    return enif_make_badarg(env);

  /* should we limit the bin.size here? */
  size = write(*fd, bin.data, bin.size);
  write_errno = errno;

  notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));

  if (size >= (ssize_t)bin.size) { // request completely satisfied
    return make_ok(env, enif_make_int(env, size));
  } else if (size >= 0) { // request partially satisfied
    int retval = select_write_async(env, fd);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_ok(env, enif_make_int(env, size));
  } else if (write_errno == EAGAIN || write_errno == EWOULDBLOCK) { // busy
    int retval = select_write_async(env, fd);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_error(env, ATOM_EAGAIN);
  } else { // Error
    perror("write()");
    return make_error(env, enif_make_int(env, write_errno));
  }
}

static int select_read_async(ErlNifEnv *env, int *fd) {
  int ret =
      enif_select(env, *fd, ERL_NIF_SELECT_READ, fd, NULL, ATOM_UNDEFINED);

  if (ret != 0)
    perror("select_read()");
  return ret;
}

static ERL_NIF_TERM nif_create_fd(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  if (argc != 1)
    enif_make_badarg(env);

  ERL_NIF_TERM term;
  int *fd;

  fd = enif_alloc_resource(FD_RT, sizeof(int));

  if (!enif_get_int(env, argv[0], fd))
    goto error_exit;

  term = enif_make_resource(env, fd);
  enif_release_resource(fd);

  return make_ok(env, term);

error_exit:
  enif_release_resource(fd);
  return ATOM_ERROR;
}

static ERL_NIF_TERM nif_read_async(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  if (argc != 2)
    enif_make_badarg(env);

  ErlNifTime start;
  int size, demand;
  int *fd;

  start = enif_monotonic_time(ERL_NIF_USEC);

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&fd))
    return make_error(env, ATOM_INVALID_CTX);

  if (!enif_get_int(env, argv[1], &demand))
    return enif_make_badarg(env);

  size = demand;

  if (demand == UNBUFFERED_READ) {
    size = PIPE_BUF_SIZE;
  } else if (demand < 1) {
    enif_make_badarg(env);
  } else if (demand > PIPE_BUF_SIZE) {
    size = PIPE_BUF_SIZE;
  }

  unsigned char buf[size];
  ssize_t result = read(*fd, buf, size);
  int read_errno = errno;

  ERL_NIF_TERM bin_term = 0;
  if (result >= 0) {
    /* no need to release this binary */
    unsigned char *temp = enif_make_new_binary(env, result, &bin_term);
    memcpy(temp, buf, result);
  }

  notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));

  if (result >= 0) {
    /* we do not 'select' if demand completely satisfied OR EOF OR its
     * UNBUFFERED_READ */
    if (result == demand || result == 0 || demand == UNBUFFERED_READ) {
      return make_ok(env, bin_term);
    } else { // demand partially satisfied
      int retval = select_read_async(env, fd);
      if (retval != 0)
        return make_error(env, enif_make_int(env, retval));
      return make_ok(env, bin_term);
    }
  } else {
    if (read_errno == EAGAIN || read_errno == EWOULDBLOCK) { // busy
      int retval = select_read_async(env, fd);
      if (retval != 0)
        return make_error(env, enif_make_int(env, retval));
      return make_error(env, ATOM_EAGAIN);
    } else { // Error
      perror("read()");
      return make_error(env, enif_make_int(env, read_errno));
    }
  }
}

static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  if (argc != 1)
    enif_make_badarg(env);

  ErlNifTime start;
  int *fd;

  start = enif_monotonic_time(ERL_NIF_USEC);

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&fd))
    return make_error(env, ATOM_INVALID_CTX);

  close(*fd);

  notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));
  return ATOM_OK;
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

static ERL_NIF_TERM sys_terminate(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  ExecContext *ctx = NULL;
  GET_CTX(env, argv[0], ctx);
  if (ctx->pid == CMD_EXIT)
    return make_ok(env, enif_make_int(env, 0));

  return make_ok(env, enif_make_int(env, kill(ctx->pid, SIGTERM)));
}

static ERL_NIF_TERM sys_kill(ErlNifEnv *env, int argc,
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

static ERL_NIF_TERM sys_wait(ErlNifEnv *env, int argc,
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

  data->exec_ctx_rt =
      enif_open_resource_type_x(env, "exile_resource", &exec_ctx_rt_init,
                                ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
  data->io_rt =
      enif_open_resource_type_x(env, "exile_resource", &io_rt_init,
                                ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

  FD_RT =
      enif_open_resource_type_x(env, "exile_resource", &io_rt_init,
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
  ATOM_ALLOC_FAILED = enif_make_atom(env, "alloc_failed");

  *priv = (void *)data;

  return 0;
}

static void on_unload(ErlNifEnv *env, void *priv) {
  debug("exile unload");
  enif_free(priv);
}

static ErlNifFunc nif_funcs[] = {
    {"sys_terminate", 1, sys_terminate, USE_DIRTY_IO},
    {"sys_wait", 1, sys_wait, USE_DIRTY_IO},
    {"sys_kill", 1, sys_kill, USE_DIRTY_IO},
    {"nif_read_async", 2, nif_read_async, USE_DIRTY_IO},
    {"nif_create_fd", 1, nif_create_fd, USE_DIRTY_IO},
    {"nif_write", 2, nif_write, USE_DIRTY_IO},
    {"nif_close", 1, nif_close, USE_DIRTY_IO},
    {"alive?", 1, is_alive, USE_DIRTY_IO},
    {"os_pid", 1, os_pid, USE_DIRTY_IO},
};

ERL_NIF_INIT(Elixir.Exile.ProcessNif, nif_funcs, &on_load, NULL, NULL,
             &on_unload)
