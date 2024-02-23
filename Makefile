calling_from_make:
	mix compile

UNAME := $(shell uname)

CFLAGS ?= -Wall -Werror -Wextra -Wno-unused-parameter -pedantic -O2 -fPIC

ifeq ($(UNAME), Darwin)
	TARGET_CFLAGS ?= -undefined dynamic_lookup -dynamiclib -Wextra
else ifeq (${UNAME}, Linux)
	# -D_POSIX_C_SOURCE=200809L needed on musl
	CFLAGS += -D_POSIX_C_SOURCE=200809L
	TARGET_CFLAGS ?= -shared
else
	# c_src/spawner.c fails to compile on FreeBSD, NetBSD, and Darwin with -D_POSIX_C_SOURCE=200809L
	# Should be fixed once NetBSD 10 get released:
	# http://gnats.netbsd.org/cgi-bin/query-pr-single.pl?number=57871
	TARGET_CFLAGS ?= -shared
endif

all: priv/exile.so priv/spawner
	@echo > /dev/null

priv/exile.so: c_src/exile.c
	mkdir -p priv
	$(CC) -std=c99 -I$(ERL_INTERFACE_INCLUDE_DIR) $(TARGET_CFLAGS) $(CFLAGS) c_src/exile.c -o priv/exile.so

priv/spawner: c_src/spawner.c
	mkdir -p priv
	$(CC) -std=c99 $(CFLAGS) c_src/spawner.c -o priv/spawner

clean:
	@rm -rf priv/exile.so priv/spawner
