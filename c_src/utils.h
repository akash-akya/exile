#ifndef EXILE_UTILS_H
#define EXILE_UTILS_H

#include "erl_nif.h"
#include <stdbool.h>

// #define DEBUG

#ifdef DEBUG
#define debug(...)                                                             \
  do {                                                                         \
    enif_fprintf(stderr, "%s:%d\t(fn \"%s\")  - ", __FILE__, __LINE__,         \
                 __func__);                                                    \
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
    enif_fprintf(stderr, "%s:%d\t(fn: \"%s\")  - ", __FILE__, __LINE__,        \
                 __func__);                                                    \
    enif_fprintf(stderr, __VA_ARGS__);                                         \
    enif_fprintf(stderr, "\n");                                                \
  } while (0)

#define ASSERT_ARGC(argc, count)                                               \
  if (argc != count) {                                                         \
    error("number of arguments must be %d", count);                            \
    return enif_make_badarg(env);                                              \
  }

#endif
