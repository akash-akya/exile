calling_from_make:
	mix compile

UNAME := $(shell uname)

CFLAGS ?= -Wall -Werror -Wextra -Wno-unused-parameter -pedantic -O2 -fPIC

ifeq ($(UNAME), Darwin)
	TARGET_CFLAGS ?= -undefined dynamic_lookup -dynamiclib
else
	TARGET_CFLAGS ?= -D_POSIX_C_SOURCE=200809L -shared
endif

ifeq ($(UNAME), Linux)
	CFLAGS += -D_POSIX_C_SOURCE=200809L
	TARGET_CFLAGS ?= -fPIC -shared
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
