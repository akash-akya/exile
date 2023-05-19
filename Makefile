calling_from_make:
	mix compile

UNAME := $(shell uname)

CFLAGS ?= -D_POSIX_C_SOURCE=200809L -Wall -Werror \
		  -Wno-unused-parameter -Wno-gnu-null-pointer-arithmetic \
		  -pedantic -std=c99 -O2 -fsanitize=undefined

ifeq ($(UNAME), Darwin)
	TARGET_CFLAGS ?= -fPIC -undefined dynamic_lookup -dynamiclib -Wextra
endif

ifeq ($(UNAME), Linux)
	TARGET_CFLAGS ?= -fPIC -shared
endif

all: priv/exile.so priv/spawner

priv/exile.so: c_src/exile.c
	mkdir -p priv
	$(CC) -I$(ERL_INTERFACE_INCLUDE_DIR) $(TARGET_CFLAGS) $(CFLAGS) c_src/exile.c -o priv/exile.so

priv/spawner: c_src/spawner.c
	mkdir -p priv
	$(CC) $(CFLAGS) c_src/spawner.c -o priv/spawner

clean:
	@rm -rf priv/exile.so priv/spawner
