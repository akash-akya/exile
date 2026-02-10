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
static ERL_NIF_TERM ATOM_EAGAIN;
static ERL_NIF_TERM ATOM_EPIPE;

static ERL_NIF_TERM ATOM_SIGTERM;
static ERL_NIF_TERM ATOM_SIGKILL;
static ERL_NIF_TERM ATOM_SIGPIPE;

typedef struct {
  int fd;
  /*
   * Raw NIF entrypoints are controlled by the Exile.Process GenServer pid.
   * This is intentionally different from Exile.Process.Pipe.owner, which is
   * an API-level ownership concept handled in Elixir.
   */
  ErlNifPid controller_pid;
  ErlNifMutex *lock;
} io_resource_t;

static bool is_owner(ErlNifEnv *env, io_resource_t *io) {
  ErlNifPid caller;

  if (!enif_self(env, &caller))
    return false;

  return enif_compare_pids(&caller, &io->controller_pid) == 0;
}

static int snapshot_fd(io_resource_t *io) {
  int fd;

  /*
   * io->fd is mutable and may transition to FD_CLOSED while an operation is
   * in progress. We take a stable snapshot so read/write and subsequent
   * enif_select(READ/WRITE) in the same operation use one consistent value.
   */
  enif_mutex_lock(io->lock);
  fd = io->fd;
  enif_mutex_unlock(io->lock);

  return fd;
}

static int take_fd(io_resource_t *io) {
  int old_fd;

  enif_mutex_lock(io->lock);
  old_fd = io->fd;
  io->fd = FD_CLOSED;
  enif_mutex_unlock(io->lock);

  return old_fd;
}

static void close_if_open(int fd) {
  if (fd != FD_CLOSED) {
    close(fd);
  }
}

static int stop_select(ErlNifEnv *env, io_resource_t *io, int fd) {
  int ret = enif_select(env, (ErlNifEvent)fd, ERL_NIF_SELECT_STOP, io, NULL,
                        ATOM_UNDEFINED);

  if (ret < 0)
    perror("stop_select()");

  return ret;
}

static bool is_stop_callback_invoked(int ret) {
  if (ret < 0)
    return false;

  return (ret & ERL_NIF_SELECT_STOP_CALLED) != 0 ||
         (ret & ERL_NIF_SELECT_STOP_SCHEDULED) != 0;
}

static void close_via_stop_or_direct(ErlNifEnv *env, io_resource_t *io) {
  int fd = snapshot_fd(io);

  if (fd == FD_CLOSED)
    return;

  /*
   * Do not hold lock across enif_select(STOP). stop callback may run directly
   * and needs the same lock for close-once state transition.
   */
  if (!is_stop_callback_invoked(stop_select(env, io, fd))) {
    close_if_open(take_fd(io));
  }
}

static void io_resource_dtor(ErlNifEnv *env, void *obj) {
  io_resource_t *io = (io_resource_t *)obj;

  if (io->lock != NULL) {
    close_if_open(take_fd(io));
    enif_mutex_destroy(io->lock);
    io->lock = NULL;
  } else {
    /* Constructor failure path: lock was not created yet. */
    close_if_open(io->fd);
    io->fd = FD_CLOSED;
  }

  debug("Exile io_resource_dtor called");
}

static void io_resource_stop(ErlNifEnv *env, void *obj, int fd,
                             int is_direct_call) {
  io_resource_t *io = (io_resource_t *)obj;

  /*
   * STOP callback is the safe close point when select is active.
   * Close using shared resource state, not callback fd parameter.
   */
  close_if_open(take_fd(io));
  debug("Exile io_resource_stop called fd=%d direct=%d", fd, is_direct_call);
}

static void io_resource_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                             ErlNifMonitor *monitor) {
  io_resource_t *io = (io_resource_t *)obj;

  close_via_stop_or_direct(env, io);
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

static bool is_select_invalid_event(int ret) {
  if (ret < 0)
    return false;

  return (ret & ERL_NIF_SELECT_INVALID_EVENT) != 0;
}

static int select_write(ErlNifEnv *env, io_resource_t *io, int fd) {
  int ret = enif_select(env, (ErlNifEvent)fd, ERL_NIF_SELECT_WRITE, io, NULL,
                        ATOM_UNDEFINED);

  if (ret < 0)
    perror("select_write()");
  return ret;
}

static ERL_NIF_TERM nif_write(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 2);

  ErlNifTime start;
  int fd;
  ssize_t size;
  ErlNifBinary bin;
  int write_errno;
  io_resource_t *io;

  start = enif_monotonic_time(ERL_NIF_USEC);

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&io))
    return make_error(env, ATOM_INVALID_FD);

  if (!is_owner(env, io))
    return make_error(env, ATOM_INVALID_FD);

  if (enif_inspect_binary(env, argv[1], &bin) != true)
    return enif_make_badarg(env);

  if (bin.size == 0)
    return enif_make_badarg(env);

  fd = snapshot_fd(io);
  if (fd == FD_CLOSED)
    return make_error(env, ATOM_INVALID_FD);

  size = write(fd, bin.data, bin.size);
  write_errno = errno;

  notify_consumed_timeslice(env, start, enif_monotonic_time(ERL_NIF_USEC));

  if (size >= (ssize_t)bin.size) { // request completely satisfied
    return make_ok(env, enif_make_int(env, size));
  } else if (size >= 0) { // request partially satisfied
    int retval = select_write(env, io, fd);
    if (is_select_invalid_event(retval))
      return make_error(env, ATOM_INVALID_FD);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_ok(env, enif_make_int(env, size));
  } else if (write_errno == EAGAIN || write_errno == EWOULDBLOCK) { // busy
    int retval = select_write(env, io, fd);
    if (is_select_invalid_event(retval))
      return make_error(env, ATOM_INVALID_FD);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_error(env, ATOM_EAGAIN);
  } else if (write_errno == EPIPE) {
    return make_error(env, ATOM_EPIPE);
  } else if (write_errno == EBADF) {
    return make_error(env, ATOM_INVALID_FD);
  } else {
    perror("write()");
    return make_error(env, enif_make_int(env, write_errno));
  }
}

static int select_read(ErlNifEnv *env, io_resource_t *io, int fd) {
  int ret = enif_select(env, (ErlNifEvent)fd, ERL_NIF_SELECT_READ, io, NULL,
                        ATOM_UNDEFINED);

  if (ret < 0)
    perror("select_read()");
  return ret;
}

static ERL_NIF_TERM nif_create_fd(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);

  ERL_NIF_TERM term;
  io_resource_t *io;
  int ret;

  io = enif_alloc_resource(FD_RT, sizeof(io_resource_t));
  io->fd = FD_CLOSED;
  io->lock = NULL;

  io->lock = enif_mutex_create("exile_fd_resource_lock");
  if (io->lock == NULL) {
    error("failed to create resource mutex");
    goto error_exit;
  }

  if (!enif_get_int(env, argv[0], &io->fd))
    goto error_exit;

  if (!enif_self(env, &io->controller_pid)) {
    error("failed get self pid");
    goto error_exit;
  }

  ret = enif_monitor_process(env, io, &io->controller_pid, NULL);

  if (ret < 0) {
    error("no down callback is provided");
    goto error_exit;
  } else if (ret > 0) {
    error("pid is not alive");
    goto error_exit;
  }

  term = enif_make_resource(env, io);
  enif_release_resource(io);

  return make_ok(env, term);

error_exit:
  enif_release_resource(io);
  return ATOM_ERROR;
}

static ERL_NIF_TERM read_fd(ErlNifEnv *env, io_resource_t *io, int fd,
                            int max_size) {
  if (max_size == UNBUFFERED_READ) {
    max_size = PIPE_BUF_SIZE;
  } else if (max_size < 1) {
    return enif_make_badarg(env);
  } else if (max_size > PIPE_BUF_SIZE) {
    max_size = PIPE_BUF_SIZE;
  }

  ErlNifTime start = enif_monotonic_time(ERL_NIF_USEC);
  unsigned char buf[max_size];
  ssize_t result = read(fd, buf, max_size);
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
    int retval = select_read(env, io, fd);
    if (is_select_invalid_event(retval))
      return make_error(env, ATOM_INVALID_FD);
    if (retval != 0)
      return make_error(env, enif_make_int(env, retval));
    return make_error(env, ATOM_EAGAIN);
  } else if (read_errno == EPIPE) {
    return make_error(env, ATOM_EPIPE);
  } else if (read_errno == EBADF) {
    return make_error(env, ATOM_INVALID_FD);
  } else {
    perror("read_fd()");
    return make_error(env, enif_make_int(env, read_errno));
  }
}

static ERL_NIF_TERM nif_read(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 2);

  int fd;
  int max_size;
  io_resource_t *io;

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&io))
    return make_error(env, ATOM_INVALID_FD);

  if (!is_owner(env, io))
    return make_error(env, ATOM_INVALID_FD);

  if (!enif_get_int(env, argv[1], &max_size))
    return enif_make_badarg(env);

  fd = snapshot_fd(io);
  if (fd == FD_CLOSED)
    return make_error(env, ATOM_INVALID_FD);

  return read_fd(env, io, fd, max_size);
}

static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);

  io_resource_t *io;

  if (!enif_get_resource(env, argv[0], FD_RT, (void **)&io))
    return make_error(env, ATOM_INVALID_FD);

  if (!is_owner(env, io))
    return make_error(env, ATOM_INVALID_FD);

  close_via_stop_or_direct(env, io);

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
