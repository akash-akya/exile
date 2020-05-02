#include "erl_nif.h"
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include <stdbool.h>

static int set_flag (int fd)
{
  return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK | O_CLOEXEC);
}

static ERL_NIF_TERM
fast_compare(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int a, b;
  // Fill a and b with the values of the first two args
  enif_get_int(env, argv[0], &a);
  enif_get_int(env, argv[1], &b);

  // Usual C unreadable code because this way is more true
  int result = a == b ? 0 : (a > b ? 1 : -1);

  return enif_make_int(env, result);
}

enum exec_status {
    SUCCESS,
    PIPE_CREATE_ERROR,
    PIPE_FLAG_ERROR,
    FORK_ERROR,
    PIPE_DUP_ERROR
};

typedef struct ExecResults {
  enum exec_status status;
  int err;
  pid_t pid;
  int pipe_in;
  int pipe_out;
} ExecResult;

static const int PIPE_READ  = 0;
static const int PIPE_WRITE = 1;

static void
close_all(int pipes[3][2]) {
  for(int i=0; i<3; i++){
    if (pipes[i][PIPE_READ])   close(pipes[i][PIPE_READ]);
    if (pipes[i][PIPE_WRITE])  close(pipes[i][PIPE_WRITE]);
  }
}

static ExecResult
start_proccess(char *const *args) {
  ExecResult result;
  pid_t pid;
  int pipes[3][2] = {{0, 0}, {0, 0}, {0, 0}};

#define RETURN_ERROR(_status)                                      \
  do {                                                            \
    result.status = _status;                                       \
    result.err = errno;                                           \
    close_all(pipes);                                             \
    return result;                                                \
  } while(0);                                                     \

  if (
      pipe(pipes[STDIN_FILENO])  == -1 ||
      pipe(pipes[STDOUT_FILENO]) == -1 ||
      pipe(pipes[STDERR_FILENO]) == -1) {
    RETURN_ERROR(PIPE_CREATE_ERROR)
  }

  if (
      set_flag(pipes[STDIN_FILENO][PIPE_READ])   < 0 ||
      set_flag(pipes[STDIN_FILENO][PIPE_WRITE])  < 0 ||
      set_flag(pipes[STDOUT_FILENO][PIPE_READ])  < 0 ||
      set_flag(pipes[STDOUT_FILENO][PIPE_WRITE]) < 0 ||
      set_flag(pipes[STDERR_FILENO][PIPE_READ])  < 0 ||
      set_flag(pipes[STDERR_FILENO][PIPE_WRITE]) < 0) {
    RETURN_ERROR(PIPE_FLAG_ERROR)
  }

  switch (pid = fork()) {
  case -1:
    RETURN_ERROR(FORK_ERROR)

  case 0 :
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    fprintf(stderr, "HERE\n");

    if (dup2(pipes[STDIN_FILENO][PIPE_READ], STDIN_FILENO) < 0) RETURN_ERROR(PIPE_DUP_ERROR)
    fprintf(stderr, "HERE 2\n");
    if (dup2(pipes[STDOUT_FILENO][PIPE_WRITE], STDOUT_FILENO) < 0) RETURN_ERROR(PIPE_DUP_ERROR)
    fprintf(stderr, "HERE 3\n");

    close_all(pipes);
    fprintf(stderr, "HERE 4\n");

    /* char* cmd = "/bin/sh"; */
    char *const cmd_args[2] = {"/bin/sh", NULL};
    execvp("/bin/sh", cmd_args);
    perror("execvp(): failed");

  default:
    close(pipes[STDIN_FILENO][PIPE_READ]);
    close(pipes[STDOUT_FILENO][PIPE_WRITE]);
    result.pid      = pid;
    result.pipe_in  = pipes[STDIN_FILENO][PIPE_WRITE];
    result.pipe_out = pipes[STDOUT_FILENO][PIPE_READ];
    result.status   = SUCCESS;
    return result;
  }
}

static ERL_NIF_TERM
exec_proc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  char cmd_args[10][1024];
  char *arg = NULL;

  for (int i=0; i < argc; i++) {
    if (enif_get_string(env, argv[i], cmd_args[i], sizeof(cmd_args[i]), ERL_NIF_LATIN1) < 1) {
      return enif_make_badarg(env);
    }
  }

  ExecResult result = start_proccess((char *const *)cmd_args);

  switch (result.status) {
  case SUCCESS:
    return enif_make_tuple4(env, enif_make_int(env, 0), enif_make_int(env, result.pid), enif_make_int(env, result.pipe_in), enif_make_int(env, result.pipe_out));
  default:
    return enif_make_tuple4(env, enif_make_int(env, -1), enif_make_int(env, 0), enif_make_int(env, 0), enif_make_int(env, 0));
  }
}


static ERL_NIF_TERM
write_proc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pipe_in;
  enif_get_int(env, argv[0], &pipe_in);

  char buf[] = "ls\n";
  int count = write(pipe_in, buf, sizeof(buf));

  if ( count == 0 ) {
    printf("EOF!\n");
  } else if ( count > 0) {
    printf("Success! %d\n", count);
  } else {
    perror("write(): failed");
  }

  return enif_make_int(env, count);
}


static ERL_NIF_TERM
read_proc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pipe_out;
  enif_get_int(env, argv[0], &pipe_out);

  char buf[500];
  (void)memset(&buf, '\0', sizeof(buf));

  int count = read(pipe_out, buf, sizeof(buf));

  if ( count == 0 ) {
    printf("EOF!\n");
  } else if ( count > 0) {
    printf("%s\n", buf);
    printf("Success %d\n", count);
  } else if ( errno == EAGAIN ) {
    printf("EAGAIN\n");
  } else {
    perror("read(): failed");
  }

  return enif_make_int(env, count);
}


static ERL_NIF_TERM
pid_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pid;
  enif_get_int(env, argv[0], &pid);

  int result = kill(pid, 0);

  if ( result == 0 ) {
    printf("Success!\n");
  } else {
    printf("Fail!\n");
  }

  return enif_make_int(env, result);
}

static ERL_NIF_TERM
terminate_proc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pid;
  enif_get_int(env, argv[0], &pid);
  return enif_make_int(env, kill(pid, SIGTERM));
}

static ERL_NIF_TERM
kill_proc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pid;
  enif_get_int(env, argv[0], &pid);
  return enif_make_int(env, kill(pid, SIGKILL));
}

static ERL_NIF_TERM
wait_proc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pid, status;
  enif_get_int(env, argv[0], &pid);

  int wpid = waitpid(pid, &status, WNOHANG);
  fprintf(stderr, "wait(): %s\n", strerror(status));

  return enif_make_tuple2(env, enif_make_int(env, wpid), enif_make_int(env, status));
}


/* static ERL_NIF_TERM */
/* terminate_proc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) { */
/*   int pid, status; */
/*   enif_get_int(env, argv[0], &pid); */

/*   int result = kill(pid, SIGTERM); */
/*   int wpid = waitpid(pid, &status, WNOHANG); */
/*   /\* usleep(500000); *\/ */

/*   printf("wpid: %d result: %d status: %d\n", wpid, result, status); */

/*   if ( wpid == pid && result == 0 ) { */
/*       printf("process %i succesfully killed\n", pid); */
/*   } else { */
/*     printf("failed to kill %i\n", pid); */
/*   } */

/*   return enif_make_int(env, kill(pid, signal)); */
/* } */


// Let's define the array of ErlNifFunc beforehand:
static ErlNifFunc nif_funcs[] = {
                                 // {erl_function_name, erl_function_arity, c_function}
                                 {"fast_compare", 2, fast_compare},
                                 {"exec_proc", 1, exec_proc},
                                 {"write_proc", 1, write_proc},
                                 {"read_proc", 1, read_proc},
                                 {"terminate_proc", 1, terminate_proc},
                                 {"wait_proc", 1, wait_proc},
                                 {"kill_proc", 1, kill_proc},
                                 {"pid_info", 1, pid_info},
};

ERL_NIF_INIT(Elixir.Exile, nif_funcs, NULL, NULL, NULL, NULL)
