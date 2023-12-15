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
#include "utils.h"

#ifdef ERTS_DIRTY_SCHEDULERS
#define USE_DIRTY_IO ERL_NIF_DIRTY_JOB_IO_BOUND
#else
#define USE_DIRTY_IO 0
#endif

static const int UNBUFFERED_READ = -1;
static const int PIPE_BUF_SIZE = 65535;
static const int FD_CLOSED = -1;

static ERL_NIF_TERM ATOM_TRUE;
static ERL_NIF_TERM ATOM_FALSE;
static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_UNDEFINED;
static ERL_NIF_TERM ATOM_INVALID_FD;
static ERL_NIF_TERM ATOM_SELECT_CANCEL_ERROR;
static ERL_NIF_TERM ATOM_EAGAIN;
static ERL_NIF_TERM ATOM_EPIPE;

static ERL_NIF_TERM ATOM_SIGTERM;
static ERL_NIF_TERM ATOM_SIGKILL;
static ERL_NIF_TERM ATOM_SIGPIPE;

static void close_fd(int *fd) {
  if (*fd != FD_CLOSED) {
    close(*fd);
    *fd = FD_CLOSED;
  }
}

static int cancel_select(ErlNifEnv *env, int *fd) {
  int ret;

  if (*fd != FD_CLOSED) {
    ret = enif_select(env, *fd, ERL_NIF_SELECT_STOP, fd, NULL, ATOM_UNDEFINED);
    if (ret < 0)
      perror("cancel_select()");

    return ret;
  }

  return 0;
}

static void io_resource_dtor(ErlNifEnv *env, void *obj) {
  debug("Exile io_resource_dtor called");
}

static void io_resource_stop(ErlNifEnv *env, void *obj, int fd,
                             int is_direct_call) {
  close_fd(&fd);
  debug("Exile io_resource_stop called %d", fd);
}

static void io_resource_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                             ErlNifMonitor *monitor) {
  int *fd = (int *)obj;
  cancel_select(env, fd);
  debug("Exile io_resource_down called");
}

static ErlNifResourceTypeInit io_rt_init;

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

static int select_write(ErlNifEnv *env, int *fd) {
  int ret =
      enif_select(env, *fd, ERL_NIF_SELECT_WRITE, fd, NULL, ATOM_UNDEFINED);

  if (ret != 0)
    perror("select_write()");
  return ret;
}

static ERL_NIF_TERM nif_write(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 2);

  ErlNifTime start;
  ssize_t size;
  ErlNifBinary bin;
  int write_errno;
  int *fd;

  start = enif_monotonic_time(ERL_NIF_USEC);

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&fd))
    return make_error(env, ATOM_INVALID_FD);

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
    int retval = select_write(env, fd);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_ok(env, enif_make_int(env, size));
  } else if (write_errno == EAGAIN || write_errno == EWOULDBLOCK) { // busy
    int retval = select_write(env, fd);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_error(env, ATOM_EAGAIN);
  } else if (write_errno == EPIPE) {
    return make_error(env, ATOM_EPIPE);
  } else {
    perror("write()");
    return make_error(env, enif_make_int(env, write_errno));
  }
}

static int select_read(ErlNifEnv *env, int *fd) {
  int ret =
      enif_select(env, *fd, ERL_NIF_SELECT_READ, fd, NULL, ATOM_UNDEFINED);

  if (ret != 0)
    perror("select_read()");
  return ret;
}

static ERL_NIF_TERM nif_create_fd(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);

  ERL_NIF_TERM term;
  ErlNifPid pid;
  int *fd;
  int ret;

  fd = enif_alloc_resource(FD_RT, sizeof(int));

  if (!enif_get_int(env, argv[0], fd))
    goto error_exit;

  if (!enif_self(env, &pid)) {
    error("failed get self pid");
    goto error_exit;
  }

  ret = enif_monitor_process(env, fd, &pid, NULL);

  if (ret < 0) {
    error("no down callback is provided");
    goto error_exit;
  } else if (ret > 0) {
    error("pid is not alive");
    goto error_exit;
  }

  term = enif_make_resource(env, fd);
  enif_release_resource(fd);

  return make_ok(env, term);

error_exit:
  enif_release_resource(fd);
  return ATOM_ERROR;
}

static ERL_NIF_TERM read_fd(ErlNifEnv *env, int *fd, int max_size) {
  if (max_size == UNBUFFERED_READ) {
    max_size = PIPE_BUF_SIZE;
  } else if (max_size < 1) {
    return enif_make_badarg(env);
  } else if (max_size > PIPE_BUF_SIZE) {
    max_size = PIPE_BUF_SIZE;
  }

  ErlNifTime start = enif_monotonic_time(ERL_NIF_USEC);
  unsigned char buf[max_size];
  ssize_t result = read(*fd, buf, max_size);
  int read_errno = errno;

  ERL_NIF_TERM bin_term = 0;
  if (result >= 0) {
    /* no need to release this binary */
    unsigned char *temp = enif_make_new_binary(env, result, &bin_term);
    memcpy(temp, buf, result);
  }

  notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));

  if (result >= 0) {
    return make_ok(env, bin_term);
  } else if (read_errno == EAGAIN || read_errno == EWOULDBLOCK) { // busy
    int retval = select_read(env, fd);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_error(env, ATOM_EAGAIN);
  } else if (read_errno == EPIPE) {
    return make_error(env, ATOM_EPIPE);
  } else {
    perror("read_fd()");
    return make_error(env, enif_make_int(env, read_errno));
  }
}

static ERL_NIF_TERM nif_read(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 2);

  int max_size;
  int *fd;

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&fd))
    return make_error(env, ATOM_INVALID_FD);

  if (!enif_get_int(env, argv[1], &max_size))
    return enif_make_badarg(env);

  return read_fd(env, fd, max_size);
}

static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);

  int *fd;

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&fd))
    return make_error(env, ATOM_INVALID_FD);

  if (cancel_select(env, fd) < 0)
    return make_error(env, ATOM_SELECT_CANCEL_ERROR);

  close_fd(fd);

  return ATOM_OK;
}

static ERL_NIF_TERM nif_is_os_pid_alive(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);

  pid_t pid;

  if (!enif_get_int(env, argv[0], (int *)&pid))
    return enif_make_badarg(env);

  int result = kill(pid, 0);

  if (result == 0)
    return ATOM_TRUE;
  else
    return ATOM_FALSE;
}

static ERL_NIF_TERM nif_kill(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 2);

  pid_t pid;
  int ret;

  // we should not assume pid type to be `int`?
  if (!enif_get_int(env, argv[0], (int *)&pid))
    return enif_make_badarg(env);

  if (enif_compare(argv[1], ATOM_SIGKILL) == 0)
    ret = kill(pid, SIGKILL);
  else if (enif_compare(argv[1], ATOM_SIGTERM) == 0)
    ret = kill(pid, SIGTERM);
  else if (enif_compare(argv[1], ATOM_SIGPIPE) == 0) {
    ret = kill(pid, SIGPIPE);
  } else
    return enif_make_badarg(env);

  if (ret != 0) {
    perror("[exile] failed to send signal");
    return make_error(
        env, enif_make_string(env, "failed to send signal", ERL_NIF_LATIN1));
  }

  return ATOM_OK;
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM load_info) {
  io_rt_init.dtor = io_resource_dtor;
  io_rt_init.stop = io_resource_stop;
  io_rt_init.down = io_resource_down;

  FD_RT =
      enif_open_resource_type_x(env, "exile_resource", &io_rt_init,
                                ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

  ATOM_TRUE = enif_make_atom(env, "true");
  ATOM_FALSE = enif_make_atom(env, "false");
  ATOM_OK = enif_make_atom(env, "ok");
  ATOM_ERROR = enif_make_atom(env, "error");
  ATOM_UNDEFINED = enif_make_atom(env, "undefined");
  ATOM_INVALID_FD = enif_make_atom(env, "invalid_fd_resource");
  ATOM_EAGAIN = enif_make_atom(env, "eagain");
  ATOM_EPIPE = enif_make_atom(env, "epipe");
  ATOM_SELECT_CANCEL_ERROR = enif_make_atom(env, "select_cancel_error");

  ATOM_SIGTERM = enif_make_atom(env, "sigterm");
  ATOM_SIGKILL = enif_make_atom(env, "sigkill");
  ATOM_SIGPIPE = enif_make_atom(env, "sigpipe");

  return 0;
}

static void on_unload(ErlNifEnv *env, void *priv) {
  debug("exile unload");
  enif_free(priv);
}

static ErlNifFunc nif_funcs[] = {
    {"nif_read", 2, nif_read, USE_DIRTY_IO},
    {"nif_create_fd", 1, nif_create_fd, USE_DIRTY_IO},
    {"nif_write", 2, nif_write, USE_DIRTY_IO},
    {"nif_close", 1, nif_close, USE_DIRTY_IO},
    {"nif_is_os_pid_alive", 1, nif_is_os_pid_alive, USE_DIRTY_IO},
    {"nif_kill", 2, nif_kill, USE_DIRTY_IO}};

ERL_NIF_INIT(Elixir.Exile.Process.Nif, nif_funcs, &on_load, NULL, NULL,
             &on_unload)
